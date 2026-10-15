#include <optional>
#include <string>
#include <vector>

#include "../file_types.h"
#include "check.h"

using ux::MimeTypeOf;
using ux::PickExtensions;

namespace {

using Extensions = std::vector<std::wstring>;

const Extensions kImages = {L"jpg", L"jpeg", L"png", L"gif", L"webp", L"bmp", L"heic", L"heif"};
const Extensions kVideos = {L"mp4", L"m4v", L"mov"};

}  // namespace

void FileTypesSuite() {
  Extensions media = kImages;
  media.insert(media.end(), kVideos.begin(), kVideos.end());
  CHECK(PickExtensions({"image/*"}) == kImages);
  CHECK(PickExtensions({"image/*", "video/*"}) == media);

  CHECK(PickExtensions({"video/quicktime", "IMAGE/JPEG"}) == Extensions({L"mov", L"jpg", L"jpeg"}));
  CHECK(PickExtensions({"image/png", "image/*"}) ==
        Extensions({L"png", L"jpg", L"jpeg", L"gif", L"webp", L"bmp", L"heic", L"heif"}));
  CHECK(PickExtensions({"application/pdf"}) == Extensions({L"pdf"}));

  CHECK(!PickExtensions({}));
  CHECK(!PickExtensions({"*/*"}));
  CHECK(!PickExtensions({"audio/*"}));
  CHECK(!PickExtensions({"image/png", "application/x-ux-unknown"}));

  CHECK(MimeTypeOf(L"JPG") == std::optional<std::string>("image/jpeg"));
  CHECK(MimeTypeOf(L"mov") == std::optional<std::string>("video/quicktime"));
  CHECK(MimeTypeOf(L"txt") == std::optional<std::string>("text/plain"));
  CHECK(!MimeTypeOf(L"x-ux-unknown"));
}
