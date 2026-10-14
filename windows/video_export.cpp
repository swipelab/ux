#include "video_export.h"

#include <codecapi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <memory>
#include <utility>

#include "media_foundation.h"
#include "text.h"
#include "video_reader.h"

namespace ux {

namespace {

using Microsoft::WRL::ComPtr;

constexpr LONGLONG kTicksPerMs = 10000;
constexpr LONGLONG kTicksPerSecond = 10000000;
// 128 kbit/s, a rate Windows's AAC encoder takes.
constexpr UINT32 kAudioBytesPerSecond = 16000;
constexpr uint32_t kOpaqueBlack = 0xFF000000;
// The density of Telegram's export tiers. Windows's encoder needs about this
// much: at the bitrate of a source that compressed further, it quantizes
// colours visibly off.
constexpr double kMinBitsPerPixel = 0.1;

ExportFailed Failure(const char* code, const std::string& what, HRESULT hr) {
  return {code, what + " (" + Hex(hr) + ")"};
}

// The bitrate of the whole file at [path] over [duration], in 100 ns, when its
// size can be read.
std::optional<UINT32> FileBitrate(const std::wstring& path, LONGLONG duration) {
  WIN32_FILE_ATTRIBUTE_DATA data;
  if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &data)) return std::nullopt;
  const ULONGLONG bytes = (static_cast<ULONGLONG>(data.nFileSizeHigh) << 32) | data.nFileSizeLow;
  return static_cast<UINT32>(bytes * 8 * kTicksPerSecond / duration);
}

// The bitrate [request] asks for, or else its source's, at least
// kMinBitsPerPixel of the [width]×[height] frames; none when the source's
// cannot be read.
std::optional<UINT32> Bitrate(const ExportRequest& request, const VideoReader& reader, UINT width, UINT height,
                              double frames_per_second) {
  if (request.video_bitrate) return static_cast<UINT32>(*request.video_bitrate);
  const std::optional<UINT32> source =
      reader.bitrate() ? reader.bitrate() : FileBitrate(request.path, *reader.duration());
  if (!source) return std::nullopt;
  return std::max(*source, static_cast<UINT32>(kMinBitsPerPixel * width * height * frames_per_second));
}

// A sample of [size] bytes that [fill] writes.
HRESULT Sample(size_t size, const std::function<void(uint8_t*)>& fill, LONGLONG time, LONGLONG duration,
               ComPtr<IMFSample>& sample) {
  ComPtr<IMFMediaBuffer> buffer;
  HRESULT hr = MFCreateMemoryBuffer(static_cast<DWORD>(size), &buffer);
  if (FAILED(hr)) return hr;
  BYTE* data = nullptr;
  hr = buffer->Lock(&data, nullptr, nullptr);
  if (FAILED(hr)) return hr;
  fill(data);
  hr = buffer->Unlock();
  if (FAILED(hr)) return hr;
  hr = buffer->SetCurrentLength(static_cast<DWORD>(size));
  if (FAILED(hr)) return hr;
  hr = MFCreateSample(&sample);
  if (FAILED(hr)) return hr;
  hr = sample->AddBuffer(buffer.Get());
  if (FAILED(hr)) return hr;
  hr = sample->SetSampleTime(time);
  if (FAILED(hr)) return hr;
  return sample->SetSampleDuration(duration);
}

HRESULT VideoType(const GUID& subtype, UINT width, UINT height, double frames_per_second,
                  ComPtr<IMFMediaType>& type) {
  HRESULT hr = MFCreateMediaType(&type);
  if (FAILED(hr)) return hr;
  hr = type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  if (FAILED(hr)) return hr;
  hr = type->SetGUID(MF_MT_SUBTYPE, subtype);
  if (FAILED(hr)) return hr;
  hr = type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  if (FAILED(hr)) return hr;
  hr = MFSetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, width, height);
  if (FAILED(hr)) return hr;
  hr = MFSetAttributeRatio(type.Get(), MF_MT_FRAME_RATE, static_cast<UINT32>(std::llround(frames_per_second * 1000)),
                           1000);
  if (FAILED(hr)) return hr;
  return MFSetAttributeRatio(type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
}

HRESULT AudioType(const GUID& subtype, const AudioFormat& format, UINT32 bytes_per_second,
                  ComPtr<IMFMediaType>& type) {
  HRESULT hr = MFCreateMediaType(&type);
  if (FAILED(hr)) return hr;
  hr = type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  if (FAILED(hr)) return hr;
  hr = type->SetGUID(MF_MT_SUBTYPE, subtype);
  if (FAILED(hr)) return hr;
  hr = type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  if (FAILED(hr)) return hr;
  hr = type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, format.rate);
  if (FAILED(hr)) return hr;
  hr = type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, format.channels);
  if (FAILED(hr)) return hr;
  return type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, bytes_per_second);
}

// The sink writer of one export: H.264 from NV12 frames and, when there is
// audio, AAC from 16-bit PCM, into an MP4.
class Writer {
 public:
  HRESULT Open(const std::wstring& path, UINT width, UINT height, double frames_per_second, UINT32 bitrate,
               const std::optional<AudioFormat>& audio) {
    ComPtr<IMFAttributes> attributes;
    HRESULT hr = MFCreateAttributes(&attributes, 1);
    if (FAILED(hr)) return hr;
    hr = attributes->SetGUID(MF_TRANSCODE_CONTAINERTYPE, MFTranscodeContainerType_MPEG4);
    if (FAILED(hr)) return hr;
    hr = MFCreateSinkWriterFromURL(path.c_str(), nullptr, attributes.Get(), &writer_);
    if (FAILED(hr)) return hr;
    ComPtr<IMFMediaType> output;
    hr = VideoType(MFVideoFormat_H264, width, height, frames_per_second, output);
    if (FAILED(hr)) return hr;
    hr = output->SetUINT32(MF_MT_AVG_BITRATE, bitrate);
    if (FAILED(hr)) return hr;
    hr = output->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_High);
    if (FAILED(hr)) return hr;
    hr = writer_->AddStream(output.Get(), &video_);
    if (FAILED(hr)) return hr;
    ComPtr<IMFMediaType> input;
    hr = VideoType(MFVideoFormat_NV12, width, height, frames_per_second, input);
    if (FAILED(hr)) return hr;
    hr = input->SetUINT32(MF_MT_DEFAULT_STRIDE, width);
    if (FAILED(hr)) return hr;
    // A key frame each second, as cameras write, so a frame is found without
    // decoding far. No B-frames: the MP4 sink writes no edit list, so their
    // reordering delay would start the video one frame late. Low latency keeps
    // the encoder from queueing frames ahead, which at 1080p holds hundreds of
    // megabytes.
    ComPtr<IMFAttributes> encoding;
    hr = MFCreateAttributes(&encoding, 3);
    if (FAILED(hr)) return hr;
    hr = encoding->SetUINT32(CODECAPI_AVEncMPVGOPSize,
                             static_cast<UINT32>(std::max(1LL, std::llround(frames_per_second))));
    if (FAILED(hr)) return hr;
    hr = encoding->SetUINT32(CODECAPI_AVEncMPVDefaultBPictureCount, 0);
    if (FAILED(hr)) return hr;
    hr = encoding->SetUINT32(CODECAPI_AVLowLatencyMode, TRUE);
    if (FAILED(hr)) return hr;
    hr = writer_->SetInputMediaType(video_, input.Get(), encoding.Get());
    if (FAILED(hr)) return hr;
    if (audio) {
      hr = AudioType(MFAudioFormat_AAC, *audio, kAudioBytesPerSecond, output);
      if (FAILED(hr)) return hr;
      hr = writer_->AddStream(output.Get(), &audio_);
      if (FAILED(hr)) return hr;
      hr = AudioType(MFAudioFormat_PCM, *audio, audio->rate * audio->channels * 2, input);
      if (FAILED(hr)) return hr;
      hr = input->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, audio->channels * 2);
      if (FAILED(hr)) return hr;
      hr = writer_->SetInputMediaType(audio_, input.Get(), nullptr);
      if (FAILED(hr)) return hr;
    }
    return writer_->BeginWriting();
  }

  HRESULT WriteFrame(const Image& canvas, LONGLONG time, LONGLONG duration) {
    // Windows's encoder states no colour space, so decoders take BT.709 for
    // frames over 576 rows and BT.601 for the rest, as Media Foundation does.
    const YuvMatrix matrix = canvas.height > 576 ? YuvMatrix::kBt709 : YuvMatrix::kBt601;
    ComPtr<IMFSample> sample;
    const HRESULT hr = Sample(
        static_cast<size_t>(canvas.width) * canvas.height * 3 / 2,
        [&canvas, matrix](uint8_t* nv12) { ToNv12(canvas, matrix, nv12, canvas.width); }, time, duration, sample);
    return FAILED(hr) ? hr : writer_->WriteSample(video_, sample.Get());
  }

  HRESULT WriteAudio(const uint8_t* pcm, size_t size, LONGLONG time, LONGLONG duration) {
    ComPtr<IMFSample> sample;
    const HRESULT hr = Sample(size, [pcm, size](uint8_t* data) { std::copy(pcm, pcm + size, data); }, time, duration,
                              sample);
    return FAILED(hr) ? hr : writer_->WriteSample(audio_, sample.Get());
  }

  HRESULT Finish() { return writer_->Finalize(); }

  // Closes the file, finished or not.
  void Close() { writer_.Reset(); }

 private:
  ComPtr<IMFSinkWriter> writer_;
  DWORD video_ = 0;
  DWORD audio_ = 0;
};

}  // namespace

ExportOutcome Export(const ExportRequest& request, const std::function<void(double)>& progress,
                     const std::atomic<bool>& cancelled) {
  MediaFoundation media;
  if (FAILED(media.status())) return Failure("session_failed", "Media Foundation is unavailable", media.status());
  std::unique_ptr<VideoReader> reader;
  HRESULT hr = VideoReader::Open(request.path, !request.remove_audio, reader);
  if (hr == MF_E_INVALIDSTREAMNUMBER) return ExportFailed{"no_video_track", "no video track in the source"};
  if (FAILED(hr)) return Failure("session_failed", "cannot read the video", hr);
  if (!reader->duration()) return ExportFailed{"export_failed", "the video states no duration"};
  const LONGLONG duration = *reader->duration();
  const LONGLONG start = request.trim_start_ms.value_or(0) * kTicksPerMs;
  const LONGLONG end = request.trim_end_ms ? std::min(*request.trim_end_ms * kTicksPerMs, duration) : duration;
  if (start < 0 || end <= start) return ExportFailed{"bad_trim", "empty trim range"};

  const auto [upright_width, upright_height] = Turned(reader->width(), reader->height(), reader->turns());
  const ExportGeometry geometry = request.geometry.value_or(ExportGeometry{Affine{}, upright_width, upright_height});
  // H.264 frames have even sides.
  const UINT width = std::max(2u, geometry.width & ~1u);
  const UINT height = std::max(2u, geometry.height & ~1u);
  const double frames_per_second = reader->frame_rate().value_or(30);
  const std::optional<UINT32> bitrate = Bitrate(request, *reader, width, height, frames_per_second);
  if (!bitrate) return ExportFailed{"session_failed", "cannot read the source's size"};
  std::optional<Image> overlay;
  Image strokes;
  if (request.overlay_path && SUCCEEDED(DecodeImage(*request.overlay_path, strokes))) {
    overlay.emplace().Reset(width, height, 0);
    Draw(strokes, 0, geometry.affine, *overlay);
  }

  DeleteFileW(request.out_path.c_str());
  Writer writer;
  const auto fail = [&](ExportFailed failed) {
    writer.Close();
    DeleteFileW(request.out_path.c_str());
    return failed;
  };
  hr = writer.Open(request.out_path, width, height, frames_per_second, *bitrate, reader->audio());
  if (FAILED(hr)) return fail(Failure("session_failed", "cannot write the export", hr));
  if (start > 0) {
    hr = reader->Seek(start);
    if (FAILED(hr)) return fail(Failure("export_failed", "cannot seek to the trim start", hr));
  }

  const LONGLONG span = end - start;
  const LONGLONG frame_period = static_cast<LONGLONG>(kTicksPerSecond / frames_per_second);
  Image canvas;
  const auto write_frame = [&](const Image& frame, LONGLONG time, LONGLONG frame_duration) {
    canvas.Reset(width, height, kOpaqueBlack);
    Draw(frame, reader->turns(), geometry.affine, canvas);
    if (overlay) Draw(*overlay, 0, Affine{}, canvas);
    return writer.WriteFrame(canvas, time, frame_duration);
  };
  // The latest frame before the trim start, shown from 0 until the first frame
  // at or after it.
  std::optional<Decoded> lead;
  bool wrote_frame = false;
  bool video_open = true;
  const auto close_video = [&]() {
    video_open = false;
    if (!wrote_frame && lead) {
      wrote_frame = true;
      const HRESULT written = write_frame(lead->frame, 0, span);
      if (FAILED(written)) return written;
    }
    return reader->StopVideo();
  };
  std::optional<LONGLONG> audio_origin;
  uint64_t audio_frames = 0;
  double reported = 0;
  progress(0);

  Decoded decoded;
  bool audio_open = reader->audio().has_value();
  while (video_open || audio_open) {
    if (cancelled) return fail(ExportFailed{"cancelled", "export cancelled"});
    hr = reader->Read(decoded);
    if (FAILED(hr)) return fail(Failure("export_failed", "cannot decode the video", hr));
    switch (decoded.kind) {
      case Decoded::Kind::kFrame: {
        if (!video_open) break;
        if (decoded.time < start) {
          if (!lead) lead.emplace();
          std::swap(*lead, decoded);
          break;
        }
        if (decoded.time >= end) {
          hr = close_video();
          break;
        }
        if (!wrote_frame && lead && decoded.time > start) hr = write_frame(lead->frame, 0, decoded.time - start);
        if (FAILED(hr)) break;
        lead.reset();
        hr = write_frame(decoded.frame, decoded.time - start,
                         std::min(decoded.duration.value_or(frame_period), end - decoded.time));
        wrote_frame = true;
        const double done = static_cast<double>(decoded.time - start) / span;
        if (done >= reported + 0.01) {
          reported = done;
          progress(done);
        }
        break;
      }
      case Decoded::Kind::kVideoEnd:
        if (video_open) hr = close_video();
        break;
      case Decoded::Kind::kAudio: {
        if (!audio_open) break;
        const AudioFormat format = *reader->audio();
        const size_t frame_bytes = format.channels * 2;
        const LONGLONG count = static_cast<LONGLONG>(decoded.pcm.size() / frame_bytes);
        const LONGLONG chunk_end = decoded.time + count * kTicksPerSecond / format.rate;
        // The chunk's frames that lie in [start, end).
        const LONGLONG first =
            decoded.time < start
                ? std::min(count, ((start - decoded.time) * format.rate + kTicksPerSecond - 1) / kTicksPerSecond)
                : 0;
        const LONGLONG last =
            chunk_end > end ? std::max(0LL, (end - decoded.time) * format.rate / kTicksPerSecond) : count;
        if (last > first) {
          if (!audio_origin) audio_origin = decoded.time + first * kTicksPerSecond / format.rate - start;
          hr = writer.WriteAudio(decoded.pcm.data() + first * frame_bytes, (last - first) * frame_bytes,
                                 *audio_origin + static_cast<LONGLONG>(audio_frames) * kTicksPerSecond / format.rate,
                                 (last - first) * kTicksPerSecond / format.rate);
          audio_frames += last - first;
        }
        if (SUCCEEDED(hr) && chunk_end >= end) {
          audio_open = false;
          hr = reader->StopAudio();
        }
        break;
      }
      case Decoded::Kind::kAudioEnd:
        audio_open = false;
        break;
    }
    if (FAILED(hr)) return fail(Failure("export_failed", "cannot encode the video", hr));
  }
  if (!wrote_frame) return fail(ExportFailed{"export_failed", "no frame in the trim range"});
  hr = writer.Finish();
  if (FAILED(hr)) return fail(Failure("export_failed", "cannot finish the export", hr));
  writer.Close();
  progress(1);
  return ExportDone{width, height, (span + kTicksPerMs / 2) / kTicksPerMs};
}

}  // namespace ux
