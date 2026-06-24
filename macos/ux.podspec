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
  s.prepare_command  = <<-CMD
rm -rf Classes/Camera-shared && cp -R ../darwin/Camera Classes/Camera-shared
rm -rf Classes/Video-shared  && cp -R ../darwin/Video  Classes/Video-shared
CMD
  s.script_phases    = [{
    :name             => 'Mirror darwin/{Camera,Video}',
    :execution_position => :before_compile,
    # We want this to run every build (the comment above explains why),
    # so opt out of Xcode's dependency analysis instead of trying to
    # enumerate inputs/outputs. Silences the "will be run during every
    # build" warning without changing semantics.
    :always_out_of_date => '1',
    :script           => <<-CMD
set -e
for MOD in Camera Video; do
  SRC="${PODS_TARGET_SRCROOT}/../darwin/${MOD}"
  DEST="${PODS_TARGET_SRCROOT}/Classes/${MOD}-shared"
  [ -d "$SRC" ] || continue
  mkdir -p "$DEST"
  rsync -a --delete "$SRC/" "$DEST/"
done
CMD
  }]
  s.source_files     = 'Classes/**/*.{swift,m}'
  s.frameworks       = ['AVFoundation', 'CoreMedia', 'CoreVideo']
  s.dependency 'FlutterMacOS'
  # Folder drag-drop zips a dropped directory for upload with progress +
  # cancellation (DropPlugin.zipForUpload); ZIPFoundation's
  # `FileManager.zipItem(progress:)` is the only piece needing a third-party pod.
  s.dependency 'ZIPFoundation'
  s.osx.deployment_target = '10.15'
  s.swift_version = '5.0'
end
