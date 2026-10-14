#include "file_types.h"

#include <windows.h>

#include <algorithm>

#include "text.h"

namespace ux {

namespace {

struct FileType {
  std::string mime_type;
  std::vector<std::wstring> extensions;
};

// The image and video files the app handles on Windows.
const std::vector<FileType>& MediaTypes() {
  static const std::vector<FileType> types = {
      {"image/jpeg", {L"jpg", L"jpeg"}}, {"image/png", {L"png"}},        {"image/gif", {L"gif"}},
      {"image/webp", {L"webp"}},         {"image/bmp", {L"bmp"}},        {"video/mp4", {L"mp4"}},
      {"video/x-m4v", {L"m4v"}},         {"video/quicktime", {L"mov"}},
  };
  return types;
}

template <typename Text>
Text AsciiLower(Text text) {
  for (auto& c : text) {
    if (c >= 'A' && c <= 'Z') c = static_cast<typename Text::value_type>(c - 'A' + 'a');
  }
  return text;
}

// A string value under HKEY_CLASSES_ROOT, where Windows records file types.
std::optional<std::wstring> ClassesValue(const std::wstring& key, const wchar_t* name) {
  DWORD size = 0;
  if (RegGetValueW(HKEY_CLASSES_ROOT, key.c_str(), name, RRF_RT_REG_SZ, nullptr, nullptr, &size) != ERROR_SUCCESS) {
    return std::nullopt;
  }
  std::wstring value(size / sizeof(wchar_t), L'\0');
  if (RegGetValueW(HKEY_CLASSES_ROOT, key.c_str(), name, RRF_RT_REG_SZ, nullptr, value.data(), &size) !=
      ERROR_SUCCESS) {
    return std::nullopt;
  }
  value.resize(wcsnlen(value.c_str(), value.size()));
  return value;
}

// The extensions of [mime_type], when they are known.
std::optional<std::vector<std::wstring>> ExtensionsOf(const std::string& mime_type) {
  for (const FileType& type : MediaTypes()) {
    if (type.mime_type == mime_type) return type.extensions;
  }
  if (mime_type.size() > 2 && mime_type.compare(mime_type.size() - 2, 2, "/*") == 0) {
    const std::string group = mime_type.substr(0, mime_type.size() - 1);
    std::vector<std::wstring> extensions;
    for (const FileType& type : MediaTypes()) {
      if (type.mime_type.compare(0, group.size(), group) == 0) {
        extensions.insert(extensions.end(), type.extensions.begin(), type.extensions.end());
      }
    }
    if (extensions.empty()) return std::nullopt;
    return extensions;
  }
  const std::optional<std::wstring> wide = Utf16(mime_type);
  if (!wide) return std::nullopt;
  const std::optional<std::wstring> extension = ClassesValue(L"MIME\\Database\\Content Type\\" + *wide, L"Extension");
  if (!extension || extension->size() < 2 || extension->front() != L'.') return std::nullopt;
  return std::vector<std::wstring>{AsciiLower(extension->substr(1))};
}

}  // namespace

std::optional<std::vector<std::wstring>> PickExtensions(const std::vector<std::string>& mime_types) {
  if (mime_types.empty()) return std::nullopt;
  std::vector<std::wstring> extensions;
  for (const std::string& mime_type : mime_types) {
    const std::optional<std::vector<std::wstring>> more = ExtensionsOf(AsciiLower(mime_type));
    if (!more) return std::nullopt;
    for (const std::wstring& extension : *more) {
      if (std::find(extensions.begin(), extensions.end(), extension) == extensions.end()) {
        extensions.push_back(extension);
      }
    }
  }
  return extensions;
}

std::optional<std::string> MimeTypeOf(const std::wstring& extension) {
  const std::wstring lower = AsciiLower(extension);
  for (const FileType& type : MediaTypes()) {
    if (std::find(type.extensions.begin(), type.extensions.end(), lower) != type.extensions.end()) {
      return type.mime_type;
    }
  }
  const std::optional<std::wstring> content_type = ClassesValue(L"." + lower, L"Content Type");
  if (!content_type) return std::nullopt;
  return Utf8(*content_type);
}

}  // namespace ux
