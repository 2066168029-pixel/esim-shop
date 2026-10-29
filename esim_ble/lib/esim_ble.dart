/// Public API surface of the esim_ble package.
library esim_ble;

export 'src/ble_transport.dart'
    show
        CardScanner,
        CardDevice,
        CardConnection,
        LpadGatt,
        BleCardException;
export 'src/card_session.dart' show CardSession, CardError;

/// Transport-agnostic SGP.22 path. This is the one to use for new work: it
/// drives any card/reader (9eSIM BLE, Linksfield, PC/SC, built-in eSIM) and
/// keeps the vendor protocols behind one interface.
export 'src/transports.dart';
export 'src/euicc_transport.dart' show ApduResponse, EuiccTransport, TransportError;
export 'src/sgp22.dart' show EuiccSession, EuiccError;
export 'src/transport_linksfield.dart' show LinksfieldTransport, LpadProbeReport;

/// Known-plaintext capture: the vendor's own AID constant plus a reset, both
/// of which have predictable plaintext. Used to turn "guess the PSK" into
/// "recover the keystream".
export 'src/known_plaintext.dart'
    show
        linksfieldAid,
        knownPlaintextCases,
        linksfieldOpenChannelBody,
        describeKnownPlaintextPlan;
export 'src/known_plaintext_capture.dart'
    show
        KnownPlaintextCapture,
        KnownPlaintextResult,
        PlaintextVerdict,
        comparePlaintext,
        captureKnownPlaintext,
        captureHandshake,
        linksfieldOpenRequest;

export 'src/lpa.dart'
    show Lpa, LpaError, ActivationCode, ProfileSummary, es10xMss;
export 'src/messages.dart' show TransmitApdu, TransmitApduRsp, DeviceInfo;
export 'src/notifications.dart'
    show NotificationSupport, PendingNotification, NotificationDrainResult;
export 'src/profile_downloader.dart'
    show ProfileDownloader, DownloadResult, DownloadStage, ProgressCallback;
export 'src/smdp_client.dart'
    show
        SmdpClient,
        SmdpError,
        AuthenticationData,
        ClientAuthenticationData,
        ProfileMetadata;

/// Linksfield MP (wholesale) API: ordering, activation codes, lifecycle.
/// Separate from the ES9+ path above — that one installs a profile on a card,
/// this one obtains the code that names which profile to install.
export 'src/protocol_scan.dart'
    show
        ProtocolScanReport,
        ProtocolProbeResult,
        scanProtocols,
        lastLinksfieldRawBytes,
        lastLinksfieldAnalysis,
        lastReplyLatencyMs,
        lastCardSpokeFirst,
        lastHandshakeError,
        lastHandshakeTranscript;
export 'src/raw_analysis.dart'
    show analyseRawBytes, RawHypothesis, describeServices;
export 'src/transport_raw_apdu.dart' show RawApduTransport;
export 'src/lpa_mp/mp_signer.dart' show MpCredentials, MpSignature, MpSigner;
export 'src/lpa_mp/mp_client.dart'
    show
        MpClient,
        MpError,
        MpProduct,
        MpActivation,
        MpOrderStatus,
        MpTraffic,
        MpInventory,
        MpSimInfo,
        MpSwitch;
