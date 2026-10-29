Pod::Spec.new do |s|
  s.name             = 'eSIMManagerSDK'
  s.version          = '1.5.3'
  s.summary          = 'Linksfield eSIM Manager SDK (closed-source binary xcframework).'
  s.description      = <<-DESC
Vendored binary distribution of the Linksfield eSIMManagerSDK.
The upstream xcframework contains an arm64 iOS device slice only, so it cannot
be used from the x86_64 or arm64 simulator.
  DESC
  s.homepage         = 'https://www.linksfield.net'
  s.license          = { :type => 'Commercial', :text => 'Proprietary. Do not redistribute.' }
  s.author           = { 'Linksfield' => 'support@linksfield.net' }
  s.platform         = :ios, '15.0'
  s.requires_arc     = true

  # Only the arm64 device slice exists in the vendored xcframework.
  s.pod_target_xcconfig = {
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'arm64 x86_64',
  }
  s.user_target_xcconfig = {
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'arm64 x86_64',
  }

  s.vendored_frameworks = 'eSIMManagerSDK.xcframework'

  # The SDK links these system frameworks.
  s.frameworks = 'CoreBluetooth', 'SystemConfiguration', 'UIKit', 'AudioToolbox', 'CoreLocation'
end
