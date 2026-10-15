#ifndef UX_RASTER_H_
#define UX_RASTER_H_

#include <windows.h>

#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace ux {

// Premultiplied BGRA pixels in top-down rows of width * 4 bytes.
struct Image {
  UINT width = 0;
  UINT height = 0;
  std::vector<uint8_t> pixels;

  // Sizes the image to [w]×[h], every pixel [bgra].
  void Reset(UINT w, UINT h, uint32_t bgra);
};

// A 2D affine map, row-major as `XVideoExportRequest.transform` carries it:
// x' = a x + b y + tx, y' = d x + e y + ty.
struct Affine {
  double a = 1;
  double b = 0;
  double tx = 0;
  double d = 0;
  double e = 1;
  double ty = 0;

  static Affine Scale(double sx, double sy);

  // This map, then [next].
  Affine Then(const Affine& next) const;

  // None when the map is singular.
  std::optional<Affine> Inverse() const;
};

// The size of a [width]×[height] frame turned [turns] quarter turns.
std::pair<UINT, UINT> Turned(UINT width, UINT height, int turns);

// Draws [source] over [canvas]: turned [turns] quarter turns clockwise, then
// mapped through [affine] from those upright pixels to canvas pixels. A canvas
// pixel whose centre maps outside the source keeps its value. Where the map
// shrinks the source, each canvas pixel averages several samples.
void Draw(const Image& source, int turns, const Affine& affine, Image& canvas);

// A limited-range YCbCr matrix.
enum class YuvMatrix { kBt601, kBt709 };

// Writes the opaque [image], whose sides are even, as NV12 in [matrix]: its
// rows of luma, then half as many rows of interleaved Cb and Cr, each row
// [stride] bytes from the one before.
void ToNv12(const Image& image, YuvMatrix matrix, uint8_t* nv12, size_t stride);

// The PNG of [image], with straight alpha.
HRESULT EncodePng(const Image& image, std::vector<uint8_t>& png);

// Decodes the image file at [path] into [image].
HRESULT DecodeImage(const std::wstring& path, Image& image);

}  // namespace ux

#endif  // UX_RASTER_H_
