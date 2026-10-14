#ifndef UX_IMAGE_PROBE_H_
#define UX_IMAGE_PROBE_H_

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace ux {

// An image's dimensions with its orientation applied.
struct UprightSize {
  uint32_t width;
  uint32_t height;
};

// An image rendered down by ProbeThumbnail.
struct ImageThumbnail {
  // The source's upright dimensions.
  UprightSize source;
  // The dimensions of [png].
  UprightSize size;
  std::vector<uint8_t> png;
};

// The upright dimensions of the image at [path], read from its header, or none
// when no installed WIC codec decodes it.
std::optional<UprightSize> ProbeSize(const std::wstring& path);

// The image at [path], upright, scaled down to at most [max_longest] pixels on
// its longest edge and encoded as PNG, or none when no installed WIC codec
// decodes it. An image within the bound keeps its size.
std::optional<ImageThumbnail> ProbeThumbnail(const std::wstring& path, uint64_t max_longest);

}  // namespace ux

#endif  // UX_IMAGE_PROBE_H_
