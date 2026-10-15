#ifndef UX_TOAST_H_
#define UX_TOAST_H_

#include <windows.h>

#include <unknwn.h>
#include <winrt/Windows.Data.Xml.Dom.h>

#include <map>
#include <optional>
#include <string>

namespace ux {

// The toast `show` posts: ToastGeneric's [title] and [body] lines, with [data]
// as a JSON object in the launch argument that a click hands back.
winrt::Windows::Data::Xml::Dom::XmlDocument ToastXml(const std::wstring& title, const std::wstring& body,
                                                     const std::map<std::wstring, std::wstring>& data);

// The data a toast's [launch] argument carries, or none when it is not a JSON
// object of strings.
std::optional<std::map<std::wstring, std::wstring>> ToastData(const std::wstring& launch);

}  // namespace ux

#endif  // UX_TOAST_H_
