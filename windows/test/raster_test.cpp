#include <windows.h>

#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

#include "../raster.h"
#include "check.h"
#include "support.h"

namespace {

ux::Image Pixels(UINT width, UINT height, const std::vector<uint32_t>& bgra) {
  ux::Image image;
  image.Reset(width, height, 0);
  for (size_t i = 0; i < bgra.size(); i++) {
    for (int c = 0; c < 4; c++) image.pixels[i * 4 + c] = static_cast<uint8_t>(bgra[i] >> (8 * c));
  }
  return image;
}

// [canvas] holds [expected], row by row.
bool Holds(const ux::Image& canvas, UINT width, UINT height, const std::vector<uint32_t>& expected) {
  if (canvas.width != width || canvas.height != height) return false;
  for (UINT y = 0; y < height; y++) {
    for (UINT x = 0; x < width; x++) {
      if (At(canvas, x, y) != Of(expected[static_cast<size_t>(y) * width + x])) return false;
    }
  }
  return true;
}

ux::Image Drawn(const ux::Image& source, int turns, const ux::Affine& affine, UINT width, UINT height,
                uint32_t background = 0) {
  ux::Image canvas;
  canvas.Reset(width, height, background);
  ux::Draw(source, turns, affine, canvas);
  return canvas;
}

}  // namespace

void RasterSuite() {
  constexpr uint32_t A = 0xFF000001, B = 0xFF000002, C = 0xFF000003, D = 0xFF000004, E = 0xFF000005,
                     F = 0xFF000006;
  // Stored as A B C over D E F.
  const ux::Image stored = Pixels(3, 2, {A, B, C, D, E, F});

  CHECK(ux::Turned(3, 2, 1) == std::make_pair(2u, 3u));
  CHECK(Holds(Drawn(stored, 0, {}, 3, 2), 3, 2, {A, B, C, D, E, F}));
  CHECK(Holds(Drawn(stored, 1, {}, 2, 3), 2, 3, {D, A, E, B, F, C}));
  CHECK(Holds(Drawn(stored, 2, {}, 3, 2), 3, 2, {F, E, D, C, B, A}));
  CHECK(Holds(Drawn(stored, 3, {}, 2, 3), 2, 3, {C, F, B, E, A, D}));

  // A crop in upright space: the upright frame's right column, lower two rows.
  CHECK(Holds(Drawn(stored, 1, {1, 0, -1, 0, 1, -1}, 1, 2), 1, 2, {B, C}));
  // A mirror.
  CHECK(Holds(Drawn(stored, 0, {-1, 0, 3, 0, 1, 0}, 3, 2), 3, 2, {C, B, A, F, E, D}));

  // Canvas pixels the source does not cover keep the background.
  {
    constexpr uint32_t X = 0xFF0000FF;
    const ux::Image canvas = Drawn(Pixels(1, 1, {A}), 0, {1, 0, 1, 0, 1, 1}, 3, 3, X);
    CHECK(Holds(canvas, 3, 3, {X, X, X, X, A, X, X, X, X}));
  }

  // Magnified twice, black to white interpolates between the pixel centres.
  {
    const ux::Image canvas = Drawn(Pixels(2, 1, {0xFF000000, 0xFFFFFFFF}), 0, ux::Affine::Scale(2, 1), 4, 1);
    CHECK(Near(At(canvas, 0, 0), {0, 0, 0, 255}, 1));
    CHECK(Near(At(canvas, 1, 0), {64, 64, 64, 255}, 1));
    CHECK(Near(At(canvas, 2, 0), {191, 191, 191, 255}, 1));
    CHECK(Near(At(canvas, 3, 0), {255, 255, 255, 255}, 1));
  }

  // Shrunk four times, a checkerboard averages to grey.
  {
    std::vector<uint32_t> checker;
    for (int y = 0; y < 4; y++) {
      for (int x = 0; x < 4; x++) checker.push_back((x + y) % 2 == 0 ? 0xFF000000 : 0xFFFFFFFF);
    }
    const ux::Image canvas = Drawn(Pixels(4, 4, checker), 0, ux::Affine::Scale(0.25, 0.25), 1, 1);
    CHECK(Near(At(canvas, 0, 0), {128, 128, 128, 255}, 1));
  }

  // Half-opaque red over opaque blue, premultiplied.
  {
    const ux::Image canvas = Drawn(Pixels(1, 1, {0x80800000}), 0, {}, 1, 1, 0xFF0000FF);
    CHECK(Near(At(canvas, 0, 0), {127, 0, 128, 255}, 1));
  }

  // Turned 45 degrees about its centre, a 2×2 square covers the canvas centre
  // and leaves its corners.
  {
    const double c = std::cos(std::atan(1.0));
    const ux::Affine turn{c, -c, 2 - (c - c), c, c, 2 - (c + c)};
    const ux::Image canvas = Drawn(Pixels(2, 2, {A, A, A, A}), 0, turn, 4, 4);
    CHECK(At(canvas, 2, 2) == Of(A));
    CHECK(At(canvas, 0, 0) == Of(0));
    CHECK(At(canvas, 3, 3) == Of(0));
  }

  const ux::Affine singular{2, 0, 0, 0, 0, 0};
  CHECK(singular.Inverse() == std::nullopt);
  {
    const ux::Affine map{0, -1, 5, 1, 0, 2};
    const ux::Affine identity = map.Then(*map.Inverse());
    CHECK(std::abs(identity.a - 1) < 1e-12 && std::abs(identity.b) < 1e-12 && std::abs(identity.tx) < 1e-12);
    CHECK(std::abs(identity.d) < 1e-12 && std::abs(identity.e - 1) < 1e-12 && std::abs(identity.ty) < 1e-12);
  }

  // White, and red's BT.709 Y 63, Cb 102 and Cr 240 and BT.601 Y 81, Cb 90 and
  // Cr 240, each chroma pair averaging its 2×2 block.
  {
    const ux::Image block = Pixels(4, 2, {0xFFFFFFFF, 0xFFFFFFFF, 0xFFFF0000, 0xFFFF0000, 0xFFFFFFFF, 0xFFFFFFFF,
                                          0xFFFF0000, 0xFFFF0000});
    std::vector<uint8_t> nv12(4 * 2 * 3 / 2);
    ux::ToNv12(block, ux::YuvMatrix::kBt709, nv12.data(), 4);
    CHECK(nv12[0] == 235 && nv12[1] == 235 && nv12[4] == 235 && nv12[5] == 235);
    CHECK(nv12[2] == 63 && nv12[3] == 63 && nv12[6] == 63 && nv12[7] == 63);
    CHECK(nv12[8] == 128 && nv12[9] == 128);
    CHECK(nv12[10] == 102 && nv12[11] == 240);
    ux::ToNv12(block, ux::YuvMatrix::kBt601, nv12.data(), 4);
    CHECK(nv12[0] == 235 && nv12[2] == 81);
    CHECK(nv12[8] == 128 && nv12[9] == 128);
    CHECK(nv12[10] == 90 && nv12[11] == 240);
  }

  // A PNG holds straight alpha and decodes back premultiplied.
  {
    const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const ux::Image image = Pixels(2, 1, {0xFF102030, 0x80400000});
    std::vector<uint8_t> png;
    CHECK(SUCCEEDED(ux::EncodePng(image, png)));
    CHECK(png.size() > 8 && png[1] == 'P' && png[2] == 'N' && png[3] == 'G');
    const std::wstring path = TempPath(L"ux_raster_test.png");
    CHECK(WriteBytes(path, png));
    ux::Image decoded;
    CHECK(SUCCEEDED(ux::DecodeImage(path, decoded)));
    CHECK(decoded.width == 2 && decoded.height == 1);
    if (decoded.width == 2 && decoded.height == 1) {
      CHECK(At(decoded, 0, 0) == Of(0xFF102030));
      CHECK(Near(At(decoded, 1, 0), Of(0x80400000), 1));
    }
    DeleteFileW(path.c_str());
    if (SUCCEEDED(com)) CoUninitialize();
  }
}
