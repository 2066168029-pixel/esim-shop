package com.esimshop.esim_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Manifest-declared receiver for the EuiccManager download callback.
 *
 * Why this exists: the PendingIntent handed to `downloadSubscription` must
 * survive the activity being recreated (the system dialog can put us in the
 * background, and the callback may arrive after process restart). A runtime
 * receiver registered only while ESimChannel is alive would drop that result.
 *
 * This receiver forwards the intent to the live channel when one is attached,
 * and otherwise logs it -- the channel treats a missing callback as "unknown"
 * so the UI can re-check profile state instead of hanging forever.
 */
class DownloadResultReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "EsimResultReceiver"

        /** Set by ESimChannel while it is registered. */
        @Volatile
        var forwarder: ((Intent) -> Unit)? = null
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (intent == null) return
        val target = forwarder
        if (target != null) {
            target(intent)
            return
        }
        // Nobody listening: the app was likely killed mid-download. Record it
        // so the next launch can reconcile state with the store backend.
        Log.w(
            TAG,
            "download result arrived with no active channel: " +
                "request=${intent.getStringExtra(ESimChannel.EXTRA_REQUEST_ID)}"
        )
    }
}
