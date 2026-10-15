#include <windows.h>

#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "../media_foundation.h"
#include "../raster.h"
#include "../video_export.h"
#include "../video_reader.h"
#include "../video_thumbnail.h"
#include "check.h"
#include "support.h"

namespace {

using Microsoft::WRL::ComPtr;

constexpr UINT kWidth = 320;
constexpr UINT kHeight = 240;
constexpr int kFramesPerSecond = 30;
constexpr int kSeconds = 3;
constexpr LONGLONG kTicksPerSecond = 10000000;
constexpr UINT kAudioRate = 48000;

constexpr uint32_t kRed = 0xFFCC3333;
constexpr uint32_t kGreen = 0xFF33CC33;
constexpr uint32_t kBlue = 0xFF3333CC;
constexpr uint32_t kYellow = 0xFFCCCC33;
constexpr uint32_t kMagenta = 0xFFFF00FF;
// H.264's 4:2:0 and the YUV matrices move a colour this far.
constexpr int kTolerance = 40;

// A square at (40, 40)-(72, 72) of the source's red quadrant is grey, at 16 +
// 8 times the frame's 100 ms block; [frame] holds it scaled.
int Block(const ux::Image& frame) {
  const int grey = At(frame, 56 * frame.width / kWidth, 56 * frame.height / kHeight)[1];
  return static_cast<int>(std::lround((grey - 16) / 8.0));
}

ux::Image SourceFrame(int index) {
  ux::Image frame;
  frame.Reset(kWidth, kHeight, 0);
  for (UINT y = 0; y < kHeight; y++) {
    for (UINT x = 0; x < kWidth; x++) {
      uint32_t color = y < kHeight / 2 ? (x < kWidth / 2 ? kRed : kGreen) : (x < kWidth / 2 ? kBlue : kYellow);
      if (x >= 40 && x < 72 && y >= 40 && y < 72) {
        const auto grey = static_cast<uint32_t>(16 + 8 * (index * 1000 / kFramesPerSecond / 100));
        color = 0xFF000000 | grey << 16 | grey << 8 | grey;
      }
      for (int c = 0; c < 4; c++) {
        frame.pixels[(static_cast<size_t>(y) * kWidth + x) * 4 + c] = static_cast<uint8_t>(color >> (8 * c));
      }
    }
  }
  return frame;
}

HRESULT WriteSample(IMFSinkWriter* writer, DWORD stream, const uint8_t* bytes, size_t size, LONGLONG time,
                    LONGLONG duration) {
  ComPtr<IMFMediaBuffer> buffer;
  HRESULT hr = MFCreateMemoryBuffer(static_cast<DWORD>(size), &buffer);
  if (FAILED(hr)) return hr;
  BYTE* data = nullptr;
  hr = buffer->Lock(&data, nullptr, nullptr);
  if (FAILED(hr)) return hr;
  std::copy(bytes, bytes + size, data);
  buffer->Unlock();
  buffer->SetCurrentLength(static_cast<DWORD>(size));
  ComPtr<IMFSample> sample;
  hr = MFCreateSample(&sample);
  if (FAILED(hr)) return hr;
  sample->AddBuffer(buffer.Get());
  sample->SetSampleTime(time);
  sample->SetSampleDuration(duration);
  return writer->WriteSample(stream, sample.Get());
}

ComPtr<IMFMediaType> MediaType(const GUID& major, const GUID& subtype) {
  ComPtr<IMFMediaType> type;
  MFCreateMediaType(&type);
  type->SetGUID(MF_MT_MAJOR_TYPE, major);
  type->SetGUID(MF_MT_SUBTYPE, subtype);
  return type;
}

// Writes the source: kSeconds of quadrants at kWidth×kHeight, its 100 ms
// blocks counted in grey, over [tone] samples of a 1 kHz tone.
HRESULT WriteSource(const std::wstring& path, UINT tone = kAudioRate * kSeconds) {
  ComPtr<IMFSinkWriter> writer;
  HRESULT hr = MFCreateSinkWriterFromURL(path.c_str(), nullptr, nullptr, &writer);
  if (FAILED(hr)) return hr;
  ComPtr<IMFMediaType> video_out = MediaType(MFMediaType_Video, MFVideoFormat_H264);
  video_out->SetUINT32(MF_MT_AVG_BITRATE, 2000000);
  video_out->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  MFSetAttributeSize(video_out.Get(), MF_MT_FRAME_SIZE, kWidth, kHeight);
  MFSetAttributeRatio(video_out.Get(), MF_MT_FRAME_RATE, kFramesPerSecond, 1);
  MFSetAttributeRatio(video_out.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  DWORD video = 0;
  hr = writer->AddStream(video_out.Get(), &video);
  if (FAILED(hr)) return hr;
  ComPtr<IMFMediaType> video_in = MediaType(MFMediaType_Video, MFVideoFormat_RGB32);
  video_in->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  video_in->SetUINT32(MF_MT_DEFAULT_STRIDE, kWidth * 4);
  MFSetAttributeSize(video_in.Get(), MF_MT_FRAME_SIZE, kWidth, kHeight);
  MFSetAttributeRatio(video_in.Get(), MF_MT_FRAME_RATE, kFramesPerSecond, 1);
  MFSetAttributeRatio(video_in.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  hr = writer->SetInputMediaType(video, video_in.Get(), nullptr);
  if (FAILED(hr)) return hr;
  ComPtr<IMFMediaType> audio_out = MediaType(MFMediaType_Audio, MFAudioFormat_AAC);
  audio_out->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  audio_out->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, kAudioRate);
  audio_out->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
  audio_out->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 16000);
  DWORD audio = 0;
  hr = writer->AddStream(audio_out.Get(), &audio);
  if (FAILED(hr)) return hr;
  ComPtr<IMFMediaType> audio_in = MediaType(MFMediaType_Audio, MFAudioFormat_PCM);
  audio_in->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  audio_in->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, kAudioRate);
  audio_in->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
  audio_in->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 4);
  audio_in->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, kAudioRate * 4);
  hr = writer->SetInputMediaType(audio, audio_in.Get(), nullptr);
  if (FAILED(hr)) return hr;
  hr = writer->BeginWriting();
  if (FAILED(hr)) return hr;
  constexpr LONGLONG kFrameTicks = kTicksPerSecond / kFramesPerSecond;
  constexpr UINT kFrameSamples = kAudioRate / kFramesPerSecond;
  constexpr UINT kFrames = kFramesPerSecond * kSeconds;
  std::vector<int16_t> chunk(kFrameSamples * 2);
  for (UINT i = 0; i < kFrames || i * kFrameSamples < tone; i++) {
    if (i < kFrames) {
      const ux::Image frame = SourceFrame(i);
      hr = WriteSample(writer.Get(), video, frame.pixels.data(), frame.pixels.size(), i * kFrameTicks, kFrameTicks);
      if (FAILED(hr)) return hr;
    }
    if (i * kFrameSamples >= tone) continue;
    const UINT samples = std::min(kFrameSamples, tone - i * kFrameSamples);
    for (UINT s = 0; s < samples; s++) {
      const double t = static_cast<double>(i * kFrameSamples + s) / kAudioRate;
      chunk[s * 2] = chunk[s * 2 + 1] = static_cast<int16_t>(8000 * std::sin(2 * 3.14159265358979 * 1000 * t));
    }
    hr = WriteSample(writer.Get(), audio, reinterpret_cast<const uint8_t*>(chunk.data()), samples * 4,
                     i * kFrameTicks, samples * kTicksPerSecond / kAudioRate);
    if (FAILED(hr)) return hr;
  }
  return writer->Finalize();
}

std::optional<ux::Image> Decoded(const std::optional<ux::Thumbnail>& thumbnail) {
  if (!thumbnail) return std::nullopt;
  const std::wstring path = TempPath(L"ux_video_export_test.png");
  ux::Image image;
  const bool decoded = WriteBytes(path, thumbnail->png) && SUCCEEDED(ux::DecodeImage(path, image));
  DeleteFileW(path.c_str());
  if (!decoded) return std::nullopt;
  return image;
}

std::optional<ux::Image> Frame(const std::wstring& path, int64_t at_ms, std::optional<UINT> max_width = std::nullopt,
                               const std::optional<ux::ThumbnailBake>& bake = std::nullopt) {
  const ux::ThumbnailResult result = ux::VideoThumbnail(path, at_ms, max_width, bake);
  const auto* thumbnail = std::get_if<std::optional<ux::Thumbnail>>(&result);
  return thumbnail == nullptr ? std::nullopt : Decoded(*thumbnail);
}

bool Missing(const std::wstring& path) { return GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES; }

}  // namespace

void VideoExportSuite() {
  ux::MediaWork media;
  CHECK(SUCCEEDED(media.status()));
  const std::wstring source = TempPath(L"ux_video_export_source.mp4");
  const std::wstring out = TempPath(L"ux_video_export_out.mp4");
  CHECK(SUCCEEDED(WriteSource(source)));

  // Frames, by time, size and bake.
  if (const std::optional<ux::Image> frame = Frame(source, 1000)) {
    CHECK(frame->width == kWidth && frame->height == kHeight);
    CHECK(Near(At(*frame, 100, 100), Of(kRed), kTolerance));
    CHECK(Near(At(*frame, 240, 60), Of(kGreen), kTolerance));
    CHECK(Near(At(*frame, 80, 180), Of(kBlue), kTolerance));
    CHECK(Near(At(*frame, 240, 180), Of(kYellow), kTolerance));
    CHECK(Block(*frame) == 10);
  } else {
    CHECK(false);
  }
  if (const std::optional<ux::Image> frame = Frame(source, 0, 160)) {
    CHECK(frame->width == 160 && frame->height == 120);
  } else {
    CHECK(false);
  }
  {
    const ux::ThumbnailBake green{{1, 0, -160, 0, 1, 0}, 160, 120, std::nullopt, 80};
    const std::optional<ux::Image> frame = Frame(source, 0, std::nullopt, green);
    CHECK(frame && frame->width == 80 && frame->height == 60);
    if (frame) CHECK(Near(At(*frame, 40, 30), Of(kGreen), kTolerance));
  }
  CHECK(std::holds_alternative<ux::ThumbnailFailed>(ux::VideoThumbnail(source, 60000, std::nullopt, std::nullopt)));
  {
    const std::vector<std::optional<ux::Thumbnail>> strip = ux::VideoThumbnails(source, {500, 2500, 60000}, 64);
    CHECK(strip.size() == 3);
    if (strip.size() == 3) {
      const std::optional<ux::Image> early = Decoded(strip[0]);
      const std::optional<ux::Image> late = Decoded(strip[1]);
      CHECK(early && early->width == 64 && Block(*early) == 5);
      CHECK(late && late->width == 64 && Block(*late) == 25);
      CHECK(!strip[2]);
    }
  }

  const std::atomic<bool> running{false};
  std::vector<double> progress;
  const auto record = [&progress](double value) { progress.push_back(value); };

  // Trimmed and muted, the export starts at the trim start exactly.
  {
    ux::ExportRequest request;
    request.path = source;
    request.out_path = out;
    request.trim_start_ms = 1000;
    request.trim_end_ms = 2000;
    request.remove_audio = true;
    const ux::ExportOutcome outcome = ux::Export(request, record, running);
    const auto* done = std::get_if<ux::ExportDone>(&outcome);
    CHECK(done && done->width == kWidth && done->height == kHeight && done->duration_ms == 1000);
    CHECK(!progress.empty() && progress.front() == 0 && progress.back() == 1);
    for (size_t i = 1; i < progress.size(); i++) CHECK(progress[i] >= progress[i - 1]);
    std::unique_ptr<ux::VideoReader> reader;
    CHECK(SUCCEEDED(ux::VideoReader::Open(out, true, reader)));
    if (reader) {
      CHECK(!reader->audio());
      CHECK(reader->duration() && std::abs(*reader->duration() / 10000 - 1000) <= 50);
    }
    reader.reset();
    const std::optional<ux::Image> first = Frame(out, 0);
    const std::optional<ux::Image> last = Frame(out, 900);
    CHECK(first && Block(*first) == 10);
    CHECK(last && Block(*last) == 19);
  }

  // Turned a quarter clockwise into a portrait canvas, with an overlay drawn
  // over the green quadrant before the turn, and with its audio.
  {
    ux::Image strokes;
    strokes.Reset(kWidth, kHeight, 0);
    for (UINT y = 40; y < 100; y++) {
      for (UINT x = 200; x < 260; x++) {
        for (int c = 0; c < 4; c++) {
          strokes.pixels[(static_cast<size_t>(y) * kWidth + x) * 4 + c] = static_cast<uint8_t>(kMagenta >> (8 * c));
        }
      }
    }
    std::vector<uint8_t> png;
    CHECK(SUCCEEDED(ux::EncodePng(strokes, png)));
    const std::wstring overlay = TempPath(L"ux_video_export_overlay.png");
    CHECK(WriteBytes(overlay, png));
    ux::ExportRequest request;
    request.path = source;
    request.out_path = out;
    request.geometry = ux::ExportGeometry{{0, -1, kHeight, 1, 0, 0}, kHeight, kWidth};
    request.video_bitrate = 1000000;
    request.overlay_path = overlay;
    const ux::ExportOutcome outcome = ux::Export(request, [](double) {}, running);
    const auto* done = std::get_if<ux::ExportDone>(&outcome);
    CHECK(done && done->width == kHeight && done->height == kWidth && std::abs(done->duration_ms - 3000) <= 100);
    std::unique_ptr<ux::VideoReader> reader;
    CHECK(SUCCEEDED(ux::VideoReader::Open(out, true, reader)));
    if (reader) CHECK(reader->audio().has_value());
    reader.reset();
    if (const std::optional<ux::Image> frame = Frame(out, 500)) {
      CHECK(frame->width == kHeight && frame->height == kWidth);
      CHECK(Near(At(*frame, 60, 80), Of(kBlue), kTolerance));
      CHECK(Near(At(*frame, 180, 80), Of(kRed), kTolerance));
      CHECK(Near(At(*frame, 60, 240), Of(kYellow), kTolerance));
      CHECK(Near(At(*frame, 220, 300), Of(kGreen), kTolerance));
      CHECK(Near(At(*frame, 170, 230), Of(kMagenta), kTolerance));
    } else {
      CHECK(false);
    }
    DeleteFileW(overlay.c_str());
  }

  // Cancelled while it runs, the export leaves no file.
  {
    std::atomic<bool> cancelled{false};
    ux::ExportRequest request;
    request.path = source;
    request.out_path = out;
    request.geometry = ux::ExportGeometry{{-1, 0, kWidth, 0, 1, 0}, kWidth, kHeight};
    const ux::ExportOutcome outcome = ux::Export(
        request, [&cancelled](double value) { cancelled = cancelled || value > 0.2; }, cancelled);
    const auto* failed = std::get_if<ux::ExportFailed>(&outcome);
    CHECK(failed && failed->code == "cancelled");
    CHECK(Missing(out));
  }

  // A tone that ends just after the video is read to its end. When the reader
  // ends the video before that tone varies from run to run, so it exports
  // five times.
  {
    const std::wstring longer = TempPath(L"ux_video_export_longer.mp4");
    CHECK(SUCCEEDED(WriteSource(longer, kAudioRate * kSeconds + 1300)));
    ux::ExportRequest request;
    request.path = longer;
    request.out_path = out;
    for (int i = 0; i < 5; i++) {
      const ux::ExportOutcome outcome = ux::Export(request, [](double) {}, running);
      const auto* done = std::get_if<ux::ExportDone>(&outcome);
      CHECK(done && std::abs(done->duration_ms - kSeconds * 1000) <= 100);
    }
    DeleteFileW(longer.c_str());
  }

  {
    ux::ExportRequest request;
    request.path = source;
    request.out_path = out;
    request.trim_start_ms = 5000;
    const ux::ExportOutcome outcome = ux::Export(request, [](double) {}, running);
    const auto* failed = std::get_if<ux::ExportFailed>(&outcome);
    CHECK(failed && failed->code == "bad_trim");
  }
  {
    ux::ExportRequest request;
    request.path = TempPath(L"ux_video_export_missing.mp4");
    request.out_path = out;
    const ux::ExportOutcome outcome = ux::Export(request, [](double) {}, running);
    const auto* failed = std::get_if<ux::ExportFailed>(&outcome);
    CHECK(failed && failed->code == "session_failed");
  }

  DeleteFileW(source.c_str());
  DeleteFileW(out.c_str());
}
