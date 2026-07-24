Pod::Spec.new do |s|
  s.name             = 'ux'
  s.version          = '0.9.0'
  s.summary          = 'UX Kit — Flutter plugin: keyboard, sensor, file, QR scanner, and camera.'
  s.homepage         = 'https://swipelab.co/ux.html'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Swipelab' => 'hello@swipelab.co' }
  s.source           = { :path => '.' }
  # Mirror the shared `darwin/Camera/` Swift files into a local
  # `Classes/Camera-shared/` so CocoaPods picks them up via the
  # normal glob — neither symlinks nor `../` escapes work
  # (Pathname.glob bails on both).
  #
  # `prepare_command` only runs on `pod install`. Swift edits in
  # `darwin/Camera/` between installs would never reach the built
  # binary — the mirror would be stale. The build script phase
  # below re-runs the mirror before each compile to keep contents
  # fresh.
  s.prepare_command  = <<-CMD
rm -rf Classes/Camera-shared && cp -R ../darwin/Camera Classes/Camera-shared
rm -rf Classes/Video-shared  && cp -R ../darwin/Video  Classes/Video-shared
rm -rf Classes/File-shared   && cp -R ../darwin/File   Classes/File-shared
CMD
  s.script_phases    = [{
    :name             => 'Mirror darwin/{Camera,Video,File}',
    :execution_position => :before_compile,
    :script           => <<-CMD
set -e
for MOD in Camera Video File; do
  SRC="${PODS_TARGET_SRCROOT}/../darwin/${MOD}"
  DEST="${PODS_TARGET_SRCROOT}/Classes/${MOD}-shared"
  [ -d "$SRC" ] || continue
  mkdir -p "$DEST"
  rsync -a --delete "$SRC/" "$DEST/"
done
CMD
  }]
  s.source_files     = 'Classes/**/*.{swift,m}'
  s.frameworks       = ['AVFoundation', 'CoreMedia', 'CoreVideo', 'Photos', 'PhotosUI']
  s.dependency 'Flutter'
  s.ios.deployment_target = '13.0'
  s.swift_version = '5.0'
end
