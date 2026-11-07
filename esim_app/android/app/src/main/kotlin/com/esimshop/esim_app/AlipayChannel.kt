package com.esimshop.esim_app

import android.app.Activity
import android.os.Handler
import android.os.Looper
import com.alipay.sdk.app.PayTask
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * 支付宝安卓桥接 —— 官方 App 支付 SDK（alipaysdk-android 15.8.42）。
 *
 * 之前那版是自己拼 `alipays://platformapi/startapp?...` 去跳转，手机上点下去
 * 毫无反应：那个 scheme 需要服务器下发的完整 payload，自己拼的参数支付宝
 * 客户端解析不了，于是直接静默失败。
 *
 * 现在改用官方 PayTask：
 *   PayTask(activity).payV2(orderInfo, true)
 *
 * orderInfo 由服务端 alipay.trade.app.pay 签名产生（含 QUICK_MSECURITY_PAY），
 * SDK 会负责唤起支付宝、收银台、以及支付完成后回到本 App。
 *
 * 关键约定：SDK 的返回码只用来提示用户，**是否真的收到钱以服务端异步通知为准**。
 * 9000 也只说明支付宝那边走完了流程，最终仍要轮询 /alipay/status。
 */
class AlipayChannel(
    private val activity: Activity,
    private val channel: MethodChannel,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "onlylink/alipay"

        /** 支付成功（仅表示支付宝端流程完成，仍需服务端确认） */
        private const val STATUS_SUCCESS = "9000"
        /** 用户主动取消 */
        private const val STATUS_CANCEL = "6001"
        /** 正在处理中，结果未知 */
        private const val STATUS_PROCESSING = "8000"
    }

    private val main = Handler(Looper.getMainLooper())

    /**
     * payV2 会阻塞，必须放在子线程。单线程池足够：同一时刻只允许一笔支付，
     * 重复点击由 Dart 侧的 _busyPay 拦住。
     */
    private val executor = Executors.newSingleThreadExecutor()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pay" -> {
                val orderInfo = call.argument<String>("orderInfo")
                    ?: call.argument<String>("orderString")
                    ?: ""
                if (orderInfo.isEmpty()) {
                    result.error("EMPTY", "orderInfo 为空", null)
                    return
                }
                pay(orderInfo, result)
            }
            "isInstalled" -> result.success(isAlipayInstalled())
            else -> result.notImplemented()
        }
    }

    private fun isAlipayInstalled(): Boolean {
        return try {
            activity.packageManager.getPackageInfo("com.eg.android.AlipayGphone", 0); true
        } catch (_: Throwable) {
            false
        }
    }

    private fun pay(orderInfo: String, result: MethodChannel.Result) {
        // 结果只回一次：payV2 返回后立即在主线程 resolve，避免重复回调。
        val replied = java.util.concurrent.atomic.AtomicBoolean(false)
        val reply: (Map<String, Any?>) -> Unit = { m ->
            if (replied.compareAndSet(false, true)) {
                main.post { result.success(m) }
            }
        }

        try {
            executor.execute {
                try {
                    val payTask = PayTask(activity)
                    @Suppress("UNCHECKED_CAST")
                    val raw = payTask.payV2(orderInfo, true) as Map<String, String>

                    val status = raw["resultStatus"] ?: ""
                    reply(
                        mapOf(
                            "resultStatus" to status,
                            "result" to (raw["result"] ?: ""),
                            "memo" to (raw["memo"] ?: ""),
                            // 语义化，Dart 侧不用记住支付宝的魔法数字
                            "success" to (status == STATUS_SUCCESS),
                            "cancelled" to (status == STATUS_CANCEL),
                            "pending" to (status == STATUS_PROCESSING),
                        )
                    )
                } catch (t: Throwable) {
                    reply(
                        mapOf(
                            "resultStatus" to "error",
                            "result" to "",
                            "memo" to (t.message ?: "支付调用失败"),
                            "success" to false,
                            "cancelled" to false,
                            "pending" to false,
                        )
                    )
                }
            }
        } catch (t: Throwable) {
            reply(
                mapOf(
                    "resultStatus" to "error",
                    "result" to "",
                    "memo" to (t.message ?: "无法启动支付线程"),
                    "success" to false,
                    "cancelled" to false,
                    "pending" to false,
                )
            )
        }
    }

    fun dispose() {
        main.removeCallbacksAndMessages(null)
        executor.shutdownNow()
    }
}
