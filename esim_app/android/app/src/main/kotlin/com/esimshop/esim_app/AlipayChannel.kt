package com.esimshop.esim_app

import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/**
 * 支付宝安卓桥接。
 *
 * 为什么是这个写法：
 *   官方 alipaysdk-android 是 AAR，但项目没引 Maven 仓库也不方便在 CI 里下载。
 *   安卓上拉起支付宝最稳的其实是「构造 intent 直接调起」：
 *     - 支付宝客户端装了：跳它自带的收银台，付完自己回到我们 app
 *     - 没装：跳 H5 收银台
 *   两条路最后都落到「服务端异步通知结算」，所以 app 这边只需要负责
 *   把用户送过去、再在回来时确认状态 —— 判断依据始终是服务端状态，
 *   不是客户端返回码。
 *
 * 这一点和 iOS 不同：iOS 必须用 SDK，因为 iOS 不允许随意拼 scheme 跳转。
 */
class AlipayChannel(
    private val activity: Activity,
    private val channel: MethodChannel,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "onlylink/alipay"

        /** 支付宝客户端包名 */
        private const val ALIPAY_PACKAGE = "com.eg.android.AlipayGphone"

        /** 没装客户端时用的 H5 收银台 */
        private const val H5_GATEWAY = "https://openapi.alipay.com/gateway.do"
    }

    private val main = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pay" -> {
                val orderString = call.argument<String>("orderString") ?: ""
                if (orderString.isEmpty()) {
                    result.error("EMPTY", "orderString 为空", null)
                    return
                }
                try {
                    openAlipay(orderString)
                    // 只回一个标记：真正付没付由服务端说了算
                    result.success("launched")
                } catch (t: Throwable) {
                    result.error("LAUNCH_FAILED", t.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    /**
     * 调起支付宝。
     *
     * orderString 是服务端签名好的一串 key=value&sign=...，
     * 支付宝自己解析它，我们只负责把它塞进 intent。
     */
    private fun openAlipay(orderString: String) {
        // 1) 先试客户端
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setPackage(ALIPAY_PACKAGE)
            addCategory(Intent.CATEGORY_BROWSABLE)
            // 支付宝认这个 scheme 前缀
            data = android.net.Uri.parse("alipays://platformapi/startapp?appId=20000067&url=" +
                android.net.Uri.encode("$H5_GATEWAY?$orderString"))
        }
        if (intent.resolveActivity(activity.packageManager) != null) {
            activity.startActivity(intent)
            return
        }

        // 2) 没装客户端 —— 开浏览器走 H5
        val web = Intent(Intent.ACTION_VIEW, android.net.Uri.parse("$H5_GATEWAY?$orderString"))
        web.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        activity.startActivity(web)
    }

    fun dispose() {
        main.removeCallbacksAndMessages(null)
    }
}
