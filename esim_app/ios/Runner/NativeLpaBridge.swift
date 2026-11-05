//
//  NativeLpaBridge.swift
//  Runner
//
//  Bridges the Linksfield eSIMManagerSDK (binary xcframework) to Flutter.
//
//  Design notes
//  ------------
//  * The SDK is BLOCKING. Every LPAdClient.onXxx() call does BLE I/O on the
//    calling thread and returns a result code. We therefore run all SDK work on
//    a dedicated serial queue and reply to Flutter asynchronously.
//  * The SDK owns its own CBCentralManager in the reference demo, but reuses the
//    CBCentralManager we hand it. We keep one central for the whole app.
//  * Only arm64 device slice is shipped (no simulator slice) -> this bridge is
//    compiled out on x86_64/arm64-simulator via `#if canImport(eSIMManagerSDK)`.
//
//  Channel protocol (MethodChannel "app.esim/native_lpa")
//  -----------------------------------------------------
//    startScan            -> {}                      scan results stream on EventChannel
//    stopScan             -> {}
//    connect(deviceId)    -> {connected: bool}
//    disconnect           -> {}
//    getEid               -> {eid: String?}
//    getProfiles          -> {profiles: [{iccid, nickname, serviceProviderName,
//                                          profileName, state, policyRules}],
//                             eid: String?}
//    getEuiccInfo         -> {info: String?}
//    download(activationCode, confirmationCode) -> {result: Int, needConfirm: bool}
//    getMetadata(activationCode)               -> {result: Int, metadata: String?}
//    enable(iccid)        -> {result: Int}
//    disable(iccid)       -> {result: Int}
//    delete(iccid)        -> {result: Int}
//    eraseAll             -> {result: Int}
//    setNickname(iccid, nickname) -> {result: Int}
//    getDefaultSmdp       -> {address: String?}
//    setDefaultSmdp(address)      -> {result: Int}
//
//  EventChannel "app.esim/native_lpa/events"
//    {type: "scan",     id, name, rssi, mac}
//    {type: "connect",  state}     state: 0 disconnected,1 connecting,2 connected,3 fail
//    {type: "valid",    valid: bool}
//    {type: "notify",   operation, status, message, iccid}
//

import Foundation
import Flutter
import CoreBluetooth
import UIKit

#if canImport(eSIMManagerSDK)
import eSIMManagerSDK

final class NativeLpaBridge: NSObject {

  // MARK: - Flutter plumbing

  private let methodChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel
  private var eventSink: FlutterEventSink?

  /// Serial queue: the SDK is blocking and not reentrant.
  private let sdkQueue = DispatchQueue(label: "app.esim.native_lpa.sdk")
  /// MethodChannel replies must land on the platform thread.
  private let resultQueue = DispatchQueue.main

  // MARK: - BLE state

  private var central: CBCentralManager?
  private var centralReady = false
  private var centralWaiters: [() -> Void] = []

  /// deviceId (CBPeripheral.identifier.uuidString) -> peripheral
  private var discovered: [String: CBPeripheral] = [:]
  private var advertisedMac: [String: String] = [:]

  private var bleDevice: EuiccBleDevice?
  private var client: LPAdClient { LPAdClient.shared }
  /// 加密卡走 SecurityBleDevice。默认 true（覆盖面更广）；
  /// Dart 侧可通过 setSecureMode 切换，方便对比排查。
  private var preferSecure = false
  /// 正在等用户输入卡密码：看门狗暂停计时，否则用户输得慢会被误判超时。
  private var pskPrompting = false

  /// 卡密码（PSK）。SDK 在阻塞线程上问密码，弹不了框，只能回填已存的。
  private var cachedPsk: String {
    get { UserDefaults.standard.string(forKey: "app.esim.cardPsk") ?? "" }
    set { UserDefaults.standard.set(newValue, forKey: "app.esim.cardPsk") }
  }
  private var createdClient = false
  private var connectedPeripheral: CBPeripheral?

  // MARK: - Init

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: "app.esim/native_lpa", binaryMessenger: messenger)
    eventChannel = FlutterEventChannel(
      name: "app.esim/native_lpa/events", binaryMessenger: messenger)
    super.init()

    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    eventChannel.setStreamHandler(self)

    // SDK log switch (noisy by default).
    LFCommonUtil.setSDKLogEnable(enable: false)
    // 4-byte length prefix, matches current LPA firmware (see demo comment).
    eSIMManagerConfig.bleDataLengthSize = 4
  }

  /// GATT 常量，与 demo 的 EuiccGattAttributes 完全一致。
  /// 文档 3.2.6 要求显式设置；不设的话 SDK 用内置默认值，一旦固件换了
  /// UUID（或大小写不一致）特征就发现不到，设备会被判为 invalid。
  private static let euiccService = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
  private static let euiccRx = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
  private static let euiccTx = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

  // MARK: - Method dispatch

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]

    switch call.method {

    case "startScan":
      startScan(result: result)

    case "stopScan":
      central?.stopScan()
      result(nil)

    case "connect":
      guard let deviceId = args["deviceId"] as? String else {
        result(Self.error("missing_device_id")); return
      }
      connect(deviceId: deviceId, result: result)

    case "disconnect":
      disconnect()
      result(nil)

    case "getEid":
      runSdk(result: result) { [weak self] in
        guard let self, self.createdClient else { return ["eid": NSNull()] }
        return ["eid": self.client.onGetEid() ?? NSNull()]
      }

    case "getProfiles":
      runSdk(result: result) { [weak self] in
        guard let self, self.createdClient else { return Self.emptyProfiles() }
        let rsp = self.client.onGetEuiccProfileInfoList()
        var out: [[String: Any]] = []
        if rsp.result == 0 {
          for p in rsp.profiles.data {
            out.append([
              "iccid": p.iccid,
              "nickname": p.nickname,
              "serviceProviderName": p.serviceProviderName,
              "profileName": p.profileName,
              "state": Int(p.state),
              "policyRules": Int(p.policyRules),
            ])
          }
        }
        return [
          "result": Int(rsp.result),
          "eid": self.client.onGetEid() ?? NSNull(),
          "profiles": out,
        ]
      }

    case "getEuiccInfo":
      runSdk(result: result) { [weak self] in
        guard let self, self.createdClient else { return ["info": NSNull()] }
        return ["info": self.client.onGetEuiccInfo() ?? NSNull()]
      }

    case "download":
      let code = args["activationCode"] as? String ?? ""
      let confirm = args["confirmationCode"] as? String ?? ""
      runSdk(result: result) { [weak self] in
        guard let self, self.createdClient else {
          return ["result": -999, "needConfirm": false]
        }
        // -2 == RESULT_NEED_CONFIRMATION_CODE
        let r = self.client.onDownloadSubscription(
          activationCode: code, confirmationCode: confirm)
        return ["result": Int(r), "needConfirm": r == -2]
      }

    case "getMetadata":
      let code = args["activationCode"] as? String ?? ""
      runSdk(result: result) { [weak self] in
        guard let self, self.createdClient else {
          return ["result": -999, "metadata": NSNull()]
        }
        let r = self.client.onGetDownloadableSubscriptionMetadata(activationCode: code)
        return ["result": Int(r.resultCode), "metadata": r.metadata]
      }

    case "enable":
      let iccid = args["iccid"] as? String ?? ""
      runSdk(result: result) { [weak self] in
        guard let self, self.createdClient else { return ["result": -999] }
        return ["result": Int(self.client.onSwitchToSubscription(iccid: iccid))]
      }

    case "disable":
      let iccid = args["iccid"] as? String ?? ""
      runSdk(result: result) { [weak self] in
        guard let self, self.createdClient else { return ["result": -999] }
        return ["result": Int(self.client.onDisableSubscription(iccid: iccid))]
      }

    case "delete":
      let iccid = args["iccid"] as? String ?? ""
      runSdk(result: result) { [weak self] in
        guard let self, self.createdClient else { return ["result": -999] }
        return ["result": Int(self.client.onDeleteSubscription(iccid: iccid))]
      }

    case "eraseAll":
      runSdk(result: result) { [weak self] in
        guard let self, self.createdClient else { return ["result": -999] }
        return ["result": Int(self.client.onEraseSubscriptions())]
      }

    case "setNickname":
      let iccid = args["iccid"] as? String ?? ""
      let nick = args["nickname"] as? String ?? ""
      runSdk(result: result) { [weak self] in
        guard let self, self.createdClient else { return ["result": -999] }
        return ["result": Int(self.client.onUpdateSubscriptionNickname(
          iccid: iccid, nickname: nick))]
      }

    case "setSecureMode":
      // args: {secure: bool}  默认 true
      let secure = args["secure"] as? Bool ?? true
      preferSecure = secure
      let modeStr = secure ? "on" : "off"
      log("secure mode = \(modeStr)")
      result(nil)

    case "setCardPassword":
      // args: {password: String}  空串表示清除
      let pwd = args["password"] as? String ?? ""
      cachedPsk = pwd
      let pwdState = pwd.isEmpty ? "cleared" : "set"
      log("card password \(pwdState)")
      result(nil)

    case "hasCardPassword":
      result(["has": !cachedPsk.isEmpty])

    case "getDefaultSmdp":
      runSdk(result: result) { [weak self] in
        guard let self, self.createdClient else { return ["address": NSNull()] }
        return ["address": self.client.getDefaultSmdpAddress() ?? NSNull()]
      }

    case "setDefaultSmdp":
      let addr = args["address"] as? String ?? ""
      runSdk(result: result) { [weak self] in
        guard let self, self.createdClient else { return ["result": -999] }
        return ["result": Int(self.client.setDefaultSmdpAddress(address: addr))]
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Scanning

  private func startScan(result: @escaping FlutterResult) {
    withCentral { [weak self] central in
      guard let self else { return }
      self.discovered.removeAll()
      self.advertisedMac.removeAll()
      central.scanForPeripherals(withServices: nil, options: nil)
      self.resultQueue.async { result(nil) }
    }
  }

  private func withCentral(_ body: @escaping (CBCentralManager) -> Void) {
    sdkQueue.async { [weak self] in
      guard let self else { return }
      if let c = self.central, self.centralReady {
        body(c); return
      }
      self.centralWaiters.append { [weak self] in
        guard let self, let c = self.central else { return }
        body(c)
      }
      if self.central == nil {
        // Delegate callbacks arrive on this same queue (queue: nil => main by
        // default, so pass sdkQueue explicitly to stay off the main thread).
        self.central = CBCentralManager(
          delegate: self, queue: self.sdkQueue,
          options: [CBCentralManagerOptionShowPowerAlertKey: false])
      }
    }
  }

  // MARK: - Connect

  private func connect(deviceId: String, result: @escaping FlutterResult) {
    sdkQueue.async { [weak self] in
      guard let self else { return }
      guard let peripheral = self.discovered[deviceId] else {
        self.reply(result, Self.error("device_not_found")); return
      }
      guard let central = self.central else {
        self.reply(result, Self.error("bluetooth_unavailable")); return
      }

      self.teardownConnectionSync()

      // 文档 3.2.6：显式设置 GATT UUID，不依赖 SDK 默认值。
      let probe = EuiccBleDevice(
        bleManager: central,
        blePeripheral: peripheral,
        bleDataLengthSize: 4)
      probe.setEuiccBleServiceUUID(
        serviceUUID: Self.euiccService,
        rxUUID: Self.euiccRx,
        txUUID: Self.euiccTx)

      let identity = peripheral.identifier.uuidString
      let device: EuiccBleDevice
      if self.preferSecure {
        let secure = SecurityBleDevice(
          identity: identity,
          bleManager: central,
          blePeripheral: peripheral,
          bleDataLengthSize: 4)
        secure.setEuiccBleServiceUUID(
          serviceUUID: Self.euiccService,
          rxUUID: Self.euiccRx,
          txUUID: Self.euiccTx)
        device = secure
        log("mode: SecurityBleDevice (secure)")
      } else {
        device = probe
        log("mode: plain EuiccBleDevice")
      }

      self.bleDevice = device
      self.connectedPeripheral = peripheral

      var replied = false
      let done: (Bool) -> Void = { [weak self] ok in
        guard let self, !replied else { return }
        replied = true
        self.reply(result, ["connected": ok])
      }

      // 看门狗：只在"长时间无任何进度"时才判失败。
      // 任何回调（连接状态、设备有效性）都会刷新 lastProgress，
      // 弹密码框期间暂停计时，避免用户输入慢导致误判。
      let start = DispatchTime.now()
      var lastProgress = start
      self.pskPrompting = false
      let waiting = DispatchSemaphore(value: 0)

      let progress: () -> Void = {
        lastProgress = DispatchTime.now()
      }

      DispatchQueue.global().async {
        while true {
          Thread.sleep(forTimeInterval: 0.5)
          if replied { return }
          // 正在等用户输密码：暂停判断
          if self.pskPrompting { lastProgress = DispatchTime.now(); continue }
          let elapsed = DispatchTime.now().uptimeNanoseconds &- lastProgress.uptimeNanoseconds
          if elapsed > 20_000_000_000 {   // 20s 无进度
            log("watchdog: no progress for 20s -> fail")
            done(false)
            return
          }
        }
      }
      _ = start
      _ = waiting

      device.connectStateCallback = { [weak self] state in
        guard let self else { return }
        progress()
        self.emit(["type": "connect", "state": state.rawValue])
        log("connect state -> \(state.rawValue)")
        if state == .STATE_CONNECTFAIL {
          log("connect FAILED (stack reported failure)")
          done(false)
        } else if state == .STATE_DISCONNECTED {
          log("disconnected before ready")
          done(false)
        }
        // STATE_CONNECTED only means the GATT link is up. Service discovery,
        // CCCD subscription and MTU negotiation are still in flight, so we must
        // NOT read device info here. isValidDeviceCallback fires once the SDK
        // has finished all of that and the card actually answers.
      }

      device.isValidDeviceCallback = { [weak self] valid in
        guard let self else { return }
        progress()
        self.emit(["type": "valid", "valid": valid])
        let validStr = valid ? "true" : "false"
        log("isValidDevice -> \(validStr)")
        if valid {
          self.sdkQueue.async { self.primeClient(done: done) }
        } else {
          // The SDK will also report CONNECTFAIL; keep the timeout as backstop.
          log("device reported invalid")
        }
      }

      device.reopen()

      log("reopen() called, waiting for state callback...")
    }
  }

  /// After BLE connect: read device info, then create the LPAd client.
  ///
  /// getDeviceInfo() is a blocking request that can still come back empty on
  /// the first try right after service discovery, so retry a couple of times
  /// with a short backoff before giving up.
  private func primeClient(done: @escaping (Bool) -> Void, attempt: Int = 1) {
    guard let device = bleDevice else {
      log("primeClient: no bleDevice")
      done(false)
      return
    }

    // Demo 的做法：密码回调必须在 getDeviceInfo() 之前注册。
    // SDK 在它自己的线程上阻塞等待输入，主线程弹框后用 DispatchGroup 桥接回去。
    LPAdClient.setUserAuthenticationCallback { [weak self] () -> String? in
      guard let self else { return nil }
      // 上次用过的密码优先，避免每次都问
      if !self.cachedPsk.isEmpty {
        log("PSK: replying cached value")
        return self.cachedPsk
      }
      log("PSK: prompting on main thread")
      return self.promptForPasswordBlocking()
    }

    log("getDeviceInfo attempt \(attempt)")
    let info = device.getDeviceInfo()

    guard let info else {
      log("getDeviceInfo returned nil (attempt \(attempt))")
      if attempt < 3 {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [weak self] in
          self?.sdkQueue.async { self?.primeClient(done: done, attempt: attempt + 1) }
        }
      } else {
        emit(["type": "valid", "valid": false])
        done(false)
      }
      return
    }

    log("deviceInfo imei='\(info.imei)' vendor='\(info.vendor)' sn='\(info.sn)'")

    let imei = info.imei
    guard !imei.isEmpty else {
      log("empty imei on attempt \(attempt)")
      if attempt < 3 {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [weak self] in
          self?.sdkQueue.async { self?.primeClient(done: done, attempt: attempt + 1) }
        }
      } else {
        // Don't tear the link down here: the card may be read-only-ish but the
        // user can still see profiles. Report failure instead of dropping it.
        done(false)
      }
      return
    }

    let identity = connectedPeripheral?.identifier.uuidString ?? ""
    client.createClient(
      imei: imei,
      nativeIdentity: identity,
      info: info,
      pbDevice: device)
    createdClient = true
    emit([
      "type": "deviceInfo",
      "vendor": info.vendor,
      "imei": info.imei,
      "sn": info.sn,
      "deviceName": info.deviceName,
    ])
    done(true)
  }

  /// 主线程弹密码框，阻塞当前（SDK）线程直到用户输入或超时。
  ///
  /// 与 demo 的 inputSecurityPassword 等价：SDK 在它自己的队列上同步等待，
  /// 这里用 DispatchGroup 把结果桥接回来。60 秒不输入就放弃，避免
  /// sdkQueue 被永久占住（后续所有 SDK 调用都会排队）。
  private func promptForPasswordBlocking() -> String? {
    pskPrompting = true
    defer { pskPrompting = false }
    let group = DispatchGroup()
    group.enter()
    var result: String?

    DispatchQueue.main.async { [weak self] in
      guard self != nil else { group.leave(); return }
      let alert = UIAlertController(
        title: "输入加密密码",
        message: "这张卡需要密码才能建立安全通道，密码通常印在卡上。",
        preferredStyle: .alert)
      alert.addTextField { tf in
        tf.placeholder = "Password"
        tf.autocorrectionType = .no
        tf.autocapitalizationType = .none
      }
      alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
        log("PSK: user cancelled")
        group.leave()
      })
      alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
        let v = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        log("PSK: user entered \(v.count) chars")
        result = v.isEmpty ? nil : v
        group.leave()
      })

      // 找到最顶层 VC 来 present
      guard let root = UIApplication.shared.connectedScenes
              .compactMap({ $0 as? UIWindowScene })
              .flatMap({ $0.windows })
              .first(where: { $0.isKeyWindow })?.rootViewController else {
        group.leave()
        return
      }
      var top = root
      while let p = top.presentedViewController { top = p }
      top.present(alert, animated: true)
    }

    // 60 秒兜底：用户一直不理会就放弃，别把 SDK 队列卡死
    let timeout = DispatchTime.now() + 60
    if group.wait(timeout: timeout) == .timedOut {
      log("PSK: prompt timed out after 60s")
      return nil
    }
    // 记住这次输入，下次直接复用
    if let r = result, !r.isEmpty {
      cachedPsk = r
    }
    return result
  }

  private func teardownConnectionSync() {
    if createdClient {
      client.closeNativeClient()
      createdClient = false
    }
    bleDevice?.close()
    bleDevice = nil
    connectedPeripheral = nil
  }

  private func disconnect() {
    sdkQueue.async { [weak self] in
      self?.teardownConnectionSync()
      self?.emit(["type": "connect", "state": DeviceConnectionState.STATE_DISCONNECTED.rawValue])
    }
  }

  // MARK: - Helpers

  /// Runs a blocking SDK call off the main thread and replies on main.
  private func runSdk(result: @escaping FlutterResult,
                      _ body: @escaping () -> [String: Any]) {
    sdkQueue.async { [weak self] in
      guard let self else { return }
      let payload = body()
      self.reply(result, payload)
    }
  }

  private func reply(_ result: @escaping FlutterResult, _ value: Any?) {
    resultQueue.async { result(value) }
  }

  /// 统一日志：既打 NSLog（Xcode 可见），也通过 EventChannel 发给 Dart，
  /// 这样 App 内能直接看到进度，不需要连 Mac。
  private func log(_ msg: String) {
    NSLog("[NativeLpa] %@", msg)
    emit(["type": "log", "message": msg])
  }

  private func emit(_ event: [String: Any]) {
    resultQueue.async { [weak self] in
      self?.eventSink?(event)
    }
  }

  private static func error(_ code: String) -> FlutterError {
    FlutterError(code: code, message: code, details: nil)
  }

  private static func emptyProfiles() -> [String: Any] {
    ["result": -999, "eid": NSNull(), "profiles": [[String: Any]]()]
  }
}

// MARK: - CBCentralManagerDelegate

extension NativeLpaBridge: CBCentralManagerDelegate {

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    let ready = central.state == .poweredOn
    centralReady = ready
    emit(["type": "bluetoothState", "state": central.state.rawValue, "ready": ready])
    if ready {
      let waiters = centralWaiters
      centralWaiters.removeAll()
      waiters.forEach { $0() }
    } else {
      centralWaiters.removeAll()
    }
  }

  func centralManager(_ central: CBCentralManager,
                      didDiscover peripheral: CBPeripheral,
                      advertisementData: [String: Any],
                      rssi RSSI: NSNumber) {
    // Accept only Linksfield-capable peripherals, same rule as the demo.
    guard LFCommonUtil.isHaveLFBleService(advertisementData: advertisementData) else {
      return
    }
    let id = peripheral.identifier.uuidString
    let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? id
    let mac = LFCommonUtil.getBleDeviceMacAdress(advertisementData: advertisementData) ?? ""

    let isNew = discovered[id] == nil
    discovered[id] = peripheral
    advertisedMac[id] = mac

    if isNew {
      emit([
        "type": "scan",
        "id": id,
        "name": name,
        "rssi": RSSI.intValue,
        "mac": mac,
      ])
    }
  }
}

// MARK: - FlutterStreamHandler

extension NativeLpaBridge: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?,
                eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}

#endif  // canImport(eSIMManagerSDK)
