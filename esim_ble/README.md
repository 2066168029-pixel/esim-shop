# esim_ble — 蓝牙 eSIM 写卡库

从 `eSIM_Manager_2.5.2.apk` 反编译的 Linksfield LPAd 协议重建的 Flutter 实现。

## 状态

`flutter analyze` 零问题，`flutter test` **27/27 通过**。真机未验证。

## 协议依据

| 项 | 来源 |
|---|---|
| BLE 服务 UUID | `EuiccGattAttributes.java` — NUS `6e400001/2/3` |
| 报文格式 | `com.linksfield.lpad.grpc.*` 的 generated protobuf |
| 加密可选 | `k3.a()` — `!secure && cmd != 3` 走明文 |
| APDU 分片 | lpac `euicc.c:es10x_command_iter` — P1=0x11/0x91, P2=序号, MSS=120 |
| ES9+ 端点 | lpac `euicc/es9p.c` |

## 结构

```
lib/
  esim_ble.dart              导出
  src/
    proto_codec.dart         手写 protobuf 编解码（无 codegen）
    messages.dart            EuiccDeviceReq/Rsp, SmartCardReq/Rsp, TransmitApdu
    ble_transport.dart       NUS 扫描/连接/MTU 分片/组帧
    card_session.dart        逻辑通道 + APDU 收发
    asn1.dart                BER/DER 编解码
    lpa.dart                 ES10b/ES10c + ES10x 分片
    smdp_client.dart         ES9+ HTTP 客户端
    profile_downloader.dart  七步下载编排
```

## 用法

```dart
import 'package:esim_ble/esim_ble.dart';

// 1. 扫描
final scanner = CardScanner();
await for (final card in scanner.scan()) {
  print('${card.name} ${card.rssi}dBm');
}

// 2. 解析激活码
final code = ActivationCode.tryParse('LPA:1$rsp-0001.linksfield.net$ABC-123');

// 3. 下载（连接→写卡→断开）
final result = await ProfileDownloader.connect(
  card.device,
  code!,
  onProgress: (stage, detail) => print('$stage: $detail'),
);
print('已写入 ICCID ${result.iccid}');
```

## 七步流程

1. ES10b GetEuiccChallenge + GetEUICCInfo1（卡）
2. ES9+ initiateAuthentication（网络）
3. ES10b AuthenticateServer（卡）
4. ES9+ authenticateClient（网络）
5. ES10b PrepareDownload（卡）
6. ES9+ getBoundProfilePackage（网络）
7. ES10b LoadBoundProfilePackage（卡）← **真正写卡**

## 已知限制

- **未真机验证**。协议来自反编译 + lpac 参考实现，分片序号、响应拼接逻辑需实测确认。
- **SmartCard cmd 枚举值是推断的**（open=0 / close=1 / apdu=2），未从源码直接确认。
- **没做 ES10b 通知处理**（ProfileInstallationResult 上报给 SM-DP+ 的后续通知）。
- **没做 ASN.1 签名校验**：证书链由卡验证，客户端不做二次校验（与 lpac 一致）。
- **加密会话未实现**：仅支持明文模式。若设备开启了 secure，需要补 AES-CCM。

## 启用加密（如需）

参考 `n3.java`：AES-CCM，32-bit tag，16 字节 key，nonce = initNonce[12] 后 4 字节加计数器。
