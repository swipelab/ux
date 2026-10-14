#ifndef UX_VIDEO_PLAYER_INSTANCE_H_
#define UX_VIDEO_PLAYER_INSTANCE_H_

#include <windows.h>

#include <d3d11.h>
#include <mfmediaengine.h>
#include <wrl/client.h>

#include <flutter/encodable_value.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <variant>

#include "platform_thread.h"
#include "video_device.h"
#include "video_surface.h"

namespace ux {

// What `initialize` answers once the player can play.
struct VideoReady {
  // The display size, with the track's rotation applied.
  UINT width;
  UINT height;
  // None for a source with no finite duration.
  std::optional<int64_t> duration_ms;
};

struct VideoFailed {
  std::string message;
};

struct VideoDisposed {};

using VideoPrepared = std::variant<VideoReady, VideoFailed, VideoDisposed>;

// A size as `ux/video` carries it.
flutter::EncodableMap VideoSize(UINT width, UINT height);

// One per Dart XVideoPlayerController: an IMFMediaEngine in frame-server mode
// on the shared VideoDevice, whose frames a pump thread transfers into its
// VideoSurface. The engine applies the track's rotation, so they land upright.
// Its methods are called on the platform thread, where it calls back and emits
// its events.
class VideoPlayerInstance : public std::enable_shared_from_this<VideoPlayerInstance> {
 public:
  // An event on `ux/video/events`, without its handle.
  using Emit = std::function<void(flutter::EncodableMap)>;

  // Sets [instance] to a player on [device], which reaches the platform thread
  // through [post] and hands its events to [emit].
  static HRESULT Create(std::shared_ptr<VideoDevice> device, PlatformThread::Poster post, Emit emit,
                        std::shared_ptr<VideoPlayerInstance>& instance);

  ~VideoPlayerInstance();

  VideoPlayerInstance(const VideoPlayerInstance&) = delete;
  VideoPlayerInstance& operator=(const VideoPlayerInstance&) = delete;

  const std::shared_ptr<VideoSurface>& surface() const { return surface_; }

  // Loads the file at [path] and transfers its frames, calling
  // [frame_available] on the pump thread after each one.
  void Open(const std::wstring& path, std::function<void()> frame_available);

  // Calls [completion] once the player can play, fails, or is disposed.
  void Prepare(std::function<void(VideoPrepared)> completion);

  void Play();
  void Pause();
  void SeekTo(int64_t position_ms);
  void SetLooping(bool loop);
  void SetVolume(double volume);
  void SetPlaybackSpeed(double rate);

  // Stops the pump and shuts the engine down.
  void Dispose();

 private:
  VideoPlayerInstance(std::shared_ptr<VideoDevice> device, PlatformThread::Poster post, Emit emit);

  HRESULT Start();
  void OnEvent(DWORD event, DWORD_PTR param1, DWORD param2);
  void Fail(std::string message);
  void CompletePrepare();
  void ReportPlaying();
  void ReportBuffering(bool buffering);
  void EmitSize();
  void EmitPosition(std::optional<int64_t> position_ms = std::nullopt);

  // Polls [engine] for frames and transfers each into [surface] until [stop]
  // is set, and calls [tick] every 100 ms.
  static void Pump(Microsoft::WRL::ComPtr<IMFMediaEngine> engine, Microsoft::WRL::ComPtr<ID3D11DeviceContext> context,
                   std::shared_ptr<VideoSurface> surface, std::function<void()> frame_available,
                   std::function<void()> tick, HANDLE stop);

  const std::shared_ptr<VideoDevice> device_;
  const PlatformThread::Poster post_;
  const Emit emit_;
  const std::shared_ptr<VideoSurface> surface_;
  Microsoft::WRL::ComPtr<IMFMediaEngine> engine_;
  const HANDLE stop_;
  std::thread pump_;

  std::function<void(VideoPrepared)> completion_;
  bool can_play_ = false;
  std::optional<std::string> failure_;
  bool ready_ = false;
  bool disposed_ = false;
  bool reported_playing_ = false;
  bool reported_buffering_ = false;
  std::optional<std::pair<UINT, UINT>> reported_size_;
};

}  // namespace ux

#endif  // UX_VIDEO_PLAYER_INSTANCE_H_
