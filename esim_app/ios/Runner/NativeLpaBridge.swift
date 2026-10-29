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

      let device = EuiccBleDevice(
        bleManager: central,
        blePeripheral: peripheral,
        bleDataLengthSize: 4)
      self.bleDevice = device
      self.connectedPeripheral = peripheral

      var replied = false
      let done: (Bool) -> Void = { [weak self] ok in
        guard let self, !replied else { return }
        replied = true
        self.reply(result, ["connected": ok])
      }

      device.connectStateCallback = { [weak self] state in
        guard let self else { return }
        self.emit(["type": "connect", "state": state.rawValue])
        if state == .STATE_CONNECTED {
          // Give the stack a moment to finish service discovery before
          // asking for device info, mirroring the demo's flow.
          self.sdkQueue.asyncAfter(deadline: .now() + 0.3) {
            self.primeClient(done: done)
          }
        } else if state == .STATE_CONNECTFAIL {
          done(false)
        } else if state == .STATE_DISCONNECTED {
          done(false)
        }
      }

      device.isValidDeviceCallback = { [weak self] valid in
        self?.emit(["type": "valid", "valid": valid])
      }

      device.reopen()

      // Safety net: don't hang Flutter forever if the callback never fires.
      self.sdkQueue.asyncAfter(deadline: .now() + 25) { done(false) }
    }
  }

  /// After BLE connect: read device info, then create the LPAd client.
  private func primeClient(done: @escaping (Bool) -> Void) {
    guard let device = bleDevice else { done(false); return }

    let info = device.getDeviceInfo()
    guard let info else {
      emit(["type": "valid", "valid": false])
      done(false)
      return
    }
    let imei = info.imei
    guard !imei.isEmpty else {
      device.close()
      done(false)
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
