#include "video_player_instance.h"

#include <mfapi.h>
#include <mfmediaengine.h>
#include <wrl/implements.h>

#include <cmath>
#include <utility>

#include "text.h"

namespace ux {

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

constexpr LONGLONG kFramePeriod100ns = 80000;
constexpr ULONGLONG kPositionPeriodMs = 100;

class EngineNotify
    : public Microsoft::WRL::RuntimeClass<Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
                                          IMFMediaEngineNotify> {
 public:
  explicit EngineNotify(std::function<void(DWORD, DWORD_PTR, DWORD)> on_event) : on_event_(std::move(on_event)) {}

  STDMETHODIMP EventNotify(DWORD event, DWORD_PTR param1, DWORD param2) override {
    on_event_(event, param1, param2);
    return S_OK;
  }

 private:
  const std::function<void(DWORD, DWORD_PTR, DWORD)> on_event_;
};

std::string EngineError(DWORD_PTR code, HRESULT hr) {
  const char* name;
  switch (code) {
    case MF_MEDIA_ENGINE_ERR_ABORTED:
      name = "aborted";
      break;
    case MF_MEDIA_ENGINE_ERR_NETWORK:
      name = "network error";
      break;
    case MF_MEDIA_ENGINE_ERR_DECODE:
      name = "decode error";
      break;
    case MF_MEDIA_ENGINE_ERR_SRC_NOT_SUPPORTED:
      name = "source not supported";
      break;
    case MF_MEDIA_ENGINE_ERR_ENCRYPTED:
      name = "encrypted source";
      break;
    default:
      name = "media engine error";
  }
  return std::string(name) + " (" + Hex(hr) + ")";
}

int64_t Milliseconds(double seconds) { return std::llround(seconds * 1000); }

}  // namespace

EncodableMap VideoSize(UINT width, UINT height) {
  return {
      {EncodableValue("width"), EncodableValue(static_cast<double>(width))},
      {EncodableValue("height"), EncodableValue(static_cast<double>(height))},
  };
}

HRESULT VideoPlayerInstance::Create(std::shared_ptr<VideoDevice> device, PlatformThread::Poster post, Emit emit,
                                    std::shared_ptr<VideoPlayerInstance>& instance) {
  std::shared_ptr<VideoPlayerInstance> created(
      new VideoPlayerInstance(std::move(device), std::move(post), std::move(emit)));
  const HRESULT hr = created->Start();
  if (FAILED(hr)) return hr;
  instance = std::move(created);
  return S_OK;
}

VideoPlayerInstance::VideoPlayerInstance(std::shared_ptr<VideoDevice> device, PlatformThread::Poster post, Emit emit)
    : device_(std::move(device)),
      post_(std::move(post)),
      emit_(std::move(emit)),
      surface_(std::make_shared<VideoSurface>(device_->device())),
      stop_(CreateEventW(nullptr, TRUE, FALSE, nullptr)) {}

VideoPlayerInstance::~VideoPlayerInstance() {
  Dispose();
  CloseHandle(stop_);
}

HRESULT VideoPlayerInstance::Start() {
  ComPtr<IMFAttributes> attributes;
  HRESULT hr = MFCreateAttributes(&attributes, 3);
  if (FAILED(hr)) return hr;
  hr = attributes->SetUnknown(MF_MEDIA_ENGINE_DXGI_MANAGER, device_->manager().Get());
  if (FAILED(hr)) return hr;
  auto notify = Microsoft::WRL::Make<EngineNotify>(
      [post = post_, weak = weak_from_this()](DWORD event, DWORD_PTR param1, DWORD param2) {
        post([weak, event, param1, param2]() {
          if (auto self = weak.lock()) self->OnEvent(event, param1, param2);
        });
      });
  hr = attributes->SetUnknown(MF_MEDIA_ENGINE_CALLBACK, notify.Get());
  if (FAILED(hr)) return hr;
  hr = attributes->SetUINT32(MF_MEDIA_ENGINE_VIDEO_OUTPUT_FORMAT, DXGI_FORMAT_B8G8R8A8_UNORM);
  if (FAILED(hr)) return hr;
  ComPtr<IMFMediaEngineClassFactory> factory;
  hr = CoCreateInstance(CLSID_MFMediaEngineClassFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
  if (FAILED(hr)) return hr;
  return factory->CreateInstance(0, attributes.Get(), &engine_);
}

void VideoPlayerInstance::Open(const std::wstring& path, std::function<void()> frame_available) {
  BSTR url = SysAllocString(path.c_str());
  const HRESULT hr = engine_->SetSource(url);
  SysFreeString(url);
  if (FAILED(hr)) {
    post_([weak = weak_from_this(), message = "cannot open the video (" + Hex(hr) + ")"]() {
      if (auto self = weak.lock(); self && !self->disposed_) self->Fail(message);
    });
    return;
  }
  pump_ = std::thread(Pump, engine_, device_->context(), surface_, std::move(frame_available),
                      [post = post_, weak = weak_from_this()]() {
                        post([weak]() {
                          if (auto self = weak.lock()) self->EmitPosition();
                        });
                      },
                      stop_);
}

void VideoPlayerInstance::Prepare(std::function<void(VideoPrepared)> completion) {
  if (disposed_) {
    completion(VideoDisposed{});
    return;
  }
  completion_ = std::move(completion);
  CompletePrepare();
}

void VideoPlayerInstance::Play() {
  if (!disposed_) engine_->Play();
}

void VideoPlayerInstance::Pause() {
  if (!disposed_) engine_->Pause();
}

void VideoPlayerInstance::SeekTo(int64_t position_ms) {
  if (disposed_) return;
  const int64_t clamped = position_ms < 0 ? 0 : position_ms;
  engine_->SetCurrentTime(static_cast<double>(clamped) / 1000);
  EmitPosition(clamped);
}

void VideoPlayerInstance::SetLooping(bool loop) {
  if (!disposed_) engine_->SetLoop(loop ? TRUE : FALSE);
}

void VideoPlayerInstance::SetVolume(double volume) {
  if (!disposed_) engine_->SetVolume(volume < 0 ? 0 : volume > 1 ? 1 : volume);
}

void VideoPlayerInstance::SetPlaybackSpeed(double rate) {
  if (disposed_) return;
  const double clamped = rate < 0.25 ? 0.25 : rate > 4 ? 4 : rate;
  // Play starts at the default rate.
  engine_->SetDefaultPlaybackRate(clamped);
  engine_->SetPlaybackRate(clamped);
}

void VideoPlayerInstance::Dispose() {
  if (disposed_) return;
  disposed_ = true;
  if (pump_.joinable()) {
    SetEvent(stop_);
    pump_.join();
  }
  if (engine_) engine_->Shutdown();
  if (completion_) std::exchange(completion_, nullptr)(VideoDisposed{});
}

void VideoPlayerInstance::OnEvent(DWORD event, DWORD_PTR param1, DWORD param2) {
  if (disposed_) return;
  switch (event) {
    case MF_MEDIA_ENGINE_EVENT_CANPLAY:
      can_play_ = true;
      CompletePrepare();
      ReportBuffering(false);
      break;
    case MF_MEDIA_ENGINE_EVENT_ERROR:
      Fail(EngineError(param1, static_cast<HRESULT>(param2)));
      break;
    case MF_MEDIA_ENGINE_EVENT_PLAY:
    case MF_MEDIA_ENGINE_EVENT_PAUSE:
      ReportPlaying();
      break;
    case MF_MEDIA_ENGINE_EVENT_PLAYING:
      ReportBuffering(false);
      ReportPlaying();
      break;
    case MF_MEDIA_ENGINE_EVENT_WAITING:
      ReportBuffering(true);
      break;
    case MF_MEDIA_ENGINE_EVENT_ENDED:
      ReportPlaying();
      emit_({{EncodableValue("event"), EncodableValue("completed")}});
      break;
    case MF_MEDIA_ENGINE_EVENT_FORMATCHANGE:
      if (ready_) EmitSize();
      break;
  }
}

void VideoPlayerInstance::Fail(std::string message) {
  if (!ready_ && !failure_) failure_ = message;
  if (completion_) {
    CompletePrepare();
    return;
  }
  emit_({
      {EncodableValue("event"), EncodableValue("error")},
      {EncodableValue("code"), EncodableValue("playback_failed")},
      {EncodableValue("description"), EncodableValue(std::move(message))},
  });
}

void VideoPlayerInstance::CompletePrepare() {
  if (!completion_) return;
  if (failure_) {
    std::exchange(completion_, nullptr)(VideoFailed{*failure_});
    return;
  }
  if (!can_play_) return;
  ready_ = true;
  EmitSize();
  const auto [width, height] = *reported_size_;
  const double duration = engine_->GetDuration();
  std::exchange(completion_, nullptr)(VideoReady{
      width, height, std::isfinite(duration) ? std::optional<int64_t>(Milliseconds(duration)) : std::nullopt});
}

void VideoPlayerInstance::ReportPlaying() {
  const bool playing = !engine_->IsPaused() && !engine_->IsEnded();
  if (playing == reported_playing_) return;
  reported_playing_ = playing;
  emit_({
      {EncodableValue("event"), EncodableValue("stateChanged")},
      {EncodableValue("isPlaying"), EncodableValue(playing)},
      {EncodableValue("positionMs"), EncodableValue(Milliseconds(engine_->GetCurrentTime()))},
  });
}

void VideoPlayerInstance::ReportBuffering(bool buffering) {
  if (buffering == reported_buffering_) return;
  reported_buffering_ = buffering;
  emit_({
      {EncodableValue("event"), EncodableValue("stateChanged")},
      {EncodableValue("isBuffering"), EncodableValue(buffering)},
      {EncodableValue("positionMs"), EncodableValue(Milliseconds(engine_->GetCurrentTime()))},
  });
}

void VideoPlayerInstance::EmitSize() {
  DWORD width = 0;
  DWORD height = 0;
  engine_->GetNativeVideoSize(&width, &height);
  const std::pair<UINT, UINT> size(width, height);
  if (reported_size_ == size) return;
  reported_size_ = size;
  emit_({
      {EncodableValue("event"), EncodableValue("sizeChanged")},
      {EncodableValue("size"), EncodableValue(VideoSize(size.first, size.second))},
  });
}

void VideoPlayerInstance::EmitPosition(std::optional<int64_t> position_ms) {
  if (!ready_ || disposed_) return;
  EncodableList buffered;
  ComPtr<IMFMediaTimeRange> ranges;
  if (SUCCEEDED(engine_->GetBuffered(&ranges))) {
    for (DWORD i = 0; i < ranges->GetLength(); i++) {
      double start = 0;
      double end = 0;
      if (FAILED(ranges->GetStart(i, &start)) || FAILED(ranges->GetEnd(i, &end))) continue;
      buffered.push_back(EncodableValue(EncodableMap{
          {EncodableValue("startMs"), EncodableValue(Milliseconds(start))},
          {EncodableValue("endMs"), EncodableValue(Milliseconds(end))},
      }));
    }
  }
  emit_({
      {EncodableValue("event"), EncodableValue("stateChanged")},
      {EncodableValue("positionMs"), EncodableValue(position_ms.value_or(Milliseconds(engine_->GetCurrentTime())))},
      {EncodableValue("buffered"), EncodableValue(std::move(buffered))},
  });
}

void VideoPlayerInstance::Pump(ComPtr<IMFMediaEngine> engine, ComPtr<ID3D11DeviceContext> context,
                               std::shared_ptr<VideoSurface> surface, std::function<void()> frame_available,
                               std::function<void()> tick, HANDLE stop) {
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  HANDLE timer = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
  const HANDLE handles[] = {stop, timer};
  ULONGLONG next_tick = GetTickCount64() + kPositionPeriodMs;
  for (;;) {
    LARGE_INTEGER due;
    due.QuadPart = -kFramePeriod100ns;
    SetWaitableTimer(timer, &due, 0, nullptr, nullptr, FALSE);
    if (WaitForMultipleObjects(2, handles, FALSE, INFINITE) != WAIT_OBJECT_0 + 1) break;
    LONGLONG pts = 0;
    DWORD width = 0;
    DWORD height = 0;
    ComPtr<ID3D11Texture2D> target;
    if (engine->OnVideoStreamTick(&pts) == S_OK && SUCCEEDED(engine->GetNativeVideoSize(&width, &height)) &&
        width > 0 && height > 0 && SUCCEEDED(surface->Target(width, height, target))) {
      const RECT rect = {0, 0, static_cast<LONG>(width), static_cast<LONG>(height)};
      const MFARGB black = {0, 0, 0, 255};
      if (SUCCEEDED(engine->TransferVideoFrame(target.Get(), nullptr, &rect, &black))) {
        context->Flush();
        surface->Show();
        frame_available();
      }
    }
    if (GetTickCount64() >= next_tick) {
      next_tick += kPositionPeriodMs;
      tick();
    }
  }
  CloseHandle(timer);
  if (SUCCEEDED(initialized)) CoUninitialize();
}

}  // namespace ux
