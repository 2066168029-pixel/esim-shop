Pod::Spec.new do |s|
  s.name             = 'AlipaySDK'
  s.version          = '15.8.42'
  s.summary          = 'Alipay App-pay SDK (vendored binary framework).'
  s.description      = <<-DESC
Vendored copy of AlipaySDK.framework 15.8.42, shipped by the Alipay open
platform. The CocoaPods trunk only carries up to 15.8.30, while the official
download is 15.8.42, so the framework lives in-repo and is referenced by path.

Only the device slice matters here: CI builds for generic/platform=iOS.
  DESC
  s.homepage         = 'https://opendocs.alipay.com/open/54/104509'
  s.license          = { :type => 'Commercial', :text => 'Proprietary. Alipay (Ant Group). Do not redistribute.' }
  s.author           = { 'Ant Group' => 'https://open.alipay.com' }
  s.platform         = :ios, '15.0'
  s.requires_arc     = true

  # Required attribute even for a :path pod. Nothing downloads it.
  s.source           = { :http => 'https://opendocs.alipay.com/open/54/104509' }

  s.vendored_frameworks = 'AlipaySDK.framework'
  s.resources           = 'AlipaySDK.bundle'

  # The framework ships device arm64 only; keep simulator builds from trying
  # to link against it.
  s.pod_target_xcconfig = {
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'arm64 x86_64',
  }
  s.user_target_xcconfig = {
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'arm64 x86_64',
  }

  s.frameworks = 'UIKit', 'CFNetwork', 'SystemConfiguration', 'CoreTelephony',
                 'QuartzCore', 'CoreText', 'CoreGraphics', 'CoreMotion',
                 'WebKit', 'Foundation'

  s.libraries = 'c++', 'z'
end
