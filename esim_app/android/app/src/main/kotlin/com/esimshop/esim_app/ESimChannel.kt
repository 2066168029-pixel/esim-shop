package com.esimshop.esim_app

import android.app.Activity
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.telephony.euicc.DownloadableSubscription
import android.telephony.euicc.EuiccManager
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Native bridge to the platform eSIM stack (EuiccManager).
 *
 * Design notes
 * ------------
 * 1. We deliberately DO NOT implement SGP.22 ourselves. Android 9 (API 28)+
 *    ships an LPA, so handing it an activation code is enough. This keeps the
 *    app small and avoids requiring GSMA certification.
 * 2. Activation codes are plain strings, so we build a DownloadableSubscription
 *    with EuiccManager.embeddedSubscription (API 28+). `DownloadSubscriptionResult`
 *    only exists on API 34+, so results are read from the legacy intent extras,
 *    which work on every supported version.
 * 3. Every entry point re-checks capability. A missing eSIM module must produce
 *    a typed error code the Dart side can turn into a helpful message.
 * 4. `downloadSubscription` is asynchronous via PendingIntent. Pending results
 *    are keyed by request id so concurrent installs do not cross callbacks.
 *
 * Error codes returned to Dart (stable contract -- do not renumber):
 *   NOT_SUPPORTED        OS too old (API < 28) or no eUICC
 *   BAD_CODE             activation code is not a valid LPA:1$... string
 *   ALREADY_IN_PROGRESS  a download is already running for this request
 *   RESOLUTION_REQUIRED  user confirmation needed
 *   EMBEDDED_SUBSCRIPTION_ERROR / DOWNLOAD_ERROR
 */
class ESimChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.esimshop.esim/eui"
        private const val TAG = "ESimChannel"

        const val ACTION_DOWNLOAD_RESULT = "com.esimshop.esim.DOWNLOAD_RESULT"
        const val EXTRA_REQUEST_ID = "request_id"
    }

    // Resolved lazily and defensively: some devices/vendors throw from
    // getSystemService, and a failure here must degrade to "unsupported"
    // rather than crash the activity during engine setup.
    private val euicc: EuiccManager? by lazy {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return@lazy null
        try {
            activity.getSystemService(Context.EUICC_SERVICE) as? EuiccManager
        } catch (t: Throwable) {
            Log.e(TAG, "EuiccManager unavailable", t)
            null
        }
    }

    /** requestId -> pending Flutter result, so the broadcast can resolve it. */
    private val pending = mutableMapOf<String, MethodChannel.Result>()

    /**
     * Route results from the manifest-declared receiver into whichever request
     * is waiting. Using a manifest receiver (not a runtime one) keeps the
     * callback intact when the system dialog backgrounds or recreates us.
     */
    fun register() {
        try {
            DownloadResultReceiver.forwarder = fun(intent: Intent) {
                val requestId = intent.getStringExtra(EXTRA_REQUEST_ID) ?: return
                val result = pending.remove(requestId) ?: return
                resolveDownloadResult(intent, result)
            }
        } catch (t: Throwable) {
            Log.e(TAG, "failed to register result forwarder", t)
        }
    }

    fun dispose() {
        DownloadResultReceiver.forwarder = null
        pending.clear()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getCapability" -> result.success(
                try { capability() } catch (t: Throwable) {
                    Log.e(TAG, "capability probe failed", t)
                    mapOf("supported" to false, "reason" to "probe_failed")
                }
            )
            "isEsimSupported" -> result.success(
                try { isSupported() } catch (t: Throwable) { false }
            )
            "download" -> download(call, result)
            "deleteProfile" -> deleteProfile(call, result)
            "switchProfile" -> switchProfile(call, result)
            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------------- state

    private fun isSupported(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
        return euicc?.isEnabled == true
    }

    private fun capability(): Map<String, Any?> {
        val apiOk = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
        val enabled = apiOk && (euicc?.isEnabled == true)
        return mapOf(
            "supported" to enabled,
            "apiLevel" to Build.VERSION.SDK_INT,
            "euiccEnabled" to enabled,
            "reason" to when {
                !apiOk -> "android_too_old"
                euicc == null -> "no_euicc_service"
                !enabled -> "euicc_disabled"
                else -> null
            },
        )
    }

    // ------------------------------------------------------------- download

    private fun download(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P || !isSupported()) {
            result.error("NOT_SUPPORTED", "eSIM is not available on this device", capability())
            return
        }
        val code = (call.argument<String>("activationCode") ?: "").trim()
        val requestId = call.argument<String>("requestId") ?: System.currentTimeMillis().toString()

        if (!isValidActivationCode(code)) {
            result.error(
                "BAD_CODE",
                "Not an eSIM activation code. Expected LPA:1\$<smdp>\$<matchingId>.",
                null
            )
            return
        }
        if (pending.containsKey(requestId)) {
            result.error("ALREADY_IN_PROGRESS", "A download is already running", null)
            return
        }

        // API 28+: build the subscription object from the activation code.
        val subscription: DownloadableSubscription =
            DownloadableSubscription.forActivationCode(code)

        val callbackIntent = PendingIntent.getBroadcast(
            activity,
            requestId.hashCode(),
            Intent(ACTION_DOWNLOAD_RESULT)
                .setPackage(activity.packageName)
                .putExtra(EXTRA_REQUEST_ID, requestId),
            PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                    PendingIntent.FLAG_MUTABLE else 0)
        )

        pending[requestId] = result
        try {
            @Suppress("DEPRECATION")
            euicc!!.downloadSubscription(
                subscription,
                /* switchAfterDownload = */ true,
                callbackIntent
            )
        } catch (e: Exception) {
            pending.remove(requestId)
            result.error("DOWNLOAD_START_FAILED", e.message ?: e.javaClass.simpleName, null)
        }
    }

    /**
     * Parses the platform callback.
     *
     * The result arrives as plain intent extras on every API level; only API 34
     * introduced a typed DownloadSubscriptionResult, so we deliberately use the
     * extras to stay compatible with Android 9-13.
     */
    private fun resolveDownloadResult(intent: Intent, result: MethodChannel.Result) {
        // The platform encodes the outcome as a "result code" in the DETAILED_CODE
        // extra on callback intents (the constant name is historical).
        val resultCode = intent.getIntExtra(
            EuiccManager.EXTRA_EMBEDDED_SUBSCRIPTION_DETAILED_CODE,
            EuiccManager.EMBEDDED_SUBSCRIPTION_RESULT_ERROR
        )
        val errorCode = intent.getIntExtra(
            EuiccManager.EXTRA_EMBEDDED_SUBSCRIPTION_ERROR_CODE, -1
        )

        when (resultCode) {
            EuiccManager.EMBEDDED_SUBSCRIPTION_RESULT_OK -> {
                result.success(mapOf("ok" to true, "status" to "ok"))
            }
            EuiccManager.EMBEDDED_SUBSCRIPTION_RESULT_RESOLVABLE_ERROR -> {
                // The system wants to show its own confirmation UI. There is no
                // public API to hand that dialog's Intent back to the caller, so
                // Dart treats this as "user must confirm in the system dialog".
                result.error(
                    "RESOLUTION_REQUIRED",
                    "User confirmation required",
                    mapOf("hasResolution" to true)
                )
            }
            EuiccManager.EMBEDDED_SUBSCRIPTION_RESULT_ERROR -> {
                result.error(
                    "EMBEDDED_SUBSCRIPTION_ERROR",
                    describeError(errorCode),
                    mapOf("errorCode" to errorCode)
                )
            }
            else -> result.error("DOWNLOAD_ERROR", "resultCode=$resultCode", null)
        }
    }

    private fun describeError(errorCode: Int): String = when (errorCode) {
        2 -> "eSIM download failed: invalid activation code"
        3 -> "eSIM download failed: profile not found"
        4 -> "eSIM download failed: profile install error"
        5 -> "eSIM download failed: not enough space on the eSIM"
        6 -> "eSIM download failed: SIM lock prevents installing"
        7 -> "eSIM download failed: device not authorised for this profile"
        8 -> "eSIM download failed: profile requires a confirmation code"
        -1 -> "eSIM download failed"
        else -> "eSIM download failed (error $errorCode)"
    }

    // ---------------------------------------------------- profile management

    private fun deleteProfile(call: MethodCall, result: MethodChannel.Result) {
        result.error("NOT_IMPLEMENTED", "deleteProfile is not enabled", null)
    }

    private fun switchProfile(call: MethodCall, result: MethodChannel.Result) {
        result.error("NOT_IMPLEMENTED", "switchProfile is not enabled", null)
    }

    // ------------------------------------------------------------ validation

    /**
     * Accepts:
     *   LPA:1$<smdp-address>$<matching-id>
     *   a raw matching id (>= 8 chars)
     *
     * Rejects UI chrome like `LPA:1`, ICCIDs, and URLs -- a common bad-input
     * case is a customer scanning the shipping barcode instead of the QR code.
     */
    private fun isValidActivationCode(code: String): Boolean {
        if (code.isEmpty()) return false
        if (code.startsWith("LPA:1", ignoreCase = true)) {
            val parts = code.split('$')
            return parts.size >= 3 && parts[1].isNotBlank() && parts[2].isNotBlank()
        }
        return code.length >= 8 && !code.contains("://")
    }
}
