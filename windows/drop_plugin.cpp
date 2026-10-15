#include "drop_plugin.h"

#include <unknwn.h>

#include <winrt/base.h>

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <string>
#include <utility>

#include "text.h"

namespace ux {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

// The OLE drop target on the Flutter view, which hands each call to [plugin].
class DropTarget : public winrt::implements<DropTarget, IDropTarget> {
 public:
  explicit DropTarget(DropPlugin& plugin) : plugin_(plugin) {}

  HRESULT __stdcall DragEnter(IDataObject* data, DWORD, POINTL point, DWORD* effect) noexcept final {
    *effect = plugin_.DragEnter(data, point, *effect);
    return S_OK;
  }

  HRESULT __stdcall DragOver(DWORD, POINTL point, DWORD* effect) noexcept final {
    *effect = plugin_.DragOver(point, *effect);
    return S_OK;
  }

  HRESULT __stdcall DragLeave() noexcept final {
    plugin_.DragLeave();
    return S_OK;
  }

  HRESULT __stdcall Drop(IDataObject* data, DWORD, POINTL point, DWORD* effect) noexcept final {
    *effect = plugin_.Drop(data, point, *effect);
    return S_OK;
  }

 private:
  DropPlugin& plugin_;
};

DropPlugin::DropPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar),
      channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          registrar->messenger(), "ux/drop", &flutter::StandardMethodCodec::GetInstance())),
      events_(std::make_unique<flutter::EventChannel<EncodableValue>>(
          registrar->messenger(), "ux/drop/events", &flutter::StandardMethodCodec::GetInstance())),
      window_proc_(registrar->RegisterTopLevelWindowProcDelegate(
          [this](HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
            return HandleWindowProc(window, message, wparam, lparam);
          })) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) { HandleMethodCall(call, std::move(result)); });
  events_->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
      [this](const EncodableValue*, std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink)
          -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        has_regions_ = true;
        if (!view_) {
          const HRESULT hr = Register();
          if (FAILED(hr)) {
            return std::make_unique<flutter::StreamHandlerError<EncodableValue>>("register_failed", Hex(hr), nullptr);
          }
        }
        sink_ = std::move(sink);
        return nullptr;
      },
      [this](const EncodableValue*) -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        sink_.reset();
        Revoke();
        return nullptr;
      }));
}

DropPlugin::~DropPlugin() {
  registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_);
  Revoke();
}

void DropPlugin::HandleMethodCall(const flutter::MethodCall<EncodableValue>& call,
                                  std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  if (call.method_name() != "setHasRegions") {
    result->NotImplemented();
    return;
  }
  const auto* value = std::get_if<bool>(call.arguments());
  if (value == nullptr) {
    result->Error("bad_args", "setHasRegions takes a bool");
    return;
  }
  has_regions_ = *value;
  result->Success();
}

std::optional<LRESULT> DropPlugin::HandleWindowProc(HWND, UINT message, WPARAM, LPARAM) {
  if (message == WM_DESTROY) Revoke();
  return std::nullopt;
}

HRESULT DropPlugin::Register() {
  flutter::FlutterView* view = registrar_->GetView();
  if (view == nullptr) return HRESULT_FROM_WIN32(ERROR_INVALID_WINDOW_HANDLE);
  HRESULT hr = OleInitialize(nullptr);
  if (FAILED(hr)) return hr;
  const HWND window = view->GetNativeWindow();
  hr = RegisterDragDrop(window, winrt::make_self<DropTarget>(*this).get());
  if (FAILED(hr)) {
    OleUninitialize();
    return hr;
  }
  view_ = window;
  return S_OK;
}

void DropPlugin::Revoke() {
  if (!view_) return;
  RevokeDragDrop(*view_);
  OleUninitialize();
  view_.reset();
  offers_files_ = false;
}

DWORD DropPlugin::DragEnter(IDataObject* data, POINTL point, DWORD allowed) {
  offers_files_ = OffersFiles(data);
  return Report("enter", point, allowed);
}

DWORD DropPlugin::DragOver(POINTL point, DWORD allowed) { return Report("update", point, allowed); }

DWORD DropPlugin::Report(const char* type, POINTL point, DWORD allowed) {
  if (!Accepts(allowed)) return DROPEFFECT_NONE;
  const LogicalPoint at = Logical(point);
  Emit({
      {EncodableValue("type"), EncodableValue(type)},
      {EncodableValue("x"), EncodableValue(at.x)},
      {EncodableValue("y"), EncodableValue(at.y)},
  });
  return DROPEFFECT_COPY;
}

void DropPlugin::DragLeave() {
  if (offers_files_) Emit({{EncodableValue("type"), EncodableValue("exit")}});
  offers_files_ = false;
}

DWORD DropPlugin::Drop(IDataObject* data, POINTL point, DWORD allowed) {
  if (!Accepts(allowed)) {
    DragLeave();
    return DROPEFFECT_NONE;
  }
  offers_files_ = false;
  const LogicalPoint at = Logical(point);
  if (std::optional<std::vector<std::wstring>> paths = DroppedPaths(data)) {
    platform_.Background<std::vector<DroppedFile>>([paths = std::move(*paths)]() { return DescribePaths(paths); },
                                                   [this, at](std::vector<DroppedFile> files) { EmitDrop(at, files); });
  } else {
    ExtractVirtualFiles(data, at);
  }
  return DROPEFFECT_COPY;
}

bool DropPlugin::Accepts(DWORD allowed) const {
  return offers_files_ && has_regions_ && (allowed & DROPEFFECT_COPY) != 0;
}

LogicalPoint DropPlugin::Logical(POINTL point) const { return ToLogical(*view_, point, GetDpiForWindow(*view_)); }

// A source that extracts asynchronously (IDataObjectAsyncCapability) keeps its
// data until EndOperation, so its files are written off the platform thread.
// Any other source serves its contents only while Drop runs.
void DropPlugin::ExtractVirtualFiles(IDataObject* data, LogicalPoint at) {
  ComPtr<IDataObjectAsyncCapability> async;
  BOOL asynchronous = FALSE;
  IStream* marshalled = nullptr;
  if (FAILED(data->QueryInterface(IID_PPV_ARGS(&async))) || FAILED(async->GetAsyncMode(&asynchronous)) ||
      !asynchronous || FAILED(CoMarshalInterThreadInterfaceInStream(IID_IDataObject, data, &marshalled))) {
    EmitDrop(at, WriteVirtualFiles(data));
    return;
  }
  async->StartOperation(nullptr);
  const uint64_t drop = next_drop_++;
  extracting_.emplace(drop, async);
  platform_.Background<std::vector<DroppedFile>>(
      [marshalled]() {
        const bool com = SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED));
        std::vector<DroppedFile> files;
        {
          ComPtr<IDataObject> source;
          if (SUCCEEDED(CoGetInterfaceAndReleaseStream(marshalled, IID_PPV_ARGS(&source)))) {
            files = WriteVirtualFiles(source.Get());
          }
        }
        if (com) CoUninitialize();
        return files;
      },
      [this, drop, at](std::vector<DroppedFile> files) {
        const auto it = extracting_.find(drop);
        it->second->EndOperation(files.empty() ? E_FAIL : S_OK, nullptr,
                                 files.empty() ? DROPEFFECT_NONE : DROPEFFECT_COPY);
        extracting_.erase(it);
        EmitDrop(at, files);
      });
}

void DropPlugin::EmitDrop(LogicalPoint at, const std::vector<DroppedFile>& files) {
  EncodableList items;
  for (const DroppedFile& file : files) {
    const std::optional<std::string> path = Utf8(file.path);
    const std::optional<std::string> name = Utf8(file.name);
    if (!path || !name) continue;
    items.push_back(EncodableValue(EncodableMap{
        {EncodableValue("path"), EncodableValue(*path)},
        {EncodableValue("name"), EncodableValue(*name)},
        {EncodableValue("isTemporaryCopy"), EncodableValue(file.is_temporary_copy)},
        {EncodableValue("isDirectory"), EncodableValue(file.is_directory)},
    }));
  }
  Emit({
      {EncodableValue("type"), EncodableValue("drop")},
      {EncodableValue("x"), EncodableValue(at.x)},
      {EncodableValue("y"), EncodableValue(at.y)},
      {EncodableValue("items"), EncodableValue(std::move(items))},
  });
}

void DropPlugin::Emit(EncodableMap event) {
  if (sink_) sink_->Success(EncodableValue(std::move(event)));
}

}  // namespace ux
