#ifndef UX_CAMERA_DEVICES_H_
#define UX_CAMERA_DEVICES_H_

#include <windows.h>

#include <optional>
#include <string>
#include <vector>

namespace ux {

// A video capture device, as `ux/camera` names it: its symbolic link, in
// UTF-8.
struct CameraDevice {
  std::string id;
};

// Sets [devices] to the video capture devices, in Media Foundation's order, on
// a thread where a MediaWork has started.
HRESULT EnumerateCameras(std::vector<CameraDevice>& devices);

// Whether Windows's Privacy & security settings let desktop apps use
// [capability], `webcam` or `microphone`: the device's, the user's and the
// user's desktop-app consent.
bool CaptureAllowed(const wchar_t* capability);

// Whether consent [values], each a ConsentStore key's `Value`, or none for a
// key that holds none, allow the capability: none of them reads `Deny`.
bool ConsentAllows(const std::vector<std::optional<std::wstring>>& values);

}  // namespace ux

#endif  // UX_CAMERA_DEVICES_H_
