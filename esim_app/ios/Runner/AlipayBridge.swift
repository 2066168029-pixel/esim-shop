// 支付宝 iOS 桥接
//
// 为什么自己写而不是用 alipay_kit：
//   项目已经有一个 Swift 的 MethodChannel 桥（NativeLpaBridge），
//   沿用同一套结构，不额外引依赖，也不用改 Podfile 之外的东西。
//
// 关键点：
//   1. 支付宝的 SDK 需要 URL Scheme 才能跳回来 —— 在 Info.plist 里配
//   2. 回调走 AppDelegate 的 open url，这里提供一个静态方法让 AppDelegate 转
//
// 没有链接 AlipaySDK 时（比如还没装 Pod）这个文件会走 #if 分支，
// 编译不会失败，Dart 侧收到 MissingPluginException 会退化成「只查状态」。
import Flutter
import UIKit

#if canImport(AlipaySDK)
import AlipaySDK
#endif

final class AlipayBridge: NSObject {
  private let channel: FlutterMethodChannel
  private var pendingResult: FlutterResult?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "onlylink/alipay", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "pay":
        let args = call.arguments as? [String: Any]
        let orderString = (args?["orderString"] as? String) ?? ""
        self.pay(orderString: orderString, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func pay(orderString: String, result: @escaping FlutterResult) {
    guard !orderString.isEmpty else {
      result(FlutterError(code: "EMPTY", message: "orderString 为空", details: nil))
      return
    }

    #if canImport(AlipaySDK)
    guard let scheme = AlipayBridge.appScheme else {
      result(FlutterError(
        code: "NO_SCHEME",
        message: "Info.plist 里没有配置 CFBundleURLSchemes，支付宝无法回到 App",
        details: nil))
      return
    }

    // 同一次只能有一笔在飞；重复调用直接拒绝，避免把结果回调搞混
    if pendingResult != nil {
      result(FlutterError(code: "BUSY", message: "上一笔支付还没结束", details: nil))
      return
    }
    pendingResult = result

    AlipaySDK.defaultService().payOrder(
      orderString, fromScheme: scheme, callback: { [weak self] res in
        self?.finish(res)
      })
    #else
    result(FlutterError(
      code: "NO_SDK",
      message: "未链接 AlipaySDK，请在 Podfile 加入 pod 'AlipaySDK-iOS'",
      details: nil))
    #endif
  }

  /// 把支付宝返回的结果交回上一次 pay 调用的 Future。
  @discardableResult
  func finish(_ resultInfo: [AnyHashable: Any]?) -> Bool {
    guard let pending = pendingResult else { return false }
    pendingResult = nil
    guard let info = resultInfo else {
      pending(nil)
      return true
    }
    // memo / result 两种形态都有；取能拿到的那个
    let memo = info["memo"] as? [String: Any]
    let resultDict = info["result"] as? [String: Any] ?? memo
    let status = (resultDict?["resultStatus"] as? String)
      ?? (resultDict?["ResultStatus"] as? String)
      ?? ""
    pending(status)
    return true
  }

  /// 由 AppDelegate 在 open url 时调用。返回 true 表示这条 URL 是支付宝的。
  static func handleOpenURL(_ url: URL) -> Bool {
    let isAlipayScheme = (url.scheme ?? "").lowercased().hasPrefix("alipay")
    let isSafepay = (url.host ?? "").lowercased() == "safepay"
    guard isAlipayScheme || isSafepay else { return false }

    #if canImport(AlipaySDK)
    AlipaySDK.defaultService().processOrder(withPaymentResult: url) { res in
      AlipayBridge.shared?.finish(res)
    }
    return true
    #else
    return false
    #endif
  }

  /// AppDelegate 拿不到实例，用一个弱引用登记当前活跃的桥
  private(set) static weak var shared: AlipayBridge?

  /// Info.plist 里第一个自定义 scheme —— 支付宝付完用它跳回来
  static var appScheme: String? {
    guard let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else {
      return nil
    }
    for t in types {
      guard let schemes = t["CFBundleURLSchemes"] as? [String] else { continue }
      if let s = schemes.first, !s.hasPrefix("alipay") {
        return s
      }
    }
    return nil
  }

  func registerAsShared() { AlipayBridge.shared = self }
}
