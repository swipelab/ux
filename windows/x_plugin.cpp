#include "x_plugin.h"

#include <memory>

#include "file_plugin.h"
#include "url_plugin.h"
#include "video_exporter_plugin.h"
#include "video_player_plugin.h"

namespace ux {

void XPlugin::RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
  registrar->AddPlugin(std::make_unique<FilePlugin>(registrar));
  registrar->AddPlugin(std::make_unique<UrlPlugin>(registrar->messenger()));
  registrar->AddPlugin(std::make_unique<VideoPlayerPlugin>(registrar));
  registrar->AddPlugin(std::make_unique<VideoExporterPlugin>(registrar->messenger()));
}

}  // namespace ux
