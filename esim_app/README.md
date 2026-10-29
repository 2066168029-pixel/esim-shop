# eSIM 商城 · 手机 App（Flutter）

面向消费者（出境用户）的原生移动 App，卖 **eSIM 流量套餐** 和 **实体 SIM 卡**。

- 前端：**Flutter**（一套代码 → Android APK / iOS / Windows）
- 后端：复用 `../esim-shop/backend` 的 FastAPI 服务（无需改动）
- 供应商：`mock`（后期把 `RealSupplier` 接上你的真实 SIM API 即可）

## 已实现的功能

| 页面 | 说明 |
|---|---|
| 首页 | 顶部 Banner、热门目的地快捷入口、热门套餐列表 |
| 套餐列表 | 搜索 + 类型/国家/排序筛选 |
| 购物车 | 数量增减、删除、合计 |
| 结算 | 邮箱、实体卡收货信息、优惠码、**支付方式（微信/支付宝/Mock 占位）**、金额明细 |
| 订单详情 | **eSIM 激活二维码**、ICCID、激活码（可复制）、流量用量刷新、实体卡物流 |
| 我的eSIM | 订单列表、状态、进入详情 |
| 我的 | 账号信息、我的订单、退出登录 |
| 登录/注册 | 邮箱密码，演示账号一键登录 |

底部导航：**首页 / 我的eSIM / 购物车 / 我的**

## 目录结构

```
esim_app/
├── lib/
│   ├── main.dart          App 入口 + 底部导航 Shell
│   ├── api.dart           API 客户端 + 数据模型 + ApiConfig
│   ├── service.dart       各接口的封装
│   ├── store.dart         全局状态（登录 token / 购物车，provider）
│   ├── theme.dart         主题配色（中文消费级风格）
│   ├── widgets.dart       复用组件（状态标签、价格、空态…）
│   └── screens/           各页面
│       ├── home_screen.dart
│       ├── plans_screen.dart
│       ├── cart_screen.dart
│       ├── checkout_screen.dart
│       ├── order_detail_screen.dart
│       ├── orders_screen.dart
│       ├── account_screen.dart
│       └── login_screen.dart
└── android/ ios/ windows/  各平台工程
```

## 运行

### 1. 先启动后端
```powershell
cd ..\esim-shop\backend
.\.venv\Scripts\python.exe -m uvicorn app.main:app --host 0.0.0.0 --port 8100
```
> 注意用 `0.0.0.0`，这样手机/模拟器才能访问到。

### 2. 运行 App

**Windows 桌面（最快看到效果）**
```powershell
cd esim_app
flutter run -d windows
```

**Android 模拟器**
```powershell
flutter run -d <emulator-id>
```
模拟器会自动用 `10.0.2.2:8100` 访问宿主机后端，无需配置。

**真机（同一 WiFi）**
```powershell
flutter run --dart-define=API_BASE=http://<你电脑的局域网IP>:8100
```

### 3. 打安装包（APK）
```powershell
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

## 后端地址配置

在 `lib/api.dart` 的 `ApiConfig`：
- Android 模拟器 → `http://10.0.2.2:8100`（自动）
- 其他平台 → `http://127.0.0.1:8100`（自动）
- 真机/自定义 → 用 `--dart-define=API_BASE=http://你电脑IP:8100` 覆盖

## 演示账号

- 用户：`demo@esim.local` / `demo123`
- 管理员：`admin@esim.local` / `admin123`
- 优惠码：`WELCOME10`（9折）、`SAVE5`（满20减5）

## 环境搭建备忘（本机已装好）

- Flutter 3.47.6（`C:\flutter`，国内镜像 `storage.flutter-io.cn`）
- Android SDK（`C:\Android\Sdk`，platform 36 / build-tools 36 / NDK r28c）
- JDK 17（Eclipse Adoptium）
- Gradle 用腾讯镜像分发 + Alibaba Maven 仓库镜像

## 后续可做

1. 对接**真实供应商 API**（改后端 `RealSupplier`，App 不用动）
2. 接入**微信/支付宝真实支付**（需要商户号，后端加支付意图 + 回调）
3. 打包 **iOS**（需 macOS + Xcode）
4. 上架应用商店（图标、启动页、隐私政策、签名 keystore）
