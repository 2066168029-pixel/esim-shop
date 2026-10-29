# iOS 构建说明（Windows → GitHub Actions）

Windows 上无法运行 Xcode，本项目通过 GitHub Actions 的 macOS runner 出 iOS 包。

## 文件清单

| 文件 | 作用 |
|---|---|
| `.github/workflows/ios-build.yml` | 主构建流水线 |
| `ios/Podfile` | CocoaPods 依赖（新建，之前缺失） |
| `ios/ExportOptions.plist` | 签名导出配置（仅签名构建用） |
| `ios/Runner/Info.plist` | 已补相机/相册/蓝牙权限声明 |

## 两种构建模式

流水线会自动检测 Secrets：**没配签名 secrets → 出未签名 IPA；配齐 → 出可上架的签名 IPA。**

### 模式 A：未签名构建（现在就能用）

- 触发：push 到 `master`/`main`、开 PR、或手动 `workflow_dispatch`
- 产物：`esim_app-unsigned-ipa` artifact
- ⚠️ **未签名 IPA 不能装到真机**，只能用于验证"代码能编译通过"。要真机安装必须有签名，或设备越狱。

### 模式 B：签名构建（上架 App Store / TestFlight）

需要 4 个 Repository secrets + 1 个变量：

| Secret | 内容 | 怎么拿 |
|---|---|---|
| `BUILD_CERTIFICATE_BASE64` | Distribution 证书 .p12 的 base64 | 见下方命令 |
| `P12_PASSWORD` | 导出 p12 时设的密码 | 你自己设的 |
| `KEYCHAIN_PASSWORD` | 临时 keychain 密码（随便设） | 随便设一个 |
| `BUILD_PROVISION_PROFILE_BASE64` | .mobileprovision 的 base64 | 见下方命令 |
| `APPLE_TEAM_ID` | Apple Team ID（10 位） | developer.apple.com → Membership |
| `PROVISIONING_PROFILE_NAME` | profile 的**名称**（不是 UUID） | Xcode / 开发者后台 |

生成 base64：

```powershell
# Windows
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\dist.p12")) | Set-Content cert.txt
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\profile.mobileprovision")) | Set-Content pp.txt
```

然后 `ios/ExportOptions.plist` 里两个 `REPLACE_WITH_*` 必须替换成真实值。

## 上 CI 前必须先做（重要）

### 1. `esim_ble` 必须进仓库

`pubspec.yaml` 里有：

```yaml
esim_ble:
  path: ../esim_ble
```

这是**本地相对路径依赖**。当前 `esim_ble/` 在 git 里是 `?? esim_ble/`（未跟踪），CI checkout 后目录不存在 → `flutter pub get` 直接失败。

流水线有 `Verify path dependency` 步骤会明确报这个错。修复：

```powershell
cd C:\Users\Administrator\.openclaw\workspace
git add esim_ble
git commit -m "chore: track esim_ble local dependency"
```

或者改用 git 依赖 / 发布到私有 pub。

### 2. 仓库没有 remote

```powershell
cd C:\Users\Administrator\.openclaw\workspace
git remote add origin https://github.com/<user>/<repo>.git
git push -u origin master
```

### 3. 仓库根目录需是 workspace

流水线假设仓库里 `esim_app/` 与 `esim_ble/` 是同级目录。当前布局正好满足。若你改成只推 `esim_app`，需把 `esim_ble` 换掉。

## 版本号

`pubspec.yaml` 的 `version: 1.1.20+120` 决定 iOS 的 `CFBundleShortVersionString` 和 `CFBundleVersion`。

- 签名构建时 CI 会覆盖 build number 为 `github.run_number`（避免 App Store 重复 build 号被拒）
- 正式发版建议手动改 `version` 的 `+N` 部分

## Flutter 版本

本地为 **3.47.6**，workflow 锁定同版本，避免本地能编译、CI 却因版本差异失败。

## 国内网络

workflow 默认走 `pub.flutter-io.cn` 镜像（与本地 pub cache 一致）。若 runner 能直连官方源，在 Repository variables 里设：

- `PUB_HOSTED_URL` = `https://pub.dev`
- `FLUTTER_STORAGE_BASE_URL` = `https://storage.googleapis.com`

## 常见失败点

| 症状 | 原因 |
|---|---|
| `path: ../esim_ble` 找不到 | `esim_ble` 没提交 |
| `pod install` 超时 | 镜像/CocoaPods CDN 慢，重跑 |
| 上传 App Store 报重复 build 号 | build number 未递增 |
| 审核被拒要求权限说明 | Info.plist 权限描述缺失（已补） |
| `RunnerTests` 签名失败 | Podfile 只签主 target，测试 target 需单独配置或删掉 |
