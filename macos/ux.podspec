Pod::Spec.new do |s|
  s.name             = 'ux'
  s.version          = '0.6.0'
  s.summary          = 'UX Kit — Flutter plugin: file share/open via Quick Look.'
  s.homepage         = 'https://swipelab.co/ux.html'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Swipelab' => 'hello@swipelab.co' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.dependency 'FlutterMacOS'
  s.osx.deployment_target = '10.15'
  s.swift_version = '5.0'
end
