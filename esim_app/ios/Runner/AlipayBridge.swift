// 支付宝 iOS 桥接 —— AlipaySDK.framework 15.8.42
//
// 与 Android 侧 AlipayChannel 返回同样的结构，Dart 只写一套解析：
//   {resultStatus, result, memo, success, cancelled, pending}
//
// 关键点：
//   1. 必须配 URL Scheme（Info.plist CFBundleURLTypes），支付宝付完才能跳回来
//   2. 回调走 AppDelegate 的 open url -> AlipayBridge.handleOpenURL
//   3. 返回的 9000 **不代表到账**，到账以服务端异步通知为准
//
// 没链接 AlipaySDK 时（framework 未加进工程）编译不报错，返回 NO_SDK，
// Dart 侧会降级到 H5。

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
        // 兼容两个键名：新版 Dart 传 orderInfo，旧版传 orderString
        let orderInfo = (args?["orderInfo"] as? String)
          ?? (args?["orderString"] as? String)
          ?? ""
        self.pay(orderInfo: orderInfo, result: result)
      case "isInstalled":
        result(AlipayBridge.isAlipayInstalled())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  static func isAlipayInstalled() -> Bool {
    guard let url = URL(string: "alipays://") else { return false }
    return UIApplication.shared.canOpenURL(url)
  }

  private func pay(orderInfo: String, result: @escaping FlutterResult) {
    guard !orderInfo.isEmpty else {
      result(FlutterError(code: "EMPTY", message: "orderInfo 为空", details: nil))
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

    // 同一时刻只允许一笔在飞；重复调用直接拒绝，避免结果回调串台
    if pendingResult != nil {
      result(FlutterError(code: "BUSY", message: "上一笔支付还没结束", details: nil))
      return
    }
    pendingResult = result

    AlipaySDK.defaultService().payOrder(
      orderInfo, fromScheme: scheme, callback: { [weak self] res in
        self?.finish(res)
      })
    #else
    result(FlutterError(
      code: "NO_SDK",
      message: "未链接 AlipaySDK：请把 AlipaySDK.framework 加进 Runner target",
      details: nil))
    #endif
  }

  /// 把支付宝返回的结果交回上一次 pay 调用的 Future。
  @discardableResult
  func finish(_ resultInfo: [AnyHashable: Any]?) -> Bool {
    guard let pending = pendingResult else { return false }
    pendingResult = nil

    guard let info = resultInfo else {
      pending([
        "resultStatus": "error",
        "result": "",
        "memo": "支付没有返回结果",
        "success": false,
        "cancelled": false,
        "pending": false,
      ])
      return true
    }

    // SDK 给的字典形状随版本变化：有时在 memo 里，有时在 result 里，
    // 值是 JSON 字符串也可能是 Dictionary。逐层剥，最后兜底整体转字符串。
    var status = ""
    var memoText = ""
    var resultText = ""

    func pick(_ obj: Any?) {
      guard let obj else { return }
      if let d = obj as? [String: Any] {
        if status.isEmpty {
          status = (d["resultStatus"] as? String)
            ?? (d["ResultStatus"] as? String)
            ?? ""
        }
        if memoText.isEmpty, let m = d["memo"] as? String, m != "[do not call]" {
          memoText = m
        }
        if resultText.isEmpty, let r = d["result"] as? String {
          resultText = r
        }
        // result 里可能还嵌一层
        if let inner = d["result"] as? [String: Any] {
          pick(inner)
        } else if let s = d["result"] as? String,
                  let data = s.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: data) {
          pick(j)
        }
      } else if let s = obj as? String, status.isEmpty {
        // 有的版本直接给 JSON 字符串
        if let data = s.data(using: .utf8),
           let j = try? JSONSerialization.jsonObject(with: data) {
          pick(j)
        }
      }
    }

    pick(info["result"])
    pick(info["memo"])
    pick(info)

    if status.isEmpty {
      status = (info["resultStatus"] as? String) ?? "error"
    }

    pending([
      "resultStatus": status,
      "result": resultText,
      "memo": memoText,
      "success": status == "9000",
      "cancelled": status == "6001",
      "pending": status == "8000",
    ])
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

  func registerAsShared() {
    AlipayBridge.shared = self
    #if canImport(AlipaySDK)
    // Xcode 26 之后需要业务自己指定 window，否则收银台可能弹不出来
    if let window = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .flatMap({ $0.windows })
      .first(where: { $0.isKeyWindow }) {
      AlipaySDK.defaultService().targetWindow = window
    }
    #endif
  }
}
