#include <cstdio>
#include <cstring>

#include "check.h"

void FileTypesSuite();
void ImageProbeSuite();
void PlatformThreadSuite();
void UrlDetectSuite();
void VideoDeviceSuite();

namespace {

struct Suite {
  const char* name;
  void (*run)();
};

constexpr Suite kSuites[] = {
    {"file_types", FileTypesSuite},
    {"image_probe", ImageProbeSuite},
    {"platform_thread", PlatformThreadSuite},
    {"url_detect", UrlDetectSuite},
    {"video_device", VideoDeviceSuite},
};

}  // namespace

// ux_test <suite>: runs one suite and exits 1 when a check failed.
int main(int argc, char** argv) {
  for (const Suite& suite : kSuites) {
    if (argc == 2 && std::strcmp(argv[1], suite.name) == 0) {
      suite.run();
      std::printf("%s: %d failed checks\n", suite.name, check_failures.load());
      return check_failures > 0 ? 1 : 0;
    }
  }
  std::printf("usage: ux_test <suite>\n");
  return 2;
}
