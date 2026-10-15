#ifndef UX_VIDEO_EXPORT_H_
#define UX_VIDEO_EXPORT_H_

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <variant>

#include "raster.h"

namespace ux {

// [affine] maps upright source pixels into a [width]×[height] canvas.
struct ExportGeometry {
  Affine affine;
  UINT width;
  UINT height;
};

// An export as `ux/video/export`'s `start` asks for it.
struct ExportRequest {
  std::wstring path;
  std::wstring out_path;
  std::optional<int64_t> trim_start_ms;
  std::optional<int64_t> trim_end_ms;
  bool remove_audio = false;
  // None keeps the upright source frame.
  std::optional<ExportGeometry> geometry;
  // In bits per second; none takes the source's.
  std::optional<int64_t> video_bitrate;
  // An image in upright source pixels, drawn over each frame before the
  // geometry maps it.
  std::optional<std::wstring> overlay_path;
};

struct ExportDone {
  UINT width;
  UINT height;
  int64_t duration_ms;
};

// Why an export failed, as the `error` event carries it.
struct ExportFailed {
  std::string code;
  std::string message;
};

using ExportOutcome = std::variant<ExportDone, ExportFailed>;

// Re-encodes [request]'s source into an H.264/AAC MP4 at its out path on the
// calling thread, reporting progress from 0 to 1 to [progress]. It fails with
// `cancelled` once [cancelled] is set, and deletes its partial file whenever it
// fails. An overlay that cannot be decoded is left out.
ExportOutcome Export(const ExportRequest& request, const std::function<void(double)>& progress,
                     const std::atomic<bool>& cancelled);

}  // namespace ux

#endif  // UX_VIDEO_EXPORT_H_
