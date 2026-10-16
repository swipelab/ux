#include "method_args.h"

#include <algorithm>

#include "text.h"

namespace ux {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

std::optional<int64_t> Int(const EncodableValue& value) {
  if (const auto* int32 = std::get_if<int32_t>(&value)) return *int32;
  if (const auto* int64 = std::get_if<int64_t>(&value)) return *int64;
  return std::nullopt;
}

std::optional<double> Double(const EncodableValue& value) {
  if (const auto* number = std::get_if<double>(&value)) return *number;
  if (const std::optional<int64_t> number = Int(value)) return static_cast<double>(*number);
  return std::nullopt;
}

}  // namespace

const EncodableValue* Arg(const EncodableMap* args, const char* key) {
  if (args == nullptr) return nullptr;
  const auto it = args->find(EncodableValue(key));
  return it == args->end() ? nullptr : &it->second;
}

std::optional<int64_t> IntArg(const EncodableMap* args, const char* key) {
  const EncodableValue* value = Arg(args, key);
  return value == nullptr ? std::nullopt : Int(*value);
}

std::optional<std::vector<double>> DoublesArg(const EncodableMap* args, const char* key) {
  const EncodableValue* value = Arg(args, key);
  if (const auto* typed = std::get_if<std::vector<double>>(value)) return *typed;
  const auto* list = std::get_if<EncodableList>(value);
  if (list == nullptr) return std::nullopt;
  std::vector<double> numbers;
  for (const EncodableValue& item : *list) {
    const std::optional<double> number = Double(item);
    if (!number) return std::nullopt;
    numbers.push_back(*number);
  }
  return numbers;
}

std::optional<std::vector<int64_t>> IntsArg(const EncodableMap* args, const char* key) {
  const auto* list = std::get_if<EncodableList>(Arg(args, key));
  if (list == nullptr) return std::nullopt;
  std::vector<int64_t> numbers;
  for (const EncodableValue& item : *list) {
    const std::optional<int64_t> number = Int(item);
    if (!number) return std::nullopt;
    numbers.push_back(*number);
  }
  return numbers;
}

std::optional<std::wstring> StringArg(const EncodableMap* args, const char* key) {
  const auto* value = std::get_if<std::string>(Arg(args, key));
  if (value == nullptr) return std::nullopt;
  return Utf16(*value);
}

std::optional<std::wstring> PathArg(const EncodableMap* args, const char* key) {
  std::optional<std::wstring> path = StringArg(args, key);
  if (path) std::replace(path->begin(), path->end(), L'/', L'\\');
  return path;
}

}  // namespace ux
