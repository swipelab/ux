Pod::Spec.new do |s|
  s.name             = 'ux'
  s.version          = '0.2.0'
  s.summary          = 'UX Kit – Flutter plugin with keyboard tracking and interactive dismiss.'
  s.homepage         = 'https://swipelab.co/ux.html'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Swipelab' => 'hello@swipelab.co' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.dependency 'Flutter'
  s.ios.deployment_target = '13.0'
  s.swift_version = '5.0'
end
