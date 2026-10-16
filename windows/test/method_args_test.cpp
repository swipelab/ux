#include <optional>
#include <string>

#include "../method_args.h"
#include "check.h"

using flutter::EncodableMap;
using flutter::EncodableValue;
using ux::PathArg;

void MethodArgsSuite() {
  const EncodableMap args = {{EncodableValue("path"), EncodableValue("C:/Users/a\\b/c.txt")}};
  CHECK(PathArg(&args, "path") == std::optional<std::wstring>(L"C:\\Users\\a\\b\\c.txt"));
}
