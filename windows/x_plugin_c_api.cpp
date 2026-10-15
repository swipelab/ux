#include "include/ux/x_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "notifications_plugin.h"
#include "x_plugin.h"

void XPluginCApiRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  ux::XPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}

void XPluginCApiSetToastActivator(const GUID* activator) {
  ux::NotificationsPlugin::SetToastActivator(*activator);
}
