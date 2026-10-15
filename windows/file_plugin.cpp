#include "file_plugin.h"

#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <flutter/standard_method_codec.h>

#include <optional>
#include <utility>
#include <vector>

#include "file_types.h"
#include "method_args.h"
#include "text.h"
#include "video_thumbnail.h"

namespace ux {

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

std::vector<std::string> MimeTypesArg(const EncodableMap* args) {
  std::vector<std::string> mime_types;
  if (const auto* list = std::get_if<EncodableList>(Arg(args, "mimeTypes"))) {
    for (const EncodableValue& value : *list) {
      if (const auto* mime_type = std::get_if<std::string>(&value)) mime_types.push_back(*mime_type);
    }
  }
  return mime_types;
}

// The system's description of [error], a Win32 error or an HRESULT.
std::string Message(DWORD error) {
  wchar_t* text = nullptr;
  const DWORD size =
      FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                     nullptr, error, 0, reinterpret_cast<LPWSTR>(&text), 0, nullptr);
  if (size == 0) return "error " + std::to_string(error);
  std::wstring message(text, size);
  LocalFree(text);
  message.erase(message.find_last_not_of(L"\r\n ") + 1);
  return Utf8(message).value_or("error " + std::to_string(error));
}

std::wstring FileName(const std::wstring& path) {
  const size_t slash = path.find_last_of(L'\\');
  return slash == std::wstring::npos ? path : path.substr(slash + 1);
}

// The extension of [name] without its dot, when it has one.
std::optional<std::wstring> Extension(const std::wstring& name) {
  const size_t dot = name.find_last_of(L'.');
  if (dot == std::wstring::npos || dot == 0 || dot + 1 == name.size()) return std::nullopt;
  return name.substr(dot + 1);
}

// A picked file as `pick` replies it: its path, name, MIME type and size.
std::optional<EncodableValue> PickedFile(const std::wstring& path) {
  const std::wstring name = FileName(path);
  const std::optional<std::string> utf8_path = Utf8(path);
  const std::optional<std::string> utf8_name = Utf8(name);
  if (!utf8_path || !utf8_name) return std::nullopt;
  EncodableMap file = {
      {EncodableValue("path"), EncodableValue(*utf8_path)},
      {EncodableValue("name"), EncodableValue(*utf8_name)},
  };
  if (const std::optional<std::wstring> extension = Extension(name)) {
    if (const std::optional<std::string> mime_type = MimeTypeOf(*extension)) {
      file[EncodableValue("mimeType")] = EncodableValue(*mime_type);
    }
  }
  WIN32_FILE_ATTRIBUTE_DATA data;
  if (GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &data)) {
    const uint64_t size = (static_cast<uint64_t>(data.nFileSizeHigh) << 32) | data.nFileSizeLow;
    file[EncodableValue("size")] = EncodableValue(static_cast<int64_t>(size));
  }
  return EncodableValue(file);
}

// A frame as `videoThumbnail` and `videoThumbnails` reply it.
EncodableValue Reply(const Thumbnail& thumbnail) {
  return EncodableValue(EncodableMap{
      {EncodableValue("png"), EncodableValue(thumbnail.png)},
      {EncodableValue("width"), EncodableValue(static_cast<int64_t>(thumbnail.width))},
      {EncodableValue("height"), EncodableValue(static_cast<int64_t>(thumbnail.height))},
  });
}

HRESULT PathOf(IShellItem* item, std::wstring& path) {
  PWSTR display_name = nullptr;
  const HRESULT hr = item->GetDisplayName(SIGDN_FILESYSPATH, &display_name);
  if (FAILED(hr)) return hr;
  path = display_name;
  CoTaskMemFree(display_name);
  return S_OK;
}

// Shows an open dialog owned by [owner] and fills [picked] with the files the
// user picked, in the dialog's order; none when the user cancelled.
HRESULT ShowOpenDialog(HWND owner, const std::vector<std::string>& mime_types, bool multiple,
                       std::vector<std::wstring>& picked) {
  ComPtr<IFileOpenDialog> dialog;
  HRESULT hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
  if (FAILED(hr)) return hr;
  FILEOPENDIALOGOPTIONS options;
  hr = dialog->GetOptions(&options);
  if (FAILED(hr)) return hr;
  options |= FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST | FOS_PATHMUSTEXIST;
  if (multiple) options |= FOS_ALLOWMULTISELECT;
  hr = dialog->SetOptions(options);
  if (FAILED(hr)) return hr;
  if (const std::optional<std::vector<std::wstring>> extensions = PickExtensions(mime_types)) {
    std::wstring spec;
    for (const std::wstring& extension : *extensions) {
      spec += (spec.empty() ? L"*." : L";*.") + extension;
    }
    const COMDLG_FILTERSPEC filter = {spec.c_str(), spec.c_str()};
    hr = dialog->SetFileTypes(1, &filter);
    if (FAILED(hr)) return hr;
  }
  hr = dialog->Show(owner);
  if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return S_OK;
  if (FAILED(hr)) return hr;
  ComPtr<IShellItemArray> items;
  hr = dialog->GetResults(&items);
  if (FAILED(hr)) return hr;
  DWORD count = 0;
  hr = items->GetCount(&count);
  if (FAILED(hr)) return hr;
  for (DWORD i = 0; i < count; i++) {
    ComPtr<IShellItem> item;
    hr = items->GetItemAt(i, &item);
    if (FAILED(hr)) return hr;
    std::wstring path;
    hr = PathOf(item.Get(), path);
    if (FAILED(hr)) return hr;
    picked.push_back(std::move(path));
  }
  return S_OK;
}

// Shows a save dialog owned by [owner] that holds [source]'s name, and sets
// [destination] to the path the user chose; none when the user cancelled.
HRESULT ShowSaveDialog(HWND owner, const std::wstring& source, std::optional<std::wstring>& destination) {
  ComPtr<IFileSaveDialog> dialog;
  HRESULT hr = CoCreateInstance(CLSID_FileSaveDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
  if (FAILED(hr)) return hr;
  FILEOPENDIALOGOPTIONS options;
  hr = dialog->GetOptions(&options);
  if (FAILED(hr)) return hr;
  hr = dialog->SetOptions(options | FOS_FORCEFILESYSTEM | FOS_OVERWRITEPROMPT);
  if (FAILED(hr)) return hr;
  const std::wstring name = FileName(source);
  hr = dialog->SetFileName(name.c_str());
  if (FAILED(hr)) return hr;
  if (const std::optional<std::wstring> extension = Extension(name)) {
    hr = dialog->SetDefaultExtension(extension->c_str());
    if (FAILED(hr)) return hr;
  }
  hr = dialog->Show(owner);
  if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return S_OK;
  if (FAILED(hr)) return hr;
  ComPtr<IShellItem> item;
  hr = dialog->GetResult(&item);
  if (FAILED(hr)) return hr;
  std::wstring path;
  hr = PathOf(item.Get(), path);
  if (FAILED(hr)) return hr;
  destination = std::move(path);
  return S_OK;
}

}  // namespace

FilePlugin::FilePlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar),
      channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          registrar->messenger(), "ux/file", &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) { HandleMethodCall(call, std::move(result)); });
}

void FilePlugin::HandleMethodCall(const flutter::MethodCall<EncodableValue>& call, std::unique_ptr<Result> result) {
  const std::string& method = call.method_name();
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  if (method == "pick" || method == "pickMultiple") {
    Pick(args, method == "pickMultiple", std::move(result));
    return;
  }
  if (method != "open" && method != "saveCopy" && method != "showInFolder" && method != "videoThumbnail" &&
      method != "videoThumbnails") {
    result->NotImplemented();
    return;
  }
  const std::optional<std::wstring> path = PathArg(args, "path");
  if (!path) {
    result->Error("bad_args", "path is required");
    return;
  }
  if (method == "open") {
    Open(*path, *result);
  } else if (method == "saveCopy") {
    SaveCopy(*path, std::move(result));
  } else if (method == "showInFolder") {
    ShowInFolder(*path, *result);
  } else if (method == "videoThumbnail") {
    VideoThumbnail(*path, args, std::move(result));
  } else {
    VideoThumbnails(*path, args, std::move(result));
  }
}

void FilePlugin::Pick(const EncodableMap* args, bool multiple, std::shared_ptr<Result> result) {
  std::vector<std::wstring> picked;
  const HRESULT hr = ShowOpenDialog(Owner(), MimeTypesArg(args), multiple, picked);
  if (FAILED(hr)) {
    result->Error("pick_failed", Message(static_cast<DWORD>(hr)));
    return;
  }
  platform_.Background<EncodableValue>(
      [picked = std::move(picked), multiple]() {
        EncodableList files;
        for (const std::wstring& path : picked) {
          if (std::optional<EncodableValue> file = PickedFile(path)) files.push_back(std::move(*file));
        }
        if (multiple) return EncodableValue(std::move(files));
        return files.empty() ? EncodableValue() : files.front();
      },
      [result](EncodableValue reply) { result->Success(reply); });
}

void FilePlugin::Open(const std::wstring& path, Result& result) {
  SHELLEXECUTEINFOW info = {sizeof(info)};
  info.hwnd = Owner();
  info.lpFile = path.c_str();
  info.nShow = SW_SHOWNORMAL;
  if (ShellExecuteExW(&info)) {
    result.Success(EncodableValue(true));
    return;
  }
  const DWORD error = GetLastError();
  switch (error) {
    case ERROR_NO_ASSOCIATION:
      result.Success(EncodableValue(false));
      break;
    case ERROR_CANCELLED:
      result.Success(EncodableValue(true));
      break;
    default:
      result.Error("open_failed", Message(error));
  }
}

void FilePlugin::SaveCopy(const std::wstring& path, std::shared_ptr<Result> result) {
  platform_.Background<bool>(
      [path]() { return GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES; },
      [this, path, result](bool exists) {
        if (!exists) {
          result->Error("not_found", "no file at path");
          return;
        }
        std::optional<std::wstring> destination;
        const HRESULT hr = ShowSaveDialog(Owner(), path, destination);
        if (FAILED(hr)) {
          result->Error("save_failed", Message(static_cast<DWORD>(hr)));
          return;
        }
        if (!destination) {
          result->Success(EncodableValue("cancelled"));
          return;
        }
        platform_.Background<DWORD>(
            [path, destination = std::move(*destination)]() {
              return CopyFileW(path.c_str(), destination.c_str(), FALSE) ? ERROR_SUCCESS : GetLastError();
            },
            [result](DWORD error) {
              if (error == ERROR_SUCCESS) {
                result->Success(EncodableValue("saved"));
              } else {
                result->Error("save_failed", Message(error));
              }
            });
      });
}

void FilePlugin::ShowInFolder(const std::wstring& path, Result& result) {
  PIDLIST_ABSOLUTE item = nullptr;
  HRESULT hr = SHParseDisplayName(path.c_str(), nullptr, &item, 0, nullptr);
  if (SUCCEEDED(hr)) {
    hr = SHOpenFolderAndSelectItems(item, 0, nullptr, 0);
    CoTaskMemFree(item);
  }
  result.Success(EncodableValue(SUCCEEDED(hr)));
}

void FilePlugin::VideoThumbnail(const std::wstring& path, const EncodableMap* args, std::unique_ptr<Result> result) {
  const std::optional<int64_t> max_width = IntArg(args, "maxWidth");
  const std::optional<std::vector<double>> transform = DoublesArg(args, "transform");
  const std::optional<int64_t> out_width = IntArg(args, "outWidth");
  const std::optional<int64_t> out_height = IntArg(args, "outHeight");
  const std::optional<int64_t> max_longest = IntArg(args, "maxLongest");
  if ((max_width && *max_width <= 0) || (max_longest && *max_longest <= 0)) {
    result->Error("bad_args", "maxWidth and maxLongest must be positive");
    return;
  }
  std::optional<ThumbnailBake> bake;
  if (transform && transform->size() == 9 && out_width && out_height) {
    if (*out_width <= 0 || *out_height <= 0) {
      result->Error("bad_args", "outWidth and outHeight must be positive");
      return;
    }
    const std::vector<double>& t = *transform;
    bake = ThumbnailBake{Affine{t[0], t[1], t[2], t[3], t[4], t[5]}, static_cast<UINT>(*out_width),
                         static_cast<UINT>(*out_height), PathArg(args, "overlayPath"),
                         max_longest ? std::optional<UINT>(static_cast<UINT>(*max_longest)) : std::nullopt};
  }
  platform_.Background<ThumbnailResult>(
      [path, at_ms = IntArg(args, "atMs").value_or(0),
       max_width = max_width ? std::optional<UINT>(static_cast<UINT>(*max_width)) : std::nullopt, bake]() {
        return ux::VideoThumbnail(path, at_ms, max_width, bake);
      },
      [result = std::shared_ptr<Result>(std::move(result))](ThumbnailResult thumbnail) {
        if (const auto* failed = std::get_if<ThumbnailFailed>(&thumbnail)) {
          result->Error("decode_failed", "could not extract frame: " + failed->message);
          return;
        }
        const auto* made = std::get_if<std::optional<Thumbnail>>(&thumbnail);
        result->Success(*made ? Reply(**made) : EncodableValue());
      });
}

void FilePlugin::VideoThumbnails(const std::wstring& path, const EncodableMap* args, std::unique_ptr<Result> result) {
  const std::optional<std::vector<int64_t>> timestamps = IntsArg(args, "timestampsMs");
  const int64_t max_width = IntArg(args, "maxWidth").value_or(128);
  if (!timestamps) {
    result->Error("bad_args", "path and timestampsMs required");
    return;
  }
  if (max_width <= 0) {
    result->Error("bad_args", "maxWidth must be positive");
    return;
  }
  platform_.Background<EncodableValue>(
      [path, timestamps = *timestamps, max_width = static_cast<UINT>(max_width)]() {
        EncodableList frames;
        for (const std::optional<Thumbnail>& thumbnail : ux::VideoThumbnails(path, timestamps, max_width)) {
          frames.push_back(thumbnail ? Reply(*thumbnail) : EncodableValue());
        }
        return EncodableValue(std::move(frames));
      },
      [result = std::shared_ptr<Result>(std::move(result))](EncodableValue frames) { result->Success(frames); });
}

HWND FilePlugin::Owner() const {
  flutter::FlutterView* view = registrar_->GetView();
  return view == nullptr ? nullptr : GetAncestor(view->GetNativeWindow(), GA_ROOT);
}

}  // namespace ux
