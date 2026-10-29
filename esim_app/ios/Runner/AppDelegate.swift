import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Strong reference: the bridge owns the MethodChannel handler.
  private var nativeLpaBridge: AnyObject?

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
  }
}
