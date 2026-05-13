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
  # (Pathname.glob bails on both). The mirror runs on every
  # `pod install`; the destination is `.gitignore`'d.
  s.prepare_command  = 'rm -rf Classes/Camera-shared && cp -R ../darwin/Camera Classes/Camera-shared'
  s.source_files     = 'Classes/**/*.swift'
  s.frameworks       = ['AVFoundation', 'CoreMedia', 'CoreVideo', 'Photos', 'PhotosUI']
  s.dependency 'Flutter'
  s.ios.deployment_target = '13.0'
  s.swift_version = '5.0'
end
