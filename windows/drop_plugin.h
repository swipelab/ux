#ifndef UX_DROP_PLUGIN_H_
#define UX_DROP_PLUGIN_H_

#include <windows.h>

#include <objidl.h>
#include <shldisp.h>
#include <wrl/client.h>

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <vector>

#include "drop_data.h"
#include "platform_thread.h"

namespace ux {

class DropTarget;

// `ux/drop/events` and `ux/drop`: files dragged onto the Flutter view. The
// first listen registers an OLE drop target on the view's window, which a
// cancel or the top-level window's destruction revokes. While Dart has an
// active region (`setHasRegions`), a drag that offers files is answered with
// copy and reports enter, update, exit and drop; otherwise it is answered with
// none.
class DropPlugin : public flutter::Plugin {
 public:
  explicit DropPlugin(flutter::PluginRegistrarWindows* registrar);
  ~DropPlugin() override;

  DropPlugin(const DropPlugin&) = delete;
  DropPlugin& operator=(const DropPlugin&) = delete;

 private:
  friend class DropTarget;

  void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  std::optional<LRESULT> HandleWindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam);
  HRESULT Register();
  void Revoke();

  // The drop target's calls, on the platform thread. Each answers the effect
  // for the drag's source.
  DWORD DragEnter(IDataObject* data, POINTL point, DWORD allowed);
  DWORD DragOver(POINTL point, DWORD allowed);
  void DragLeave();
  DWORD Drop(IDataObject* data, POINTL point, DWORD allowed);

  // Emits [type] at [point] and answers copy for a drag the view accepts.
  DWORD Report(const char* type, POINTL point, DWORD allowed);
  // Whether the view accepts the drag: it offers files, Dart has an active
  // region and the source allows a copy.
  bool Accepts(DWORD allowed) const;
  LogicalPoint Logical(POINTL point) const;
  void ExtractVirtualFiles(IDataObject* data, LogicalPoint at);
  void EmitDrop(LogicalPoint at, const std::vector<DroppedFile>& files);
  void Emit(flutter::EncodableMap event);

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
  int window_proc_;
  // The view's window, while the drop target is registered on it.
  std::optional<HWND> view_;
  bool has_regions_ = true;
  // Whether the drag over the view offers files.
  bool offers_files_ = false;
  // The sources writing their virtual files off the platform thread, by drop.
  std::map<uint64_t, Microsoft::WRL::ComPtr<IDataObjectAsyncCapability>> extracting_;
  uint64_t next_drop_ = 0;
  PlatformThread platform_;
};

}  // namespace ux

#endif  // UX_DROP_PLUGIN_H_
