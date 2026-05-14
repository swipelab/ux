Pod::Spec.new do |s|
  s.name             = 'ux'
  s.version          = '0.9.0'
  s.summary          = 'UX Kit — Flutter plugin: keyboard, sensor, file, QR scanner, and camera.'
  s.homepage         = 'https://swipelab.co/ux.html'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Swipelab' => 'hello@swipelab.co' }
  s.source           = { :path => '.' }
  # `Classes/Camera-shared/` mirrors the shared `darwin/Camera/`
  # Swift files. `prepare_command` runs only on `pod install`, so
  # mid-iteration edits to darwin/Camera/*.swift wouldn't reach the
  # built binary until pods were re-installed. Run the mirror as a
  # build script phase too (before compile) so the latest source is
  # always picked up. The two are belt-and-suspenders — pod install
  # primes the file set so CocoaPods globs it; the build phase keeps
  # contents fresh on every subsequent Swift change.
  s.prepare_command  = 'rm -rf Classes/Camera-shared && cp -R ../darwin/Camera Classes/Camera-shared'
  s.script_phases    = [{
    :name             => 'Mirror darwin/Camera',
    :execution_position => :before_compile,
    :script           => <<-CMD
set -e
SRC="${PODS_TARGET_SRCROOT}/../darwin/Camera"
DEST="${PODS_TARGET_SRCROOT}/Classes/Camera-shared"
[ -d "$SRC" ] || exit 0
mkdir -p "$DEST"
rsync -a --delete "$SRC/" "$DEST/"
CMD
  }]
  s.source_files     = 'Classes/**/*.{swift,m}'
  s.frameworks       = ['AVFoundation', 'CoreMedia', 'CoreVideo']
  s.dependency 'FlutterMacOS'
  s.osx.deployment_target = '10.15'
  s.swift_version = '5.0'
end
