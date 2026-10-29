package com.esimshop.esim_app

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import android.util.Log
import com.linksfield.lpad.utils.euiccInfo.ByteUtils
import com.linksfield.lpad.utils.euiccInfo.euicc.Es10b

/**
 * Native BLE path on top of the Linksfield eSIM Manager SDK (droidlib-v1.2.0).
 *
 * Why this exists next to esim_ble
 * --------------------------------
 * The Flutter UI still writes cards through esim_ble (pure Dart, 27 tests).
 * That path came from reverse-engineering the vendor protocol and is not
 * vendor-certified. This class is the vendor's own stack:
 *
 *     EuiccBleDevice  -> NUS GATT transport   (SDK)
 *     LPAdClient      -> gRPC over that link  (SDK)
 *     onDownloadSubscription / onSwitchToSubscription / onDeleteSubscription
 *
 * Everything below mirrors the call order in the SDK's own demo
 * (BleProfileActivity), because that order is what the firmware expects:
 *
 *     EuiccBleDevice -> open() -> initSecure() -> deviceInfo gate
 *                    -> LPAdClient.createLPAdClient()
 *                    -> initSecure() again after 3s
 *
 * Contract notes
 * --------------
 *  - Every call is blocking. LPAdClient talks to the card over BLE, so each
 *    request is tens to hundreds of milliseconds and a download is minutes.
 *    The Dart side MUST call these from a background isolate/task, never the
 *    UI thread. MethodChannel calls already arrive on the platform thread, so
 *    everything here hops to a worker thread and answers via a Handler.
 *  - `createLPAdClient` is documented as throwable (README 1.0.7). It is
 *    caught and reported as CLIENT_FAILED instead of crashing the engine.
 *  - The auth listener is invoked on the SDK's own thread and must return
 *    synchronously. We serve it from a stored PSK or a pre-supplied password;
 *    there is no blocking UI dialog, because a Flutter modal would need the
 *    platform thread that the SDK is already holding.
 */
class LpadBleBridge(private val context: Context) {

    companion object {
        const val CHANNEL = "com.esimshop.esim/lpad"
        private const val TAG = "LpadBleBridge"

        private const val INTERVAL_MS = 250L
        private const val PROTOCOL_LENGTH = 4
        private const val SECOND_SECURE_DELAY_MS = 3000L
        private const val DEFAULT_SLOT_ID = -1
    }

    /** Set once per connection; cleared on close. */
    @Volatile
    private var device: com.linksfield.lpad.device.EuiccBleDevice? = null

    @Volatile
    private var client: com.linksfield.lpad.grpc.LPAdClient? = null

    @Volatile
    private var currentMac: String? = null

    private val passwordStore = LpadPasswordStore(context)

    // ------------------------------------------------------------- lifecycle

    fun isReady(): Boolean = try {
        client != null && device?.isConnected() == true
    } catch (t: Throwable) {
        false
    }

    fun currentDevice(): String? = currentMac

    /** True when a usable password is already stored for [mac]. */
    fun hasStoredPassword(mac: String): Boolean = passwordStore.has(mac)

    /** The stored PSK for [mac], or null. */
    fun rememberedPassword(mac: String): String? = passwordStore.get(mac)

    /** Drop the stored PSK so the next connect must ask the user. */
    fun forgetPassword(mac: String) = passwordStore.remove(mac)

    /**
     * Connect + authenticate + build the gRPC channel.
     *
     * @param mac BLE MAC of the card reader.
     * @param password the card's PSK. Required: deployments provision a unique
     *        password per card group, and the firmware default only works on a
     *        never-provisioned card. Guessing it produces a fresh challenge
     *        instead of UPDATE, which reads as a protocol failure and wastes
     *        far more time than asking.
     *
     *        The stored value is still consulted when the caller omits the
     *        argument, so reconnecting to a card that already succeeded once
     *        does not re-prompt.
     */
    @Throws(LpadError::class)
    fun connect(mac: String, password: String? = null) {
        if (mac.isBlank()) throw LpadError("INVALID_PARAM", "BLE address is empty")

        val psw = password?.takeIf { it.isNotEmpty() } ?: passwordStore.get(mac)
        if (psw.isNullOrBlank()) {
            throw LpadError(
                "PASSWORD_REQUIRED",
                "This card needs its password. Enter it to connect."
            )
        }
        if (currentMac.equals(mac, ignoreCase = true) && isReady()) return

        val adapter = bluetoothAdapter()
            ?: throw LpadError("NOT_ENABLED", "This device has no Bluetooth adapter")
        if (!adapter.isEnabled) {
            throw LpadError("NOT_ENABLED", "Bluetooth is turned off")
        }

        Log.i(TAG, "connect mac=$mac interval=${INTERVAL_MS}ms protoLen=$PROTOCOL_LENGTH")
        close()

        val bleDevice = com.linksfield.lpad.device.EuiccBleDevice(context, adapter, mac).apply {
            // Must be set before open(), per API 3.2.6.
            pendingUuids?.let { setEuiccBleServiceUUID(it.first, it.second, it.third) }
            setIntervalTime(INTERVAL_MS)
            setProtocolLength(PROTOCOL_LENGTH)
            setUserAuthenticationListener(object :
                com.linksfield.lpad.utils.UserAuthenticationListener {
                override fun onPromptUserAuthentication(id: String?): String {
                    // SDK calls this on its own thread and blocks until we return.
                    // Only the user-supplied / stored value is ever handed back.
                    return psw
                }
            })
        }

        val opened = try {
            bleDevice.open()
        } catch (t: Throwable) {
            Log.e(TAG, "open threw", t)
            false
        }
        Log.i(TAG, "open() -> $opened")
        if (!opened) {
            quietClose(bleDevice)
            throw LpadError("OPEN_FAILED", "Could not open the BLE link to $mac")
        }

        // First secure pass. Failures here are tolerated: the demo does the same,
        // because the card sometimes only completes the handshake after the
        // channel is up.
        runCatching { bleDevice.initSecure(context, mac, psw) }
            .onFailure { Log.w(TAG, "initSecure#1: ${it.javaClass.simpleName}: ${it.message}") }

        val info = bleDevice.deviceInfo
        Log.i(TAG, "deviceInfo vendor=${info?.vendor} imei=${info?.imei} sn=${info?.sn}")
        if (info?.imei.isNullOrEmpty()) {
            quietClose(bleDevice)
            throw LpadError("NO_IMEI", "Device reported no IMEI; not a valid eSIM card")
        }

        val lpadClient = try {
            com.linksfield.lpad.grpc.LPAdClient.createLPAdClient(context, bleDevice)
        } catch (t: Throwable) {
            // Documented requirement since 1.0.7.
            Log.e(TAG, "createLPAdClient failed", t)
            quietClose(bleDevice)
            throw LpadError("CLIENT_FAILED", t.message ?: t.javaClass.simpleName)
        }
        Log.i(TAG, "createLPAdClient ok")

        device = bleDevice
        client = lpadClient
        currentMac = mac
        // Only remembered once the handshake actually worked, so a typo cannot
        // get cached and silently reused on the next connect.
        passwordStore.save(mac, psw)

        // Second secure pass after the channel settles (demo behaviour).
        try {
            Thread.sleep(SECOND_SECURE_DELAY_MS)
            bleDevice.initSecure(context, mac, psw)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
        } catch (t: Throwable) {
            Log.w(TAG, "initSecure#2: ${t.javaClass.simpleName}")
        }
    }

    fun close() {
        try {
            device?.close()
        } catch (t: Throwable) {
            Log.w(TAG, "close failed: ${t.javaClass.simpleName}")
        }
        device = null
        client = null
        currentMac = null
    }

    // ------------------------------------------------------------------- eSIM

    fun deviceInfo(): Map<String, Any?> {
        val info = requireClient().let { device?.deviceInfo }
        return mapOf(
            "vendor" to info?.vendor,
            "deviceName" to info?.deviceName,
            "imei" to info?.imei,
            "sn" to info?.sn,
            "bleMac" to runCatching { device?.getBleMac() }.getOrNull(),
        )
    }

    fun getEid(): String? {
        val eid = requireClient().onGetEid(DEFAULT_SLOT_ID)
        Log.i(TAG, "getEid -> $eid")
        return eid
    }

    /** @return list of {iccid, nickname, profileName, state} */
    fun listProfiles(): List<Map<String, Any?>> {
        val rsp = requireClient().onGetEuiccProfileInfoList(DEFAULT_SLOT_ID)
        val code = rsp?.getResult() ?: -1
        Log.i(TAG, "listProfiles -> result=$code count=${rsp?.profiles?.size ?: 0}")
        if (code != 0) throw LpadError("CARD_ERROR", "Profile list failed (result $code)")
        return rsp.profiles?.map {
            linkedMapOf(
                "iccid" to it.iccid,
                "nickname" to it.nickname,
                "profileName" to it.profileName,
                "serviceProvider" to it.serviceProviderName,
                "state" to it.state,
            )
        } ?: emptyList()
    }

    /**
     * Read the carrier metadata for an activation code before downloading.
     * Mirrors the demo: this is the "which operator is this?" step.
     *
     * @return {ok, carrierName, resultCode}
     */
    fun getMetadata(activationCode: String): Map<String, Any?> {
        // The SDK was compiled against a shaded copy of the platform class
        // (android_.telephony.euicc.DownloadableSubscription), so the framework
        // type has to be bridged through its encoded form rather than passed in.
        val sub = android_.telephony.euicc.DownloadableSubscription.Builder()
            .setEncodedActivationCode(activationCode)
            .build()
        val rsp = requireClient().onGetDownloadableSubscriptionMetadata(DEFAULT_SLOT_ID, sub, true)
        val code = rsp?.getResult() ?: -1
        return mapOf(
            "ok" to (code == 0),
            // Same packed detailed code contract as download().
            "resultCode" to code,
            "carrierName" to rsp?.downloadableSubscription?.carrierName,
        )
    }

    /**
     * The real write. Blocking for the duration of the download.
     *
     * @param switchAfter true to enable the profile as soon as it lands.
     * @return {ok, resultCode, iccid}
     */
    fun download(
        activationCode: String,
        confirmationCode: String? = null,
        switchAfter: Boolean = true
    ): Map<String, Any?> {
        val c = requireClient()
        val sub = android_.telephony.euicc.DownloadableSubscription.Builder()
            .setEncodedActivationCode(activationCode)
            .setConfirmationCode(confirmationCode)
            .build()

        // Same notification hooks the demo uses, so the card's own progress
        // reporting stays consistent.
        val bleDevice = device
        runCatching { bleDevice?.notifyDevice("download", "progress", "", "") }

        val code = try {
            c.onDownloadSubscription(DEFAULT_SLOT_ID, sub, switchAfter, false)
        } catch (t: Throwable) {
            runCatching { bleDevice?.notifyDevice("download", "fail", "fail", "") }
            throw LpadError("DOWNLOAD_FAILED", t.message ?: t.javaClass.simpleName)
        }

        if (code != 0) {
            runCatching { bleDevice?.notifyDevice("download", "fail", "fail", "") }
            // -2 means the operator wants a confirmation code.
            throw LpadError(
                if (code == -2) "NEED_CONFIRMATION_CODE" else "DOWNLOAD_FAILED",
                describeDownloadCode(code),
                // The packed detailed code goes to Dart untouched: only there
                // is it decoded into operation/error or subject/reason, in the
                // same shape the vendor demo uses. Translating it to prose here
                // would throw away the codes support needs.
                mapOf("detailedCode" to code)
            )
        }
        runCatching { bleDevice?.notifyDevice("download", "success", "ok", "") }

        // Read back so the caller can verify it landed on the expected ICCID.
        val iccid = runCatching {
            listProfiles().firstOrNull { it["state"] == 1 }?.get("iccid") as? String
                ?: listProfiles().lastOrNull()?.get("iccid") as? String
        }.getOrNull()

        return mapOf("ok" to true, "resultCode" to code, "iccid" to iccid)
    }

    fun enable(iccid: String): Int {
        requireClient()
        val code = client!!.onSwitchToSubscription(DEFAULT_SLOT_ID, iccid, false)
        Log.i(TAG, "enable($iccid) -> $code")
        // Reset only on success, as the vendor demo does. Calling it after a
        // failed switch tears down the reader's card session, and every later
        // APDU then answers SIM_ERR / Channel -1 -- which is exactly how
        // "disable, then enable" turned into an unrecoverable state.
        if (code == 0) {
            runCatching { device?.resetDevice() }
                .onSuccess { Log.i(TAG, "enable resetDevice ok") }
                .onFailure { Log.w(TAG, "enable resetDevice failed: ${it.message}") }
        }
        return code
    }

    fun disable(iccid: String): Int {
        requireClient()
        val code = client!!.onDisableSubscription(DEFAULT_SLOT_ID, iccid)
        Log.i(TAG, "disable($iccid) -> $code")
        if (code == 0) {
            runCatching { device?.resetDevice() }
                .onSuccess { Log.i(TAG, "disable resetDevice ok") }
                .onFailure { Log.w(TAG, "disable resetDevice failed: ${it.message}") }
        }
        return code
    }

    fun delete(iccid: String): Int {
        requireClient()
        val code = client!!.onDeleteSubscription(DEFAULT_SLOT_ID, iccid)
        Log.i(TAG, "delete($iccid) -> $code")
        if (code == 0) {
            runCatching { device?.resetDevice() }
                .onSuccess { Log.i(TAG, "delete resetDevice ok") }
                .onFailure { Log.w(TAG, "delete resetDevice failed: ${it.message}") }
        }
        return code
    }

    fun setNickname(iccid: String, nickname: String): Int {
        requireClient()
        return client!!.onUpdateSubscriptionNickname(DEFAULT_SLOT_ID, iccid, nickname)
    }

    /**
     * ES10b GetEuiccInfo2, decoded through the SDK's own Es10b helper.
     *
     * The SDK hands back the raw response as a hex string on [osVersion];
     * [Es10b.processGetEuiccInfo2Response] turns it into the standard EUICCInfo2
     * fields. Read-only: nothing here touches the card's configuration.
     *
     * @return ordered label -> value pairs for the info panel, or null when the
     *         card did not answer or the payload could not be parsed.
     */
    fun getEuiccInfo(): List<Map<String, String>>? {
        val raw = requireClient().onGetEuiccInfo(DEFAULT_SLOT_ID)?.osVersion
        Log.i(TAG, "getEuiccInfo rawLen=${raw?.length ?: 0}")
        if (raw.isNullOrEmpty()) return null

        val info = try {
            Es10b.processGetEuiccInfo2Response(ByteUtils.hexStringToBytes(raw))
        } catch (t: Throwable) {
            Log.e(TAG, "getEuiccInfo parse failed", t)
            null
        } ?: return null

        fun hex24(list: List<ByteArray>?): String? =
            list?.takeIf { it.isNotEmpty() }
                ?.mapNotNull { k -> ByteUtils.bytesToHexStringMlNs(k, 24) }
                ?.takeIf { it.isNotEmpty() }
                ?.joinToString(",\n") { it.replace("[", "").replace("]", "") }

        val out = mutableListOf<Map<String, String>>()
        fun add(label: String, value: String?) {
            if (!value.isNullOrBlank()) {
                out.add(linkedMapOf("label" to label, "value" to value))
            }
        }

        add("Profile 版本", info.profileVersion)
        add("SVN", info.svn)
        add("固件版本", info.euiccFirmwareVer)

        info.extCardResInfo?.let {
            add("已安装应用数", it.installedAppNumber.toString())
            add("可用内存", "易失 ${it.freeVolatileMem} / 非易失 ${it.freeNonVolatileMem}")
            // Raw numbers, so the capacity can be derived offline instead of
            // guessing: profile slot size = (free_before - free_after) after one
            // write, and max slots = free_bytes / slot_size.
            Log.i(TAG, "EUICCInfo2 mem: volatile=${it.freeVolatileMem} " +
                "nonVolatile=${it.freeNonVolatileMem} " +
                "installedApps=${it.installedAppNumber}")
        }
        info.uiccCapability?.let {
            add("UICC 能力", it.toString().replace("[", "").replace("]", ""))
        }
        add("JavaCard 版本", info.javacardVersion)
        add("GP 版本", info.globalplatformVersion)
        info.rspCapability?.let {
            add("RSP 能力", it.toString().replace("[", "").replace("]", ""))
        }
        add("eUICC 类别", info.euiccCategory?.name)
        info.forbiddenPprs?.takeIf { it.isNotEmpty() }?.let {
            add("禁用 PPR", it.toString().replace("[", "").replace("]", ""))
        }
        add("保护配置版本", info.ppVersion)
        add("SAS 认证编号", info.sasAcreditationNumber)
        info.certificationDataObject?.takeIf { it.size == 2 }?.let {
            add("认证数据对象", "${it[0]}\n${it[1]}")
        }
        add("验证公钥 ID", hex24(info.ciPKIdListForVerification))
        add("签名公钥 ID", hex24(info.ciPKIdListForSigning))

        Log.i(TAG, "getEuiccInfo -> ${out.size} fields")
        return out
    }

    fun getSmdpAddress(): String? = requireClient().requestDefaultSmdpAddress(
        getEid() ?: return null
    )

    fun setSmdpAddress(address: String): Int {
        val eid = getEid() ?: throw LpadError("CARD_ERROR", "EID unavailable")
        return requireClient().setDefaultSmdpAddress(eid, address)
    }

    fun getSmdsAddress(): String? {
        val eid = getEid() ?: return null
        return requireClient().requestSmdsAddress(eid)
    }

    /**
     * SM-DS discovery list (API 3.3.9). Returns the downloadable subscriptions
     * the discovery server offers for this eUICC -- the vendor demo's "DS" tab.
     *
     * Each entry carries its own activation code, so the UI can hand it straight
     * to [download] without the user scanning anything.
     */
    fun getDsList(): Map<String, Any?> {
        val rsp = requireClient().onGetDefaultDownloadableSubscriptionList(DEFAULT_SLOT_ID, false)
        val code = rsp?.getResult() ?: -1
        val items = rsp?.downloadableSubscriptions?.map {
            linkedMapOf(
                "activationCode" to it.encodedActivationCode,
                "confirmationCode" to it.confirmationCode,
                "carrierName" to it.carrierName,
            )
        } ?: emptyList()
        return mapOf(
            "ok" to (code == 0),
            // Same packed detailed-code contract as the other calls.
            "resultCode" to code,
            "subscriptions" to items,
        )
    }

    /**
     * Re-queries the card and re-registers on the network (API 3.2.2).
     * Required after download / switch / disable -- the vendor demo calls it
     * through `resetDevice()` on the AbstractPbDevice once the operation returns.
     */
    fun resetDevice() {
        val d = device ?: throw LpadError("NOT_CONNECTED", "No card connected")
        d.resetDevice()
    }

    /** Drops and rebuilds the GATT link (API 3.2.4). */
    fun reopen(): Boolean {
        val d = device ?: throw LpadError("NOT_CONNECTED", "No card connected")
        return try {
            d.reopen()
            true
        } catch (t: Throwable) {
            Log.w(TAG, "reopen failed: ${t.javaClass.simpleName}")
            throw LpadError("RECONNECT_FAILED", t.message ?: t.javaClass.simpleName)
        }
    }

    /**
     * Overrides the GATT identifiers (API 3.2.6). Must be called before [connect]
     * or it has no effect, exactly as the SDK documents.
     */
    fun setServiceUuids(service: String, rx: String, tx: String) {
        pendingUuids = Triple(service, rx, tx)
    }

    @Volatile
    private var pendingUuids: Triple<String, String, String>? = null

    // -------------------------------------------------------------- internals

    private fun requireClient(): com.linksfield.lpad.grpc.LPAdClient =
        client ?: throw LpadError("NOT_CONNECTED", "No card connected")

    private fun bluetoothAdapter(): BluetoothAdapter? = try {
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
            ?: BluetoothAdapter.getDefaultAdapter()
    } catch (t: Throwable) {
        Log.w(TAG, "adapter probe failed", t)
        null
    }

    private fun quietClose(d: com.linksfield.lpad.device.EuiccBleDevice) {
        try {
            d.close()
        } catch (_: Throwable) {
        }
    }

    /**
     * Platform result codes -> text the user can act on.
     *
     * NOTE: this only runs for codes that arrive as a bare int. The real reason
     * for a failed download is the *detailed code*, which is decoded on the Dart
     * side (lib/lpad_errors.dart) exactly as the vendor demo does. Keeping this
     * here as a fallback is still right, but it must not pretend to understand
     * the packed form -- 0x03002714 is "card full", not "install error".
     */
    private fun describeDownloadCode(code: Int): String = when (code) {
        1 -> "Download failed: invalid activation code"
        2 -> "Download failed: profile not found"
        3 -> "Download failed: installation error"
        4 -> "Download failed: not enough space on the card"
        5 -> "Download failed: SIM lock blocks installation"
        6 -> "Download failed: device not authorised for this profile"
        7 -> "Download failed: confirmation code required"
        -2 -> "This activation code needs a confirmation code"
        else -> "Download failed (detailed code 0x${code.toUInt().toString(16)})"
    }
}

/** Typed failure so Dart can branch on `code` instead of parsing prose. */
class LpadError(val code: String, message: String, val extras: Map<String, Any?>? = null) :
    Exception(message)
