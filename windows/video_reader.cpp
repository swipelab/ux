#include "video_reader.h"

#include <mfapi.h>
#include <mferror.h>
#include <propidl.h>

#include <algorithm>
#include <cstdlib>
#include <utility>

namespace ux {

using Microsoft::WRL::ComPtr;

HRESULT VideoReader::Open(const std::wstring& path, bool audio, std::unique_ptr<VideoReader>& reader) {
  ComPtr<IMFAttributes> attributes;
  HRESULT hr = MFCreateAttributes(&attributes, 1);
  if (FAILED(hr)) return hr;
  hr = attributes->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE);
  if (FAILED(hr)) return hr;
  std::unique_ptr<VideoReader> opened(new VideoReader());
  hr = MFCreateSourceReaderFromURL(path.c_str(), attributes.Get(), &opened->reader_);
  if (FAILED(hr)) return hr;
  hr = opened->reader_->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
  if (FAILED(hr)) return hr;
  std::optional<DWORD> video_stream;
  std::optional<DWORD> audio_stream;
  for (DWORD stream = 0;; stream++) {
    ComPtr<IMFMediaType> type;
    hr = opened->reader_->GetNativeMediaType(stream, 0, &type);
    if (hr == MF_E_INVALIDSTREAMNUMBER) break;
    if (FAILED(hr)) return hr;
    GUID major;
    hr = type->GetMajorType(&major);
    if (FAILED(hr)) return hr;
    if (major == MFMediaType_Video && !video_stream) video_stream = stream;
    if (major == MFMediaType_Audio && !audio_stream) audio_stream = stream;
  }
  if (!video_stream) return MF_E_INVALIDSTREAMNUMBER;
  opened->video_stream_ = *video_stream;
  hr = opened->ConfigureVideo();
  if (FAILED(hr)) return hr;
  if (audio && audio_stream) {
    opened->audio_stream_ = audio_stream;
    if (FAILED(opened->ConfigureAudio())) opened->audio_stream_.reset();
  }
  PROPVARIANT duration;
  PropVariantInit(&duration);
  if (SUCCEEDED(opened->reader_->GetPresentationAttribute(static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE),
                                                          MF_PD_DURATION, &duration)) &&
      duration.vt == VT_UI8) {
    opened->duration_ = static_cast<LONGLONG>(duration.uhVal.QuadPart);
  }
  PropVariantClear(&duration);
  reader = std::move(opened);
  return S_OK;
}

HRESULT VideoReader::ConfigureVideo() {
  ComPtr<IMFMediaType> native;
  HRESULT hr = reader_->GetNativeMediaType(video_stream_, 0, &native);
  if (FAILED(hr)) return hr;
  UINT32 numerator = 0;
  UINT32 denominator = 0;
  if (SUCCEEDED(MFGetAttributeRatio(native.Get(), MF_MT_FRAME_RATE, &numerator, &denominator)) && numerator > 0 &&
      denominator > 0) {
    frame_rate_ = static_cast<double>(numerator) / denominator;
  }
  UINT32 bitrate = 0;
  if (SUCCEEDED(native->GetUINT32(MF_MT_AVG_BITRATE, &bitrate)) && bitrate > 0) bitrate_ = bitrate;
  ComPtr<IMFMediaType> type;
  hr = MFCreateMediaType(&type);
  if (FAILED(hr)) return hr;
  hr = type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  if (FAILED(hr)) return hr;
  hr = type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  if (FAILED(hr)) return hr;
  hr = reader_->SetCurrentMediaType(video_stream_, nullptr, type.Get());
  if (FAILED(hr)) return hr;
  hr = reader_->SetStreamSelection(video_stream_, TRUE);
  if (FAILED(hr)) return hr;
  return ReadFormat();
}

HRESULT VideoReader::ConfigureAudio() {
  ComPtr<IMFMediaType> native;
  HRESULT hr = reader_->GetNativeMediaType(*audio_stream_, 0, &native);
  if (FAILED(hr)) return hr;
  // AAC, which the export writes, takes 44.1 or 48 kHz, in mono or stereo.
  const UINT32 rate = MFGetAttributeUINT32(native.Get(), MF_MT_AUDIO_SAMPLES_PER_SECOND, 0) == 44100 ? 44100 : 48000;
  const UINT32 channels = MFGetAttributeUINT32(native.Get(), MF_MT_AUDIO_NUM_CHANNELS, 0) == 1 ? 1 : 2;
  ComPtr<IMFMediaType> type;
  hr = MFCreateMediaType(&type);
  if (FAILED(hr)) return hr;
  hr = type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  if (FAILED(hr)) return hr;
  hr = type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  if (FAILED(hr)) return hr;
  hr = type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  if (FAILED(hr)) return hr;
  hr = type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, rate);
  if (FAILED(hr)) return hr;
  hr = type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, channels);
  if (FAILED(hr)) return hr;
  hr = type->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, channels * 2);
  if (FAILED(hr)) return hr;
  hr = type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, rate * channels * 2);
  if (FAILED(hr)) return hr;
  hr = reader_->SetCurrentMediaType(*audio_stream_, nullptr, type.Get());
  if (FAILED(hr)) return hr;
  hr = reader_->SetStreamSelection(*audio_stream_, TRUE);
  if (FAILED(hr)) return hr;
  audio_ = AudioFormat{rate, channels};
  return S_OK;
}

HRESULT VideoReader::ReadFormat() {
  ComPtr<IMFMediaType> type;
  HRESULT hr = reader_->GetCurrentMediaType(video_stream_, &type);
  if (FAILED(hr)) return hr;
  UINT32 width = 0;
  hr = MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &width, &rows_);
  if (FAILED(hr)) return hr;
  // The advanced video processor turns the frames upright and leaves the
  // rotation off the type it delivers.
  turns_ = static_cast<int>(MFGetAttributeUINT32(type.Get(), MF_MT_VIDEO_ROTATION, MFVideoRotationFormat_0) / 90 % 4);
  MFVideoArea area;
  if (SUCCEEDED(type->GetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE, reinterpret_cast<UINT8*>(&area), sizeof(area),
                              nullptr))) {
    left_ = area.OffsetX.value;
    top_ = area.OffsetY.value;
    width_ = static_cast<UINT>(area.Area.cx);
    height_ = static_cast<UINT>(area.Area.cy);
  } else {
    left_ = 0;
    top_ = 0;
    width_ = width;
    height_ = rows_;
  }
  UINT32 stride = 0;
  if (SUCCEEDED(type->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride))) {
    stride_ = static_cast<LONG>(stride);
    return S_OK;
  }
  return MFGetStrideForBitmapInfoHeader(MFVideoFormat_RGB32.Data1, width, &stride_);
}

HRESULT VideoReader::Seek(LONGLONG time) {
  PROPVARIANT position;
  PropVariantInit(&position);
  position.vt = VT_I8;
  position.hVal.QuadPart = time;
  const HRESULT hr = reader_->SetCurrentPosition(GUID_NULL, position);
  PropVariantClear(&position);
  return hr;
}

HRESULT VideoReader::Read(Decoded& decoded) {
  for (;;) {
    DWORD stream = 0;
    DWORD flags = 0;
    LONGLONG time = 0;
    ComPtr<IMFSample> sample;
    HRESULT hr = reader_->ReadSample(static_cast<DWORD>(MF_SOURCE_READER_ANY_STREAM), 0, &stream, &flags, &time,
                                     &sample);
    if (FAILED(hr)) return hr;
    if (flags & MF_SOURCE_READERF_ERROR) return E_FAIL;
    const bool video = stream == video_stream_;
    if (video && (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED)) {
      hr = ReadFormat();
      if (FAILED(hr)) return hr;
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
      decoded.kind = video ? Decoded::Kind::kVideoEnd : Decoded::Kind::kAudioEnd;
      return S_OK;
    }
    if (!sample) continue;
    decoded.time = time;
    LONGLONG duration = 0;
    decoded.duration = SUCCEEDED(sample->GetSampleDuration(&duration)) ? std::optional<LONGLONG>(duration)
                                                                       : std::nullopt;
    if (video) {
      decoded.kind = Decoded::Kind::kFrame;
      return CopyFrame(sample.Get(), decoded.frame);
    }
    decoded.kind = Decoded::Kind::kAudio;
    ComPtr<IMFMediaBuffer> buffer;
    hr = sample->ConvertToContiguousBuffer(&buffer);
    if (FAILED(hr)) return hr;
    BYTE* data = nullptr;
    DWORD length = 0;
    hr = buffer->Lock(&data, nullptr, &length);
    if (FAILED(hr)) return hr;
    decoded.pcm.assign(data, data + length);
    return buffer->Unlock();
  }
}

HRESULT VideoReader::CopyFrame(IMFSample* sample, Image& frame) const {
  ComPtr<IMFMediaBuffer> buffer;
  HRESULT hr = sample->ConvertToContiguousBuffer(&buffer);
  if (FAILED(hr)) return hr;
  ComPtr<IMF2DBuffer> buffer2d;
  BYTE* scanline0 = nullptr;
  LONG pitch = 0;
  if (SUCCEEDED(buffer.As(&buffer2d))) {
    hr = buffer2d->Lock2D(&scanline0, &pitch);
  } else {
    BYTE* data = nullptr;
    hr = buffer->Lock(&data, nullptr, nullptr);
    pitch = stride_;
    scanline0 = pitch < 0 ? data - static_cast<ptrdiff_t>(pitch) * (rows_ - 1) : data;
  }
  if (FAILED(hr)) return hr;
  frame.width = width_;
  frame.height = height_;
  frame.pixels.resize(static_cast<size_t>(width_) * height_ * 4);
  for (UINT y = 0; y < height_; y++) {
    const BYTE* row = scanline0 + static_cast<ptrdiff_t>(top_ + y) * pitch + static_cast<ptrdiff_t>(left_) * 4;
    uint8_t* out = frame.pixels.data() + static_cast<size_t>(y) * width_ * 4;
    std::copy(row, row + static_cast<size_t>(width_) * 4, out);
    for (UINT x = 0; x < width_; x++) out[x * 4 + 3] = 255;
  }
  return buffer2d ? buffer2d->Unlock2D() : buffer->Unlock();
}

HRESULT VideoReader::StopVideo() { return reader_->SetStreamSelection(video_stream_, FALSE); }

HRESULT VideoReader::StopAudio() {
  return audio_stream_ ? reader_->SetStreamSelection(*audio_stream_, FALSE) : S_OK;
}

HRESULT VideoReader::FrameAt(LONGLONG time, LONGLONG tolerance, std::optional<Decoded>& frame) {
  HRESULT hr = Seek(time);
  if (FAILED(hr)) return hr;
  std::optional<Decoded> best;
  Decoded decoded;
  for (;;) {
    hr = Read(decoded);
    if (FAILED(hr)) return hr;
    if (decoded.kind == Decoded::Kind::kAudio) continue;
    if (decoded.kind != Decoded::Kind::kFrame) break;
    const bool reached = decoded.time >= time;
    if (!best || std::abs(decoded.time - time) < std::abs(best->time - time)) {
      if (!best) best.emplace();
      std::swap(*best, decoded);
    }
    if (reached) break;
  }
  if (best && std::abs(best->time - time) <= tolerance) frame = std::move(best);
  return S_OK;
}

}  // namespace ux
