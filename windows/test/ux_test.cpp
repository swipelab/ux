#include <cstdio>
#include <cstring>

#include "check.h"

void CameraSuite();
void CryptoSuite();
void DibSuite();
void DropSuite();
void FileTypesSuite();
void ImageProbeSuite();
void MediaFoundationSuite();
void MethodArgsSuite();
void PlatformThreadSuite();
void RasterSuite();
void ToastSuite();
void UrlDetectSuite();
void VideoExportSuite();
void WindowSuite();
void WorkQueueSuite();

namespace {

struct Suite {
  const char* name;
  void (*run)();
};

// CTest's SKIP_RETURN_CODE for ux_test.
constexpr int kSkipped = 77;

constexpr Suite kSuites[] = {
    {"camera", CameraSuite},
    {"crypto", CryptoSuite},
    {"dib", DibSuite},
    {"drop", DropSuite},
    {"file_types", FileTypesSuite},
    {"image_probe", ImageProbeSuite},
    {"media_foundation", MediaFoundationSuite},
    {"method_args", MethodArgsSuite},
    {"platform_thread", PlatformThreadSuite},
    {"raster", RasterSuite},
    {"toast", ToastSuite},
    {"url_detect", UrlDetectSuite},
    {"video_export", VideoExportSuite},
    {"window", WindowSuite},
    {"work_queue", WorkQueueSuite},
};

}  // namespace

// ux_test <suite>: runs one suite and exits 1 when a check failed, or
// kSkipped when the suite cannot run in this process.
int main(int argc, char** argv) {
  for (const Suite& suite : kSuites) {
    if (argc == 2 && std::strcmp(argv[1], suite.name) == 0) {
      suite.run();
      if (check_skipped) {
        std::printf("%s: skipped: %s\n", suite.name, *check_skipped);
        return kSkipped;
      }
      std::printf("%s: %d failed checks\n", suite.name, check_failures.load());
      return check_failures > 0 ? 1 : 0;
    }
  }
  std::printf("usage: ux_test <suite>\n");
  return 2;
}
