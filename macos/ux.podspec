Pod::Spec.new do |s|
  s.name             = 'ux'
  s.version          = '0.9.0'
  s.summary          = 'UX Kit — Flutter plugin: keyboard, sensor, file, QR scanner, and camera.'
  s.homepage         = 'https://swipelab.co/ux.html'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Swipelab' => 'hello@swipelab.co' }
  s.source           = { :path => '.' }
  # See the matching note in `ios/ux.podspec` — mirror the shared
  # `darwin/Camera/` Swift files into a local `Classes/Camera-shared/`
  # at install time so CocoaPods picks them up via the normal glob.
  s.prepare_command  = 'rm -rf Classes/Camera-shared && cp -R ../darwin/Camera Classes/Camera-shared'
  s.source_files     = 'Classes/**/*.swift'
  s.frameworks       = ['AVFoundation', 'CoreMedia', 'CoreVideo']
  s.dependency 'FlutterMacOS'
  s.osx.deployment_target = '10.15'
  s.swift_version = '5.0'
end
