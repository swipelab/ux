#ifndef UX_X_PLUGIN_H_
#define UX_X_PLUGIN_H_

#include <flutter/plugin_registrar_windows.h>

namespace ux {

// Registers each area's handler with the registrar, which owns them.
class XPlugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);
};

}  // namespace ux

#endif  // UX_X_PLUGIN_H_
