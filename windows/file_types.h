#ifndef UX_FILE_TYPES_H_
#define UX_FILE_TYPES_H_

#include <optional>
#include <string>
#include <vector>

namespace ux {

// The extensions, without their dot, that a pick filtered to [mime_types]
// allows, in the order the types name them. Empty when the pick allows every
// file: no type, `*/*`, or a type whose extensions are unknown.
std::vector<std::wstring> PickExtensions(const std::vector<std::string>& mime_types);

// The MIME type of a file with [extension], without its dot, when it is known.
std::optional<std::string> MimeTypeOf(const std::wstring& extension);

}  // namespace ux

#endif  // UX_FILE_TYPES_H_
