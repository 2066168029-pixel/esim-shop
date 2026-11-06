package com.esimshop.esim_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var esimChannel: ESimChannel? = null
    private var lpadChannel: LpadChannel? = null
    private var alipayChannel: AlipayChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Registration is deliberately defensive: any failure here must not
        // stop the Flutter engine from starting. eSIM install is a feature,
        // not a prerequisite for the app running.
        try {
            val channel = ESimChannel(this)
            esimChannel = channel
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ESimChannel.CHANNEL)
                .setMethodCallHandler(channel)
            channel.register()
        } catch (t: Throwable) {
            // Swallow and log: the Dart side treats a missing channel as
            // "eSIM unsupported" and falls back to the QR flow.
            android.util.Log.e("MainActivity", "eSIM channel unavailable", t)
            esimChannel = null
        }

        // Vendor LPA stack over BLE. Separate channel from the system EuiccManager
        // one above: that one installs into the phone's own eSIM, this one writes
        // to a physical card reader. The two must not share error codes.
        try {
            val methodChannel = MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                LpadBleBridge.CHANNEL
            )
            val lpad = LpadChannel(LpadBleBridge(applicationContext), methodChannel)
            lpadChannel = lpad
            methodChannel.setMethodCallHandler(lpad)
        } catch (t: Throwable) {
            android.util.Log.e("MainActivity", "LPA BLE channel unavailable", t)
            lpadChannel = null
        }

        // 支付宝：只负责把用户送到收银台，付没付由服务端异步通知判定。
        try {
            val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AlipayChannel.CHANNEL_NAME)
            val alipay = AlipayChannel(this, ch)
            alipayChannel = alipay
            ch.setMethodCallHandler(alipay)
        } catch (t: Throwable) {
            android.util.Log.e("MainActivity", "Alipay channel unavailable", t)
            alipayChannel = null
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        try {
            esimChannel?.dispose()
        } catch (t: Throwable) {
            android.util.Log.w("MainActivity", "eSIM channel cleanup failed", t)
        }
        esimChannel = null
        try {
            lpadChannel?.dispose()
        } catch (t: Throwable) {
            android.util.Log.w("MainActivity", "LPA channel cleanup failed", t)
        }
        lpadChannel = null
        try {
            alipayChannel?.dispose()
        } catch (t: Throwable) {
            android.util.Log.w("MainActivity", "Alipay channel cleanup failed", t)
        }
        alipayChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
