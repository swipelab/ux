#ifndef UX_TEXT_H_
#define UX_TEXT_H_

#include <optional>
#include <string>

namespace ux {

// [utf8] in UTF-16, or none when it is not UTF-8.
std::optional<std::wstring> Utf16(const std::string& utf8);

// [utf16] in UTF-8, or none when it is not UTF-16.
std::optional<std::string> Utf8(const std::wstring& utf16);

}  // namespace ux

#endif  // UX_TEXT_H_
