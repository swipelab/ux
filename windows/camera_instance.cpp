#include "camera_instance.h"

#include <mfapi.h>
#include <mfcaptureengine.h>
#include <mferror.h>
#include <mfidl.h>
#include <mmdeviceapi.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <wrl/implements.h>

#include <tuple>
#include <utility>

#include "text.h"

namespace ux {

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ClassicCom;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::RuntimeClass;
using Microsoft::WRL::RuntimeClassFlags;

constexpr DWORD kPreviewStream = static_cast<DWORD>(MF_CAPTURE_ENGINE_PREFERRED_SOURCE_STREAM_FOR_VIDEO_PREVIEW);
constexpr DWORD kRecordStream = static_cast<DWORD>(MF_CAPTURE_ENGINE_PREFERRED_SOURCE_STREAM_FOR_VIDEO_RECORD);
constexpr DWORD kPhotoStream = static_cast<DWORD>(MF_CAPTURE_ENGINE_PREFERRED_SOURCE_STREAM_FOR_PHOTO);
constexpr DWORD kAudioStream = static_cast<DWORD>(MF_CAPTURE_ENGINE_PREFERRED_SOURCE_STREAM_FOR_AUDIO);

// H.264 at 0.15 bits a pixel a frame: 9.3 Mbit/s for 1920×1080 at 30 frames a
// second.
constexpr double kBitsPerPixel = 0.15;

using Pending = std::function<void(HRESULT)>;

// Runs and clears [pending] with [status].
void Complete(Pending& pending, HRESULT status) {
  if (Pending run = std::exchange(pending, nullptr)) run(status);
}

CameraError Error(HRESULT hr, const std::string& what) { return {hr, what + " (" + Hex(hr) + ")"}; }

class EngineEvents : public RuntimeClass<RuntimeClassFlags<ClassicCom>, IMFCaptureEngineOnEventCallback> {
 public:
  explicit EngineEvents(std::function<void(GUID, HRESULT)> on_event) : on_event_(std::move(on_event)) {}

  STDMETHODIMP OnEvent(IMFMediaEvent* event) override {
    GUID type = GUID_NULL;
    HRESULT status = S_OK;
    if (SUCCEEDED(event->GetExtendedType(&type)) && SUCCEEDED(event->GetStatus(&status))) on_event_(type, status);
    return S_OK;
  }

 private:
  const std::function<void(GUID, HRESULT)> on_event_;
};

// Writes the preview's RGB32 samples into its texture.
class PreviewSamples : public RuntimeClass<RuntimeClassFlags<ClassicCom>, IMFCaptureEngineOnSampleCallback> {
 public:
  PreviewSamples(std::shared_ptr<CameraTexture> texture, FrameSize size, std::function<void(FrameSize)> resized)
      : texture_(std::move(texture)), size_(size), resized_(std::move(resized)) {}

  STDMETHODIMP OnSample(IMFSample* sample) override {
    ComPtr<IMFMediaBuffer> buffer;
    if (sample == nullptr || FAILED(sample->ConvertToContiguousBuffer(&buffer))) return S_OK;
    ComPtr<IMF2DBuffer> lines;
    BYTE* top = nullptr;
    LONG pitch = 0;
    if (SUCCEEDED(buffer.As(&lines)) && SUCCEEDED(lines->Lock2D(&top, &pitch))) {
      Write(top, pitch);
      lines->Unlock2D();
      return S_OK;
    }
    DWORD length = 0;
    if (SUCCEEDED(buffer->Lock(&top, nullptr, &length))) {
      const LONG stride = static_cast<LONG>(size_.width * 4);
      if (length >= static_cast<DWORD>(stride) * size_.height) Write(top, stride);
      buffer->Unlock();
    }
    return S_OK;
  }

 private:
  void Write(const BYTE* top, LONG pitch) {
    if (texture_->Write(top, pitch, size_.width, size_.height)) resized_(size_);
  }

  const std::shared_ptr<CameraTexture> texture_;
  const FrameSize size_;
  const std::function<void(FrameSize)> resized_;
};

HRESULT VideoSource(const std::wstring& link, ComPtr<IMFMediaSource>& source) {
  ComPtr<IMFAttributes> attributes;
  HRESULT hr = MFCreateAttributes(&attributes, 2);
  if (FAILED(hr)) return hr;
  hr = attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
  if (FAILED(hr)) return hr;
  hr = attributes->SetString(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, link.c_str());
  if (FAILED(hr)) return hr;
  return MFCreateDeviceSource(attributes.Get(), &source);
}

// The default microphone: the console role's default capture endpoint.
HRESULT MicrophoneSource(ComPtr<IMFMediaSource>& source) {
  ComPtr<IMMDeviceEnumerator> enumerator;
  HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&enumerator));
  if (FAILED(hr)) return hr;
  ComPtr<IMMDevice> device;
  hr = enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &device);
  if (FAILED(hr)) return hr;
  wchar_t* endpoint = nullptr;
  hr = device->GetId(&endpoint);
  if (FAILED(hr)) return hr;
  ComPtr<IMFAttributes> attributes;
  hr = MFCreateAttributes(&attributes, 2);
  if (SUCCEEDED(hr)) {
    hr = attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_AUDCAP_GUID);
  }
  if (SUCCEEDED(hr)) hr = attributes->SetString(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_AUDCAP_ENDPOINT_ID, endpoint);
  CoTaskMemFree(endpoint);
  if (FAILED(hr)) return hr;
  return MFCreateDeviceSource(attributes.Get(), &source);
}

HRESULT CreateEngine(ComPtr<IMFCaptureEngine>& engine) {
  ComPtr<IMFCaptureEngineClassFactory> factory;
  HRESULT hr =
      CoCreateInstance(CLSID_MFCaptureEngineClassFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
  if (FAILED(hr)) return hr;
  return factory->CreateInstance(CLSID_MFCaptureEngine, IID_PPV_ARGS(&engine));
}

// A video type of [subtype] at [current]'s size and rate, progressive, with
// square pixels.
HRESULT VideoType(IMFMediaType* current, const GUID& subtype, ComPtr<IMFMediaType>& type) {
  UINT32 width = 0;
  UINT32 height = 0;
  UINT32 numerator = 0;
  UINT32 denominator = 0;
  HRESULT hr = MFGetAttributeSize(current, MF_MT_FRAME_SIZE, &width, &height);
  if (FAILED(hr)) return hr;
  hr = MFGetAttributeRatio(current, MF_MT_FRAME_RATE, &numerator, &denominator);
  if (FAILED(hr)) return hr;
  hr = MFCreateMediaType(&type);
  if (FAILED(hr)) return hr;
  hr = type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  if (FAILED(hr)) return hr;
  hr = type->SetGUID(MF_MT_SUBTYPE, subtype);
  if (FAILED(hr)) return hr;
  hr = MFSetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, width, height);
  if (FAILED(hr)) return hr;
  hr = MFSetAttributeRatio(type.Get(), MF_MT_FRAME_RATE, numerator, denominator);
  if (FAILED(hr)) return hr;
  hr = MFSetAttributeRatio(type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  if (FAILED(hr)) return hr;
  return type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
}

// A JPEG at [current]'s size.
HRESULT JpegType(IMFMediaType* current, ComPtr<IMFMediaType>& type) {
  UINT32 width = 0;
  UINT32 height = 0;
  HRESULT hr = MFGetAttributeSize(current, MF_MT_FRAME_SIZE, &width, &height);
  if (FAILED(hr)) return hr;
  hr = MFCreateMediaType(&type);
  if (FAILED(hr)) return hr;
  hr = type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Image);
  if (FAILED(hr)) return hr;
  hr = type->SetGUID(MF_MT_SUBTYPE, GUID_ContainerFormatJpeg);
  if (FAILED(hr)) return hr;
  return MFSetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, width, height);
}

// The first type Media Foundation's AAC encoders offer.
HRESULT AacType(ComPtr<IMFMediaType>& type) {
  ComPtr<IMFCollection> types;
  HRESULT hr = MFTranscodeGetAudioOutputAvailableTypes(MFAudioFormat_AAC,
                                                       MFT_ENUM_FLAG_ALL | MFT_ENUM_FLAG_SORTANDFILTER, nullptr, &types);
  if (FAILED(hr)) return hr;
  ComPtr<IUnknown> first;
  hr = types->GetElement(0, &first);
  if (FAILED(hr)) return hr;
  return first.As(&type);
}

}  // namespace

std::optional<size_t> PreferredFormat(const std::vector<VideoFormat>& formats) {
  const auto rank = [](const VideoFormat& format) {
    return std::make_tuple(format.rate >= 15, static_cast<uint64_t>(format.width) * format.height, format.rate);
  };
  std::optional<size_t> preferred;
  for (size_t i = 0; i < formats.size(); i++) {
    if (formats[i].width > 1920 || formats[i].height > 1080) continue;
    if (!preferred || rank(formats[i]) > rank(formats[*preferred])) preferred = i;
  }
  return preferred;
}

HRESULT CapturePath(const wchar_t* extension, std::wstring& path) {
  wchar_t directory[MAX_PATH + 1];
  const DWORD length = GetTempPathW(MAX_PATH + 1, directory);
  if (length == 0) return HRESULT_FROM_WIN32(GetLastError());
  GUID guid;
  const HRESULT hr = CoCreateGuid(&guid);
  if (FAILED(hr)) return hr;
  // `{` and `}` around the GUID's 36 characters.
  wchar_t braced[39];
  StringFromGUID2(guid, braced, 39);
  path = std::wstring(directory, length) + L"ux_camera_" + std::wstring(braced + 1, 36) + L"." + extension;
  return S_OK;
}

EncodableList CamerasWire(const std::vector<CameraDevice>& devices) {
  EncodableList cameras;
  for (const CameraDevice& device : devices) {
    cameras.push_back(EncodableValue(EncodableMap{
        {EncodableValue("id"), EncodableValue(device.id)},
        {EncodableValue("lens"), EncodableValue("back")},
        {EncodableValue("sensorOrientation"), EncodableValue(0)},
    }));
  }
  return cameras;
}

EncodableMap SizeWire(UINT width, UINT height) {
  return {
      {EncodableValue("width"), EncodableValue(static_cast<double>(width))},
      {EncodableValue("height"), EncodableValue(static_cast<double>(height))},
  };
}

EncodableMap PreviewSizeChangedEvent(UINT width, UINT height) {
  return {
      {EncodableValue("event"), EncodableValue("previewSizeChanged")},
      {EncodableValue("previewSize"), EncodableValue(SizeWire(width, height))},
  };
}

EncodableMap SessionErrorEvent(const std::string& description) {
  return {
      {EncodableValue("event"), EncodableValue("sessionError")},
      {EncodableValue("code"), EncodableValue("session_runtime_error")},
      {EncodableValue("description"), EncodableValue(description)},
  };
}

EncodableMap DiagnosticEvent(const std::string& message) {
  return {
      {EncodableValue("event"), EncodableValue("diagnostic")},
      {EncodableValue("message"), EncodableValue(message)},
  };
}

EncodableValue CameraEvent(int64_t handle, EncodableMap event) {
  event[EncodableValue("handle")] = EncodableValue(handle);
  return EncodableValue(std::move(event));
}

// A CameraInstance's capture engine and state, which live on its queue's
// thread: each method runs there, and the engine's events reach it there.
// Completions and events go to the platform thread.
class CaptureSession : public std::enable_shared_from_this<CaptureSession> {
 public:
  CaptureSession(WorkQueue::Poster queue, PlatformThread::Poster post, CameraInstance::Emit emit,
                 std::shared_ptr<CameraTexture> texture)
      : queue_(std::move(queue)), post_(std::move(post)), emit_(std::move(emit)), texture_(std::move(texture)) {}

  void Start() { foundation_.emplace(); }

  void Shutdown() {
    Teardown();
    foundation_.reset();
  }

  void Open(const std::wstring& link, bool audio, const CameraInstance::Opened& done) {
    audio_ = audio;
    OpenEngine(link, [this, done](CameraResult<FrameSize> opened) { Reply(done, std::move(opened)); });
  }

  void StartPreview(const CameraInstance::Done& done) {
    if (!engine_) {
      Reply(done, Error(MF_E_NOT_INITIALIZED, "the camera is not open"));
      return;
    }
    BeginPreview([this, done](HRESULT status) {
      if (FAILED(status)) {
        Reply(done, Error(status, "cannot start the preview"));
      } else {
        Reply(done, std::nullopt);
      }
    });
  }

  void SetDevice(const std::wstring& link, const CameraInstance::Opened& done) {
    if (recording_) {
      Reply(done, Error(MF_E_INVALIDREQUEST, "a recording is in progress"));
      return;
    }
    const bool preview = previewing_;
    Teardown();
    OpenEngine(link, [this, preview, done](CameraResult<FrameSize> opened) {
      const auto* size = std::get_if<FrameSize>(&opened);
      if (size == nullptr || !preview) {
        Reply(done, std::move(opened));
        return;
      }
      BeginPreview([this, done, size = *size](HRESULT status) {
        if (FAILED(status)) {
          Reply(done, Error(status, "cannot start the preview"));
        } else {
          Reply(done, size);
        }
      });
    });
  }

  void TakePicture(const CameraInstance::Written& done) {
    if (!engine_) {
      Reply(done, Error(MF_E_NOT_INITIALIZED, "the camera is not open"));
      return;
    }
    if (photo_taken_) {
      Reply(done, Error(MF_E_INVALIDREQUEST, "a photo is being taken"));
      return;
    }
    std::wstring path;
    HRESULT hr = CapturePath(L"jpg", path);
    if (SUCCEEDED(hr)) hr = AddPhoto(path);
    if (FAILED(hr)) {
      Reply(done, Error(hr, "cannot take a photo"));
      return;
    }
    photo_taken_ = [this, done, path](HRESULT status) {
      if (FAILED(status)) {
        Reply(done, Error(status, "cannot take a photo"));
      } else {
        Reply(done, path);
      }
    };
    hr = engine_->TakePhoto();
    if (FAILED(hr)) Complete(photo_taken_, hr);
  }

  void StartRecording(const CameraInstance::Done& done) {
    if (!engine_) {
      Reply(done, Error(MF_E_NOT_INITIALIZED, "the camera is not open"));
      return;
    }
    if (recording_) {
      Reply(done, Error(MF_E_INVALIDREQUEST, "a recording is in progress"));
      return;
    }
    std::wstring path;
    HRESULT hr = CapturePath(L"mp4", path);
    if (SUCCEEDED(hr)) hr = AddRecord(path);
    if (FAILED(hr)) {
      Reply(done, Error(hr, "cannot start recording"));
      return;
    }
    recording_ = path;
    record_started_ = [this, done](HRESULT status) {
      if (SUCCEEDED(status)) {
        Reply(done, std::nullopt);
        return;
      }
      DeleteFileW(std::exchange(recording_, std::nullopt)->c_str());
      Reply(done, Error(status, "cannot start recording"));
    };
    hr = engine_->StartRecord();
    if (FAILED(hr)) Complete(record_started_, hr);
  }

  void StopRecording(const CameraInstance::Written& done) {
    if (!recording_ || record_started_) {
      Reply(done, Error(MF_E_INVALIDREQUEST, "no recording in progress"));
      return;
    }
    if (record_stopped_) {
      Reply(done, Error(MF_E_INVALIDREQUEST, "the recording is stopping"));
      return;
    }
    record_stopped_ = [this, done](HRESULT status) {
      const std::wstring path = *std::exchange(recording_, std::nullopt);
      if (SUCCEEDED(status)) {
        Reply(done, path);
        return;
      }
      DeleteFileW(path.c_str());
      Reply(done, Error(status, "cannot finish the recording"));
    };
    const HRESULT hr = engine_->StopRecord(TRUE, FALSE);
    if (FAILED(hr)) Complete(record_stopped_, hr);
  }

  void Close(const std::function<void()>& done) {
    if (recording_ && !record_started_ && !record_stopped_) {
      record_stopped_ = [this, done](HRESULT) {
        DeleteFileW(std::exchange(recording_, std::nullopt)->c_str());
        Teardown();
        post_(done);
      };
      const HRESULT hr = engine_->StopRecord(FALSE, FALSE);
      if (FAILED(hr)) Complete(record_stopped_, hr);
      return;
    }
    Teardown();
    post_(done);
  }

 private:
  // Calls [done] with [value] on the platform thread.
  template <typename T, typename V>
  void Reply(const std::function<void(T)>& done, V value) {
    post_([done, value = T(std::move(value))]() mutable { done(std::move(value)); });
  }

  // Opens an engine on the camera at [link], with the microphone where audio_,
  // and calls [opened] with the preview's size.
  void OpenEngine(const std::wstring& link, std::function<void(CameraResult<FrameSize>)> opened) {
    HRESULT hr = foundation_->status();
    if (FAILED(hr)) {
      opened(Error(hr, "Media Foundation is unavailable"));
      return;
    }
    hr = VideoSource(link, video_);
    if (FAILED(hr)) {
      opened(Error(hr, "cannot open the camera"));
      return;
    }
    // A microphone that does not open leaves recordings silent.
    if (audio_ && FAILED(MicrophoneSource(microphone_))) microphone_.Reset();
    ComPtr<IMFAttributes> attributes;
    hr = CreateEngine(engine_);
    if (SUCCEEDED(hr)) hr = MFCreateAttributes(&attributes, 1);
    if (SUCCEEDED(hr)) hr = attributes->SetUINT32(MF_CAPTURE_ENGINE_USE_VIDEO_DEVICE_ONLY, microphone_ ? FALSE : TRUE);
    if (FAILED(hr)) {
      Teardown();
      opened(Error(hr, "cannot create the capture engine"));
      return;
    }
    auto events = Microsoft::WRL::Make<EngineEvents>(
        [queue = queue_, weak = weak_from_this(), generation = generation_](GUID type, HRESULT status) {
          queue([weak, generation, type, status] {
            if (auto self = weak.lock()) self->OnEvent(generation, type, status);
          });
        });
    initialized_ = [this, opened](HRESULT status) {
      FrameSize size = {};
      if (SUCCEEDED(status)) status = ChooseFormat(size);
      if (FAILED(status)) {
        Teardown();
        opened(Error(status, "cannot start the camera"));
        return;
      }
      opened(size);
    };
    hr = engine_->Initialize(events.Get(), attributes.Get(), microphone_.Get(), video_.Get());
    if (FAILED(hr)) Complete(initialized_, hr);
  }

  // Sets the preview stream to its PreferredFormat, and [size] to the stream's
  // frame size.
  HRESULT ChooseFormat(FrameSize& size) {
    ComPtr<IMFCaptureSource> source;
    HRESULT hr = engine_->GetSource(&source);
    if (FAILED(hr)) return hr;
    std::vector<ComPtr<IMFMediaType>> types;
    std::vector<VideoFormat> formats;
    for (DWORD i = 0;; i++) {
      ComPtr<IMFMediaType> type;
      hr = source->GetAvailableDeviceMediaType(kPreviewStream, i, &type);
      if (hr == MF_E_NO_MORE_TYPES) break;
      if (FAILED(hr)) return hr;
      VideoFormat format = {};
      UINT32 numerator = 0;
      UINT32 denominator = 0;
      MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &format.width, &format.height);
      if (SUCCEEDED(MFGetAttributeRatio(type.Get(), MF_MT_FRAME_RATE, &numerator, &denominator)) && denominator != 0) {
        format.rate = static_cast<double>(numerator) / denominator;
      }
      types.push_back(type);
      formats.push_back(format);
    }
    if (const std::optional<size_t> preferred = PreferredFormat(formats)) {
      hr = source->SetCurrentDeviceMediaType(kPreviewStream, types[*preferred].Get());
      if (FAILED(hr)) return hr;
    }
    ComPtr<IMFMediaType> current;
    hr = source->GetCurrentDeviceMediaType(kPreviewStream, &current);
    if (FAILED(hr)) return hr;
    return MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, &size.width, &size.height);
  }

  // Starts the preview into texture_ and calls [started] with its status.
  void BeginPreview(Pending started) {
    if (previewing_) {
      started(S_OK);
      return;
    }
    HRESULT hr = AddPreview();
    if (FAILED(hr)) {
      started(hr);
      return;
    }
    preview_started_ = std::move(started);
    hr = engine_->StartPreview();
    if (FAILED(hr)) Complete(preview_started_, hr);
  }

  // The preview sink's one stream: top-down RGB32 at the source's size, whose
  // samples go to texture_.
  HRESULT AddPreview() {
    ComPtr<IMFCaptureSink> sink;
    HRESULT hr = engine_->GetSink(MF_CAPTURE_ENGINE_SINK_TYPE_PREVIEW, &sink);
    if (FAILED(hr)) return hr;
    ComPtr<IMFCapturePreviewSink> preview;
    hr = sink.As(&preview);
    if (FAILED(hr)) return hr;
    hr = preview->RemoveAllStreams();
    if (FAILED(hr)) return hr;
    ComPtr<IMFMediaType> current;
    hr = CurrentType(kPreviewStream, current);
    if (FAILED(hr)) return hr;
    ComPtr<IMFMediaType> type;
    hr = VideoType(current.Get(), MFVideoFormat_RGB32, type);
    if (FAILED(hr)) return hr;
    FrameSize size = {};
    hr = MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &size.width, &size.height);
    if (FAILED(hr)) return hr;
    hr = type->SetUINT32(MF_MT_DEFAULT_STRIDE, size.width * 4);
    if (FAILED(hr)) return hr;
    DWORD index = 0;
    hr = preview->AddStream(kPreviewStream, type.Get(), nullptr, &index);
    if (FAILED(hr)) return hr;
    auto samples = Microsoft::WRL::Make<PreviewSamples>(texture_, size, [post = post_, emit = emit_](FrameSize resized) {
      post([emit, resized] { emit(PreviewSizeChangedEvent(resized.width, resized.height)); });
    });
    return preview->SetSampleCallback(index, samples.Get());
  }

  // The photo sink's one stream: a JPEG at the photo stream's size, written to
  // [path].
  HRESULT AddPhoto(const std::wstring& path) {
    ComPtr<IMFCaptureSink> sink;
    HRESULT hr = engine_->GetSink(MF_CAPTURE_ENGINE_SINK_TYPE_PHOTO, &sink);
    if (FAILED(hr)) return hr;
    ComPtr<IMFCapturePhotoSink> photo;
    hr = sink.As(&photo);
    if (FAILED(hr)) return hr;
    hr = photo->RemoveAllStreams();
    if (FAILED(hr)) return hr;
    ComPtr<IMFMediaType> current;
    hr = CurrentType(kPhotoStream, current);
    if (FAILED(hr)) return hr;
    ComPtr<IMFMediaType> type;
    hr = JpegType(current.Get(), type);
    if (FAILED(hr)) return hr;
    DWORD index = 0;
    hr = photo->AddStream(kPhotoStream, type.Get(), nullptr, &index);
    if (FAILED(hr)) return hr;
    return photo->SetOutputFileName(path.c_str());
  }

  // The record sink's streams, written to [path] as an MP4: H.264 at the
  // record stream's size and rate, and AAC from the microphone where it
  // opened.
  HRESULT AddRecord(const std::wstring& path) {
    ComPtr<IMFCaptureSink> sink;
    HRESULT hr = engine_->GetSink(MF_CAPTURE_ENGINE_SINK_TYPE_RECORD, &sink);
    if (FAILED(hr)) return hr;
    ComPtr<IMFCaptureRecordSink> record;
    hr = sink.As(&record);
    if (FAILED(hr)) return hr;
    hr = record->RemoveAllStreams();
    if (FAILED(hr)) return hr;
    hr = record->SetOutputFileName(path.c_str());
    if (FAILED(hr)) return hr;
    ComPtr<IMFMediaType> current;
    hr = CurrentType(kRecordStream, current);
    if (FAILED(hr)) return hr;
    ComPtr<IMFMediaType> video;
    hr = VideoType(current.Get(), MFVideoFormat_H264, video);
    if (FAILED(hr)) return hr;
    UINT32 width = 0;
    UINT32 height = 0;
    UINT32 numerator = 0;
    UINT32 denominator = 1;
    MFGetAttributeSize(video.Get(), MF_MT_FRAME_SIZE, &width, &height);
    MFGetAttributeRatio(video.Get(), MF_MT_FRAME_RATE, &numerator, &denominator);
    hr = video->SetUINT32(MF_MT_AVG_BITRATE,
                          static_cast<UINT32>(kBitsPerPixel * width * height * numerator / denominator));
    if (FAILED(hr)) return hr;
    DWORD index = 0;
    hr = record->AddStream(kRecordStream, video.Get(), nullptr, &index);
    if (FAILED(hr) || !microphone_) return hr;
    ComPtr<IMFMediaType> audio;
    hr = AacType(audio);
    if (FAILED(hr)) return hr;
    return record->AddStream(kAudioStream, audio.Get(), nullptr, &index);
  }

  HRESULT CurrentType(DWORD stream, ComPtr<IMFMediaType>& type) {
    ComPtr<IMFCaptureSource> source;
    const HRESULT hr = engine_->GetSource(&source);
    if (FAILED(hr)) return hr;
    return source->GetCurrentDeviceMediaType(stream, &type);
  }

  void OnEvent(uint64_t generation, const GUID& type, HRESULT status) {
    if (generation != generation_) return;
    if (type == MF_CAPTURE_ENGINE_INITIALIZED) {
      Complete(initialized_, status);
    } else if (type == MF_CAPTURE_ENGINE_PREVIEW_STARTED) {
      previewing_ = SUCCEEDED(status);
      Complete(preview_started_, status);
    } else if (type == MF_CAPTURE_ENGINE_PREVIEW_STOPPED) {
      previewing_ = false;
    } else if (type == MF_CAPTURE_ENGINE_PHOTO_TAKEN) {
      Complete(photo_taken_, status);
    } else if (type == MF_CAPTURE_ENGINE_RECORD_STARTED) {
      Complete(record_started_, status);
    } else if (type == MF_CAPTURE_ENGINE_RECORD_STOPPED) {
      Complete(record_stopped_, status);
    } else if (type == MF_CAPTURE_ENGINE_ERROR && !FailPending(status)) {
      post_([emit = emit_, description = "capture engine error (" + Hex(status) + ")"] {
        emit(SessionErrorEvent(description));
      });
    }
  }

  // Fails each pending operation with [status], and answers whether there was
  // one.
  bool FailPending(HRESULT status) {
    bool failed = false;
    for (Pending* pending : {&initialized_, &preview_started_, &photo_taken_, &record_started_, &record_stopped_}) {
      if (!*pending) continue;
      failed = true;
      Complete(*pending, status);
    }
    return failed;
  }

  // Releases the engine and the devices, after failing what is pending. The
  // released engine's events are ignored.
  void Teardown() {
    generation_++;
    FailPending(MF_E_SHUTDOWN);
    if (engine_ && previewing_) engine_->StopPreview();
    engine_.Reset();
    if (video_) video_->Shutdown();
    video_.Reset();
    if (microphone_) microphone_->Shutdown();
    microphone_.Reset();
    previewing_ = false;
    recording_.reset();
  }

  const WorkQueue::Poster queue_;
  const PlatformThread::Poster post_;
  const CameraInstance::Emit emit_;
  const std::shared_ptr<CameraTexture> texture_;
  // Started by Start and stopped by Shutdown, the queue's first and last tasks.
  std::optional<CameraFoundation> foundation_;
  bool audio_ = false;
  uint64_t generation_ = 0;
  ComPtr<IMFCaptureEngine> engine_;
  ComPtr<IMFMediaSource> video_;
  ComPtr<IMFMediaSource> microphone_;
  bool previewing_ = false;
  // The file a recording writes, from its start until it stops.
  std::optional<std::wstring> recording_;
  Pending initialized_;
  Pending preview_started_;
  Pending photo_taken_;
  Pending record_started_;
  Pending record_stopped_;
};

CameraInstance::CameraInstance(PlatformThread::Poster post, Emit emit, std::shared_ptr<CameraTexture> texture)
    : session_(std::make_shared<CaptureSession>(queue_.poster(), std::move(post), std::move(emit), std::move(texture))) {
  Run([](CaptureSession& session) { session.Start(); });
}

CameraInstance::~CameraInstance() {
  Run([](CaptureSession& session) { session.Shutdown(); });
}

void CameraInstance::Open(std::wstring link, bool audio, Opened done) {
  Run([link = std::move(link), audio, done = std::move(done)](CaptureSession& session) {
    session.Open(link, audio, done);
  });
}

void CameraInstance::StartPreview(Done done) {
  Run([done = std::move(done)](CaptureSession& session) { session.StartPreview(done); });
}

void CameraInstance::SetDevice(std::wstring link, Opened done) {
  Run([link = std::move(link), done = std::move(done)](CaptureSession& session) { session.SetDevice(link, done); });
}

void CameraInstance::TakePicture(Written done) {
  Run([done = std::move(done)](CaptureSession& session) { session.TakePicture(done); });
}

void CameraInstance::StartRecording(Done done) {
  Run([done = std::move(done)](CaptureSession& session) { session.StartRecording(done); });
}

void CameraInstance::StopRecording(Written done) {
  Run([done = std::move(done)](CaptureSession& session) { session.StopRecording(done); });
}

void CameraInstance::Close(std::function<void()> done) {
  Run([done = std::move(done)](CaptureSession& session) { session.Close(done); });
}

void CameraInstance::Run(std::function<void(CaptureSession&)> work) {
  queue_.poster()([session = session_, work = std::move(work)] { work(*session); });
}

}  // namespace ux
