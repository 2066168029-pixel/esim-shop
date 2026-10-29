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

  # Required by CocoaPods even for local path pods: the spec must declare where
  # its source would live. Nobody downloads it, because the Podfile uses
  # `:path => 'Frameworks'`, so the xcframework is vendored in-repo. The URL is
  # only a formality, but it must be present and well-formed or `pod install`
  # aborts with "missing required attribute `source'".
  s.source           = { :http => 'https://www.linksfield.net/sdk/eSIMManagerSDK-1.5.3.zip' }

  # The vendored xcframework only ships the arm64 device slice. Excluding the
  # simulator architectures everywhere keeps SwiftPM/CocoaPods from failing to
  # resolve symbols when building for a simulator.
  s.pod_target_xcconfig = {
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'arm64 x86_64',
  }
  s.user_target_xcconfig = {
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'arm64 x86_64',
  }

  s.vendored_frameworks = 'eSIMManagerSDK.xcframework'

  # System frameworks the binary links against.
  s.frameworks = 'CoreBluetooth', 'SystemConfiguration', 'UIKit', 'AudioToolbox', 'CoreLocation'
end
