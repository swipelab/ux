#include "video_thumbnail.h"

#include <algorithm>
#include <cmath>
#include <memory>

#include "media_foundation.h"
#include "text.h"
#include "video_reader.h"

namespace ux {

namespace {

constexpr LONGLONG kTicksPerMs = 10000;
// The darwin plugin's requestedTimeToleranceBefore and After.
constexpr LONGLONG kTolerance = 500 * kTicksPerMs;

std::optional<Thumbnail> Encoded(const Image& canvas) {
  Thumbnail thumbnail{{}, canvas.width, canvas.height};
  if (FAILED(EncodePng(canvas, thumbnail.png))) return std::nullopt;
  return thumbnail;
}

std::optional<Thumbnail> Scaled(const Image& frame, int turns, std::optional<UINT> max_width) {
  const auto [width, height] = Turned(frame.width, frame.height, turns);
  UINT scaled_width = width;
  UINT scaled_height = height;
  if (max_width && width > *max_width) {
    scaled_width = *max_width;
    scaled_height = static_cast<UINT>(std::max(1L, std::lround(static_cast<double>(height) * *max_width / width)));
  }
  Image canvas;
  canvas.Reset(scaled_width, scaled_height, 0);
  Draw(frame, turns,
       Affine::Scale(static_cast<double>(scaled_width) / width, static_cast<double>(scaled_height) / height), canvas);
  return Encoded(canvas);
}

std::optional<Thumbnail> Baked(const Image& frame, int turns, const ThumbnailBake& bake) {
  const UINT longest = std::max(bake.width, bake.height);
  const double scale =
      bake.max_longest && longest > *bake.max_longest ? static_cast<double>(*bake.max_longest) / longest : 1;
  const UINT width = static_cast<UINT>(std::max(1L, std::lround(bake.width * scale)));
  const UINT height = static_cast<UINT>(std::max(1L, std::lround(bake.height * scale)));
  const Affine fit = bake.affine.Then(
      Affine::Scale(static_cast<double>(width) / bake.width, static_cast<double>(height) / bake.height));
  Image canvas;
  canvas.Reset(width, height, 0);
  Draw(frame, turns, fit, canvas);
  Image overlay;
  if (bake.overlay && SUCCEEDED(DecodeImage(*bake.overlay, overlay))) Draw(overlay, 0, fit, canvas);
  return Encoded(canvas);
}

}  // namespace

ThumbnailResult VideoThumbnail(const std::wstring& path, int64_t at_ms, std::optional<UINT> max_width,
                               const std::optional<ThumbnailBake>& bake) {
  MediaWork media;
  if (FAILED(media.status())) return ThumbnailFailed{"Media Foundation is unavailable (" + Hex(media.status()) + ")"};
  std::unique_ptr<VideoReader> reader;
  HRESULT hr = VideoReader::Open(path, false, reader);
  if (FAILED(hr)) return ThumbnailFailed{"cannot read the video (" + Hex(hr) + ")"};
  std::optional<Decoded> frame;
  hr = reader->FrameAt(at_ms * kTicksPerMs, kTolerance, frame);
  if (FAILED(hr)) return ThumbnailFailed{"cannot decode a frame (" + Hex(hr) + ")"};
  if (!frame) return ThumbnailFailed{"no frame within 500 ms of " + std::to_string(at_ms) + " ms"};
  return bake ? Baked(frame->frame, reader->turns(), *bake) : Scaled(frame->frame, reader->turns(), max_width);
}

std::vector<std::optional<Thumbnail>> VideoThumbnails(const std::wstring& path,
                                                      const std::vector<int64_t>& timestamps_ms, UINT max_width) {
  std::vector<std::optional<Thumbnail>> thumbnails(timestamps_ms.size());
  MediaWork media;
  std::unique_ptr<VideoReader> reader;
  if (FAILED(media.status()) || FAILED(VideoReader::Open(path, false, reader))) return thumbnails;
  for (size_t i = 0; i < timestamps_ms.size(); i++) {
    std::optional<Decoded> frame;
    if (SUCCEEDED(reader->FrameAt(timestamps_ms[i] * kTicksPerMs, kTolerance, frame)) && frame) {
      thumbnails[i] = Scaled(frame->frame, reader->turns(), max_width);
    }
  }
  return thumbnails;
}

}  // namespace ux
