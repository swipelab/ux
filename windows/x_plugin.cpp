#include "x_plugin.h"

#include <memory>

#include "clipboard_plugin.h"
#include "drop_plugin.h"
#include "file_plugin.h"
#include "image_probe_plugin.h"
#include "notifications_plugin.h"
#include "url_plugin.h"
#include "video_player_plugin.h"
#include "window_plugin.h"

namespace ux {

void XPlugin::RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
  registrar->AddPlugin(std::make_unique<ClipboardPlugin>(registrar->messenger()));
  registrar->AddPlugin(std::make_unique<DropPlugin>(registrar));
  registrar->AddPlugin(std::make_unique<FilePlugin>(registrar));
  registrar->AddPlugin(std::make_unique<ImageProbePlugin>(registrar->messenger()));
  registrar->AddPlugin(std::make_unique<NotificationsPlugin>(registrar));
  registrar->AddPlugin(std::make_unique<UrlPlugin>(registrar->messenger()));
  registrar->AddPlugin(std::make_unique<VideoPlayerPlugin>(registrar));
  registrar->AddPlugin(std::make_unique<WindowPlugin>(registrar));
}

}  // namespace ux
