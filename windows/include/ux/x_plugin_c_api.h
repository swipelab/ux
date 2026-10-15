#ifndef FLUTTER_PLUGIN_X_PLUGIN_C_API_H_
#define FLUTTER_PLUGIN_X_PLUGIN_C_API_H_

#include <flutter_plugin_registrar.h>
#include <guiddef.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif

#if defined(__cplusplus)
extern "C" {
#endif

FLUTTER_PLUGIN_EXPORT void XPluginCApiRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar);

// Names the COM class that takes the clicks on this process's toasts: the
// ToastActivatorCLSID of the shortcut that carries the process's
// AppUserModelID. A host calls it before it registers its plugins.
FLUTTER_PLUGIN_EXPORT void XPluginCApiSetToastActivator(const GUID* activator);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // FLUTTER_PLUGIN_X_PLUGIN_C_API_H_
