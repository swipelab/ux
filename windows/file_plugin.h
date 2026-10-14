#ifndef UX_FILE_PLUGIN_H_
#define UX_FILE_PLUGIN_H_

#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>
#include <string>

#include "platform_thread.h"

namespace ux {

// `ux/file`: `pick` and `pickMultiple` through the open dialog, `open` with
// the file's associated application, `saveCopy` through the save dialog, and
// `showInFolder` in Explorer.
class FilePlugin : public flutter::Plugin {
 public:
  explicit FilePlugin(flutter::PluginRegistrarWindows* registrar);
  ~FilePlugin() override;

  FilePlugin(const FilePlugin&) = delete;
  FilePlugin& operator=(const FilePlugin&) = delete;

 private:
  using Result = flutter::MethodResult<flutter::EncodableValue>;

  void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call, std::unique_ptr<Result> result);
  void Pick(const flutter::EncodableMap* args, bool multiple, std::shared_ptr<Result> result);
  void Open(const std::wstring& path, Result& result);
  void SaveCopy(const std::wstring& path, std::shared_ptr<Result> result);
  void ShowInFolder(const std::wstring& path, Result& result);

  // The window that owns the dialogs: the top-level window of the Flutter view.
  HWND Owner() const;

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  PlatformThread platform_;
};

}  // namespace ux

#endif  // UX_FILE_PLUGIN_H_
