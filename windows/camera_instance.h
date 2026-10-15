#ifndef UX_CAMERA_INSTANCE_H_
#define UX_CAMERA_INSTANCE_H_

#include <windows.h>

#include <flutter/encodable_value.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <variant>
#include <vector>

#include "camera_devices.h"
#include "camera_texture.h"
#include "platform_thread.h"
#include "work_queue.h"

namespace ux {

struct CameraError {
  HRESULT hr;
  std::string message;
};

struct FrameSize {
  UINT width;
  UINT height;
};

template <typename T>
using CameraResult = std::variant<T, CameraError>;

// A frame size and rate a camera offers.
struct VideoFormat {
  UINT width;
  UINT height;
  double rate;
};

// The format a preview opens at: the one with the most pixels within
// 1920×1080, then the highest rate, among those of at least 15 frames a
// second where any is, or none when no format fits within 1920×1080.
std::optional<size_t> PreferredFormat(const std::vector<VideoFormat>& formats);

// Sets [path] to a capture's file, `ux_camera_<GUID>.<extension>` in the
// directory GetTempPathW answers.
HRESULT CapturePath(const wchar_t* extension, std::wstring& path);

// [devices] as `availableCameras` answers them: each the back lens, as for any
// camera with no position, with a sensorOrientation of 0.
flutter::EncodableList CamerasWire(const std::vector<CameraDevice>& devices);

// A size as `ux/camera` carries it.
flutter::EncodableMap SizeWire(UINT width, UINT height);

flutter::EncodableMap PreviewSizeChangedEvent(UINT width, UINT height);
flutter::EncodableMap SessionErrorEvent(const std::string& description);
flutter::EncodableMap DiagnosticEvent(const std::string& message);

// [event] as `ux/camera/events` carries it for [handle], -1 for the plugin.
flutter::EncodableValue CameraEvent(int64_t handle, flutter::EncodableMap event);

class CaptureSession;

// One per Dart XCameraController: a capture engine (IMFCaptureEngine) on a
// WorkQueue of its own, whose preview lands in its CameraTexture. Its methods
// are called on the platform thread, where it calls back and emits its events,
// without their handle.
class CameraInstance {
 public:
  using Emit = std::function<void(flutter::EncodableMap)>;
  using Done = std::function<void(std::optional<CameraError>)>;
  using Opened = std::function<void(CameraResult<FrameSize>)>;
  using Written = std::function<void(CameraResult<std::wstring>)>;

  CameraInstance(PlatformThread::Poster post, Emit emit, std::shared_ptr<CameraTexture> texture);
  // Releases the device, leaving a recording's file, and joins the queue,
  // calling nothing back.
  ~CameraInstance();

  CameraInstance(const CameraInstance&) = delete;
  CameraInstance& operator=(const CameraInstance&) = delete;

  // Opens the camera at [link], with the default microphone where [audio] and
  // one opens, and answers the preview's size.
  void Open(std::wstring link, bool audio, Opened done);

  void StartPreview(Done done);

  // Reopens on the camera at [link], previewing if the last one was, and
  // answers the preview's size.
  void SetDevice(std::wstring link, Opened done);

  // Answers the path of the JPEG it writes.
  void TakePicture(Written done);

  // Records an H.264 MP4, with AAC sound where the microphone opened.
  void StartRecording(Done done);

  // Answers the recording's path once its file is complete.
  void StopRecording(Written done);

  // Ends a recording and deletes its file, then releases the device.
  void Close(std::function<void()> done);

 private:
  // Runs [work] on the session, on the queue's thread.
  void Run(std::function<void(CaptureSession&)> work);

  WorkQueue queue_;
  std::shared_ptr<CaptureSession> session_;
};

}  // namespace ux

#endif  // UX_CAMERA_INSTANCE_H_
