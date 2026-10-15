#ifndef UX_METHOD_ARGS_H_
#define UX_METHOD_ARGS_H_

#include <flutter/encodable_value.h>

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace ux {

// The value under [key] in a method call's argument map, or null when the map
// or the key is absent.
const flutter::EncodableValue* Arg(const flutter::EncodableMap* args, const char* key);

// The integer under [key].
std::optional<int64_t> IntArg(const flutter::EncodableMap* args, const char* key);

// The numbers under [key], from a list of numbers or a Float64List.
std::optional<std::vector<double>> DoublesArg(const flutter::EncodableMap* args, const char* key);

// The integers under [key], from a list of integers.
std::optional<std::vector<int64_t>> IntsArg(const flutter::EncodableMap* args, const char* key);

// The path under [key] as a Windows path, which Dart may give with either
// separator.
std::optional<std::wstring> PathArg(const flutter::EncodableMap* args, const char* key);

}  // namespace ux

#endif  // UX_METHOD_ARGS_H_
