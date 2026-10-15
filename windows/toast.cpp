#include "toast.h"

#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.Collections.h>

namespace ux {

namespace {

using winrt::Windows::Data::Json::JsonObject;
using winrt::Windows::Data::Json::JsonValue;
using winrt::Windows::Data::Json::JsonValueType;
using winrt::Windows::Data::Xml::Dom::XmlDocument;
using winrt::Windows::Data::Xml::Dom::XmlElement;

XmlElement Append(XmlDocument& document, const winrt::Windows::Data::Xml::Dom::IXmlNode& parent, const wchar_t* name) {
  XmlElement element = document.CreateElement(name);
  parent.AppendChild(element);
  return element;
}

}  // namespace

XmlDocument ToastXml(const std::wstring& title, const std::wstring& body,
                     const std::map<std::wstring, std::wstring>& data) {
  JsonObject launch;
  for (const auto& [key, value] : data) launch.SetNamedValue(key, JsonValue::CreateStringValue(value));
  XmlDocument document;
  XmlElement toast = Append(document, document, L"toast");
  toast.SetAttribute(L"launch", launch.Stringify());
  XmlElement binding = Append(document, Append(document, toast, L"visual"), L"binding");
  binding.SetAttribute(L"template", L"ToastGeneric");
  Append(document, binding, L"text").InnerText(title);
  Append(document, binding, L"text").InnerText(body);
  return document;
}

std::optional<std::map<std::wstring, std::wstring>> ToastData(const std::wstring& launch) {
  JsonObject object{nullptr};
  if (!JsonObject::TryParse(launch, object)) return std::nullopt;
  std::map<std::wstring, std::wstring> data;
  for (const auto& entry : object) {
    if (entry.Value().ValueType() != JsonValueType::String) return std::nullopt;
    data.emplace(entry.Key(), entry.Value().GetString());
  }
  return data;
}

}  // namespace ux
