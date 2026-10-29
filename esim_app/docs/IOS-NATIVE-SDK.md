# iOS 原生 SDK 集成（路线 A）

把 Linksfield 的闭源 `eSIMManagerSDK.xcframework` 接进 `esim_app`，Dart 只做 UI，
BLE 与 LPA 协议全部交给官方 SDK。

## 为什么这样做

`esim_ble` 包里有一整套**纯 Dart 逆向实现**（`transport_linksfield.dart` 58KB、
`linksfield_secure.dart` 22KB）。这条路在 Android 上能跑，但代价是：

- 官方 SDK 还在更新协议（v1.5.3 仍在改 BLE 加密通信），逆向代码得一直追
- 协议一旦漂移，问题只能自己查

iOS 端改用官方二进制 SDK，把这类风险交给厂商。

## 结构

```
ios/
  Frameworks/
    eSIMManagerSDK.xcframework/     <- 厂商二进制 (34MB, arm64 device only)
    eSIMManagerSDK.podspec          <- 本地 podspec 包装
  Runner/
    NativeLpaBridge.swift           <- 桥接层 (新增)
    AppDelegate.swift               <- 注册桥接 (已改)

lib/
  native_lpa.dart                   <- Dart 通道封装 (新增)
  screens/native_lpa_screen.dart    <- 原生 LPA 页面 (新增)
  screens/activate_screen.dart      <- 按平台分流入口 (已改)
```

## 架构

```
Flutter UI (Dart)
      │
      ├─ MethodChannel  app.esim/native_lpa          (请求/响应)
      └─ EventChannel   app.esim/native_lpa/events   (扫描/连接/通知推送)
      │
NativeLpaBridge.swift
      │   专用串行队列 (SDK 是阻塞式，不可重入)
      │   所有回调切回主线程再回 Dart
      ▼
eSIMManagerSDK.xcframework  ──BLE──▶  eSIM 卡片
```

### 关键设计决策

| 问题 | 处理 |
|---|---|
| SDK 全部方法是**阻塞**的 | 所有调用丢到 `sdkQueue` 串行队列，绝不在主线程跑 |
| `CBCentralManager` 归谁 | 整个 App 共用一个，通过 `queue: sdkQueue` 指定回调队列 |
| 连接后不能立刻读卡 | 等 `STATE_CONNECTED` 后延迟 300ms 再 `getDeviceInfo()`（对齐 demo 行为） |
| 回调不来会卡死 UI | 连接加了 25s 超时兜底 |
| 二进制太大进 git | `.gitattributes` 标 LFS；workflow 里 `lfs: true` |

## 平台可用性

xcframework **只有 `ios-arm64` 一个切片**（无模拟器版本）。

| 环境 | 原生 SDK | 行为 |
|---|---|---|
| 真机 iPhone | ✅ | 用原生 SDK |
| iOS 模拟器 | ❌ | `isAvailable` 返回 false，页面显示说明 |
| Android | ❌ | 回落 `esim_ble` 纯 Dart 实现 |
| Windows/桌面 | ❌ | 同上 |

分流逻辑在 `activate_screen.dart` 的 `_openCardWriter()`：
```dart
if (Platform.isIOS) useNative = await NativeLpa.isAvailable;
useNative ? NativeLpaScreen() : CardWriterScreenV2()
```

## 支持的 LPA 操作

全量封装了 `LPAdClient` 的能力：

- `startScan` / `stopScan` / `connect` / `disconnect`
- `getEid` / `getEuiccInfo` / `getProfiles`
- `download`（含 `-2` 需要确认码的分支）
- `enable` / `disable` / `delete` / `eraseAll`
- `setNickname`
- `getDefaultSmdp` / `setDefaultSmdp`

返回码约定同 SDK：**0 = 成功**，`-2` = 需要确认码。

## 需要验证的部分（Windows 上做不到）

这些只能在 Mac / CI 上验证：

1. **Swift 编译** —— Windows 无 Xcode，桥接层代码未经过编译器
2. **Podfile / podspec 语法** —— 无 Ruby
3. **`pod install` 能否正确解析本地 xcframework**
4. **真机签名与联调**

已验证的：Dart 侧 `flutter analyze` 零问题、`flutter build windows` 完整通过、
workflow YAML / 两个 plist 语法合法、pbxproj 结构完整。

## 首次跑 CI 前

`esim_ble` 仍未进 git，`flutter pub get` 会在 CI 失败（也影响 Windows 构建以外的场景）。先：

```powershell
cd C:\Users\Administrator\.openclaw\workspace
git add .gitattributes esim_ble
git add esim_app/ios/Frameworks esim_app/ios/Runner/NativeLpaBridge.swift
git add esim_app/ios/Podfile esim_app/ios/Runner/AppDelegate.swift
git add esim_app/lib/native_lpa.dart esim_app/lib/screens/native_lpa_screen.dart
git commit -m "feat(ios): integrate Linksfield eSIMManagerSDK via native bridge"
```

注意 `.gitattributes` 会让 xcframework 走 LFS，需要仓库开启 LFS 支持。

## 已知限制

- **模拟器完全不可用** —— 要调试 iOS UI 得用真机
- **`RunnerTests` target 未签名** —— 若要跑测试需单独配置
- **`setLogEnabled` 未接线** —— 桥接层里硬编码关闭 SDK 日志（避免刷屏），
  需要时改 `NativeLpaBridge.swift` 的 `LFCommonUtil.setSDKLogEnable`
