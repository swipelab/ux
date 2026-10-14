#include "x_plugin.h"

#include <memory>

#include "url_plugin.h"

namespace ux {

void XPlugin::RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
  registrar->AddPlugin(std::make_unique<UrlPlugin>(registrar->messenger()));
}

}  // namespace ux
