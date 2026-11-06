import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Strong reference: the bridge owns the MethodChannel handler.
  private var nativeLpaBridge: AnyObject?
  /// 支付宝桥；持有强引用，MethodChannel 靠它处理回调。
  private var alipayBridge: AlipayBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Native LPA bridge (Linksfield eSIMManagerSDK).
    // The xcframework ships an arm64-device slice only, so the bridge compiles
    // out on simulator builds -- Dart must treat a missing channel as
    // "native SDK unavailable" and fall back to the pure-Dart transport.
    #if canImport(eSIMManagerSDK)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NativeLpaBridge") {
      nativeLpaBridge = NativeLpaBridge(messenger: registrar.messenger())
    }
    #endif

    // 支付宝：付款完成后由系统把 App 拉回前台，open url 在这里接住。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AlipayBridge") {
      let bridge = AlipayBridge(messenger: registrar.messenger())
      bridge.registerAsShared()
      alipayBridge = bridge
    }
  }

  /// 支付宝付完会用自己的 scheme 跳回来，必须在这里接住并把结果交还 SDK。
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if AlipayBridge.handleOpenURL(url) {
      return true
    }
    return super.application(app, open: url, options: options)
  }
  // iOS 13+ 走 SceneDelegate，openURL 可能落到那里；这里再兜一层。
  override func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    if let url = userActivity.webpageURL, AlipayBridge.handleOpenURL(url) {
      return true
    }
    return super.application(application, continue: userActivity, restorationHandler: restorationHandler)
  }
}
