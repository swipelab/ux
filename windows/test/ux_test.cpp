#include <cstdio>
#include <cstring>

#include "check.h"

void DibSuite();
void DropSuite();
void FileTypesSuite();
void ImageProbeSuite();
void PlatformThreadSuite();
void ToastSuite();
void UrlDetectSuite();
void VideoDeviceSuite();
void WindowSuite();

namespace {

struct Suite {
  const char* name;
  void (*run)();
};

// CTest's SKIP_RETURN_CODE for ux_test.
constexpr int kSkipped = 77;

constexpr Suite kSuites[] = {
    {"dib", DibSuite},
    {"drop", DropSuite},
    {"file_types", FileTypesSuite},
    {"image_probe", ImageProbeSuite},
    {"platform_thread", PlatformThreadSuite},
    {"toast", ToastSuite},
    {"url_detect", UrlDetectSuite},
    {"video_device", VideoDeviceSuite},
    {"window", WindowSuite},
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
