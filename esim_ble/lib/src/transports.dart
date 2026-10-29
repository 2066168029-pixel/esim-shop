/// Public surface of the transport layer.
///
/// Import this to work with cards without caring which reader is attached:
///
/// ```dart
/// final transport = await openAnyTransport(device); // 9eSIM, Linksfield, ...
/// final session = EuiccSession(transport);
/// await session.open();
/// final lpa = Lpa(session);
/// final profiles = await lpa.listProfiles();
/// ```
library;

export 'euicc_transport.dart'
    show ApduResponse, EuiccTransport, TransportError;
export 'sgp22.dart' show EuiccError, EuiccSession;
export 'transport_9esim_ble.dart' show Esim9BleTransport, Esim9Gatt;
export 'transport_linksfield.dart' show LinksfieldTransport;
export 'profile_downloader.dart'
    show openAnyTransport, probeTransport, ReaderProbe, diagnoseReader;
