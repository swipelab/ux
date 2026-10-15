#include <windows.h>

#include <map>
#include <optional>
#include <string>

#include "../toast.h"
#include "check.h"

namespace {

void CheckToast() {
  const std::map<std::wstring, std::wstring> data = {{L"dialogId", L"G-\"7\" <&>"}, {L"messageId", L"42 é中"}};
  const auto xml = ux::ToastXml(L"Ann & <Bo>", L"hi \"there\"", data);
  const auto toast = xml.DocumentElement();
  CHECK(toast.TagName() == L"toast");
  CHECK(xml.SelectSingleNode(L"/toast/visual/binding[@template='ToastGeneric']") != nullptr);
  const auto texts = xml.SelectNodes(L"/toast/visual/binding/text");
  CHECK(texts.Length() == 2);
  CHECK(texts.Item(0).InnerText() == L"Ann & <Bo>");
  CHECK(texts.Item(1).InnerText() == L"hi \"there\"");
  CHECK(ux::ToastData(std::wstring(toast.GetAttribute(L"launch"))) == data);

  CHECK(ux::ToastData(L"{\"dialogId\":7}") == std::nullopt);
  CHECK(ux::ToastData(L"dialogId=7") == std::nullopt);
}

}  // namespace

void ToastSuite() {
  CHECK(SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED)));
  CheckToast();
  CoUninitialize();
}
