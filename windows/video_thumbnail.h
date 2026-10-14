#ifndef UX_VIDEO_THUMBNAIL_H_
#define UX_VIDEO_THUMBNAIL_H_

#include <windows.h>

#include <cstdint>
#include <optional>
#include <string>
#include <variant>
#include <vector>

#include "raster.h"

namespace ux {

// A frame as `videoThumbnail` and `videoThumbnails` answer it.
struct Thumbnail {
  std::vector<uint8_t> png;
  UINT width;
  UINT height;
};

// FilePluginBake's geometry: [affine] maps upright source pixels into a
// [width]×[height] canvas, the [overlay] image, in upright source pixels, is
// drawn over the frame through it, and the canvas is scaled so that its
// longest edge fits [max_longest].
struct ThumbnailBake {
  Affine affine;
  UINT width;
  UINT height;
  std::optional<std::wstring> overlay;
  std::optional<UINT> max_longest;
};

// Why a video gave no frame.
struct ThumbnailFailed {
  std::string message;
};

// A thumbnail, or none when its PNG could not be made.
using ThumbnailResult = std::variant<std::optional<Thumbnail>, ThumbnailFailed>;

// The frame of the video at [path] nearest [at_ms] within 500 ms, upright:
// baked by [bake], or else no wider than [max_width], when it has one. An
// overlay that cannot be decoded is left out. It runs off the platform thread.
ThumbnailResult VideoThumbnail(const std::wstring& path, int64_t at_ms, std::optional<UINT> max_width,
                               const std::optional<ThumbnailBake>& bake);

// The frames nearest [timestamps_ms], in their order, each as VideoThumbnail
// answers it for [max_width], or none for one that failed. It runs off the
// platform thread.
std::vector<std::optional<Thumbnail>> VideoThumbnails(const std::wstring& path,
                                                      const std::vector<int64_t>& timestamps_ms, UINT max_width);

}  // namespace ux

#endif  // UX_VIDEO_THUMBNAIL_H_
