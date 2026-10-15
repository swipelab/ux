#ifndef UX_DIB_H_
#define UX_DIB_H_

#include <cstdint>
#include <optional>
#include <vector>

namespace ux {

// [dib], a packed bitmap as the clipboard holds CF_DIB and CF_DIBV5, encoded as
// PNG with WIC. It reads a BITMAPINFOHEADER, BITMAPV4HEADER or BITMAPV5HEADER
// over uncompressed rows of 1, 4, 8, 16, 24 or 32 bits a pixel, bottom-up or
// top-down. A 16- or 32-bit pixel takes its alpha from a V4 or V5 header's
// alpha mask, and any other pixel is opaque. None when [dib] is not such a
// bitmap or WIC fails.
std::optional<std::vector<uint8_t>> DibToPng(const std::vector<uint8_t>& dib);

}  // namespace ux

#endif  // UX_DIB_H_
