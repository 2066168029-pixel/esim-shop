package com.esimshop.esim_app

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Dart-facing wrapper around [LpadBleBridge].
 *
 * Threading contract
 * ------------------
 * Every LpadBleBridge call blocks (BLE + card I/O: a download takes minutes).
 * MethodChannel delivers calls on the platform thread, which is also the thread
 * that pumps Flutter's vsync -- blocking it freezes the UI and, at ~5s, trips
 * Android's ANR detector. So:
 *
 *     platform thread: marshal -> worker -> post result back to main
 *
 * Serialised on a single-thread executor on purpose. The SDK holds one GATT
 * connection and one LPAdClient; two overlapping downloads on the same card
 * would interleave frames and corrupt the session. A second call issued while
 * one is running gets BUSY instead of queueing, so the UI can say so.
 */
class LpadChannel(
    private val bridge: LpadBleBridge,
    private val channel: MethodChannel
) : MethodChannel.MethodCallHandler {

    private val worker = Executors.newSingleThreadExecutor { r ->
        Thread(r, "lpad-ble").apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())
    private val busy = AtomicBoolean(false)

    private companion object {
        const val TAG = "LpadChannel"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // Unconditional entry log. Without this, a Dart-side switch that silently
        // fails to route to the native path is indistinguishable from a native
        // failure that logs nothing -- which is exactly how an hour got lost on
        // 2026-10-27.
        Log.i(TAG, "call ${call.method} args=${call.arguments?.let { redact(it) }}")

        val blocking = call.method != "isReady" &&
            call.method != "state" &&
            call.method != "probePassword"

        if (!blocking) {
            main.post { reply(result) { dispatch(call) } }
            return
        }
        if (!busy.compareAndSet(false, true)) {
            // A download is minutes long; refuse rather than pile up.
            result.error("BUSY", "Another card operation is still running", null)
            return
        }
        worker.execute {
            val outcome = runCatching { dispatch(call) }
            busy.set(false)
            main.post {
                outcome.fold(
                    onSuccess = { result.success(it) },
                    onFailure = {
                        val e = asFlutterError(it)
                        result.error(e[0] as String, e[1] as String?, e[2])
                    }
                )
            }
        }
    }

    private inline fun reply(
        result: MethodChannel.Result,
        block: () -> Any?
    ) {
        runCatching(block).fold(
            onSuccess = { result.success(it) },
            onFailure = {
                val e = asFlutterError(it)
                result.error(e[0] as String, e[1] as String?, e[2])
            }
        )
    }

    private fun redact(args: Any?): String {
        // Never log a PSK. Password is the only secret that travels this channel.
        val s = args.toString()
        return if (s.contains("password")) s.replace(Regex("password=[^,}]+"), "password=***") else s
    }

    private fun asFlutterError(t: Throwable): Array<Any?> {        return if (t is LpadError) {
            arrayOf(t.code, t.message, t.extras)
        } else {
            Log.e("LpadChannel", "unexpected failure", t)
            arrayOf("INTERNAL", t.message ?: t.javaClass.simpleName, null)
        }
    }

    private fun dispatch(call: MethodCall): Any? = when (call.method) {
        "state" -> mapOf(
            "connected" to bridge.isReady(),
            "device" to bridge.currentDevice(),
        )

        "connect" -> {
            val mac = call.argument<String>("mac") ?: throw LpadError("INVALID_PARAM", "mac is required")
            bridge.connect(mac, call.argument<String>("password"))
            bridge.deviceInfo()
        }

        "disconnect" -> {
            bridge.close()
            true
        }

        // Cheap lookup the UI uses to decide whether to prompt for the card
        // password. Must not open a GATT link.
        "probePassword" -> bridge.hasStoredPassword(require(call, "mac"))

        // The remembered PSK, so the UI never has to send an empty string in
        // place of "use the saved one". A missing entry answers null.
        "rememberedPassword" -> bridge.rememberedPassword(require(call, "mac"))

        "forgetPassword" -> {
            bridge.forgetPassword(require(call, "mac"))
            true
        }

        "deviceInfo" -> bridge.deviceInfo()
        "getEuiccInfo" -> bridge.getEuiccInfo()
        "getEid" -> bridge.getEid()
        "listProfiles" -> bridge.listProfiles()
        "getMetadata" -> bridge.getMetadata(require(call, "activationCode"))

        "download" -> bridge.download(
            activationCode = require(call, "activationCode"),
            confirmationCode = call.argument<String>("confirmationCode"),
            switchAfter = call.argument<Boolean>("switchAfter") ?: true,
        )

        "enable" -> bridge.enable(require(call, "iccid"))
        "disable" -> bridge.disable(require(call, "iccid"))
        "delete" -> bridge.delete(require(call, "iccid"))
        "setNickname" -> bridge.setNickname(require(call, "iccid"), require(call, "nickname"))

        "getSmdpAddress" -> bridge.getSmdpAddress()
        "setSmdpAddress" -> bridge.setSmdpAddress(require(call, "address"))
        "getSmdsAddress" -> bridge.getSmdsAddress()

        // API 3.3.9 -- SM-DS discovery list.
        "getDsList" -> bridge.getDsList()

        // API 3.2.2 / 3.2.4 / 3.2.6.
        "resetDevice" -> {
            bridge.resetDevice()
            true
        }
        "reopen" -> bridge.reopen()
        "setServiceUuids" -> {
            bridge.setServiceUuids(
                require(call, "service"),
                require(call, "rx"),
                require(call, "tx"),
            )
            true
        }

        else -> throw LpadError("NOT_IMPLEMENTED", "Unknown method ${call.method}")
    }

    private fun require(call: MethodCall, arg: String): String =
        call.argument<String>(arg)?.takeIf { it.isNotBlank() }
            ?: throw LpadError("INVALID_PARAM", "$arg is required")

    fun dispose() {
        bridge.close()
        worker.shutdownNow()
        channel.setMethodCallHandler(null)
    }
}
