/// SenseCraft Voice SDK for Flutter.
///
/// Top-level entry point. Import this file and you get the BLE client, the
/// AT(JSON) transport, the data models and the logger facade.
///
/// ```dart
/// import 'package:sensecraft_voice/sensecraft_voice.dart';
///
/// final sdk = SenseCraftVoiceClient();
/// await sdk.startScan();
/// final result = await sdk.scanResults
///     .firstWhere((r) => r.isNotEmpty)
///     .then((r) => r.first);
/// final conn = await sdk.connect(result);
/// final at = AtTransport(
///   commandRx: conn.commandRx,
///   responseTx: conn.responseTx,
///   fileData: conn.fileData,
///   mtu: conn.mtu,
/// );
/// final reply = await at.send('AT+VERSION');
/// print(reply);
/// ```
///
/// See `README.md` for platform setup (BLE / Location permissions) and the
/// device protocol overview.
library;

// BLE
export 'src/ble/ble_client.dart';
export 'src/ble/ble_permissions.dart';
export 'src/ble/ble_uuids.dart';
export 'src/ble/ble_transfer_frame_handler.dart';
export 'src/ble/clip_file_data.dart';
export 'src/ble/mtu_manager.dart';
export 'src/ble/transfer_json_events.dart';

// AT(JSON) protocol transport
export 'src/at/at_transport.dart';

// OTA firmware update
export 'src/ota/firmware_processor.dart';
export 'src/ota/ota_session.dart';

// WiFi hotspot high-speed transfer
export 'src/wifi/fast_sync_session.dart';
export 'src/wifi/hotspot_connector.dart';
export 'src/wifi/transfer_client.dart';
export 'src/wifi/udp_sync_client.dart';
export 'src/wifi/wifi_network_errors.dart';

// High-level recording orchestration
export 'src/session/device_event.dart';
export 'src/session/device_runtime_info.dart';
export 'src/session/device_status.dart';
export 'src/session/session_opus_part_names.dart';
export 'src/session/session_opus_parts_merge.dart';
export 'src/session/session_resume_markers.dart';
export 'src/session/recording_session.dart';

// Data models
export 'src/models/device.dart';
export 'src/models/device_bookmark.dart';
export 'src/models/device_file_meta.dart';
export 'src/models/wifi_hotspot_info.dart';

// Utilities
export 'src/utils/crc32.dart';
export 'src/utils/sdk_log.dart';
export 'src/utils/transfer_progress.dart';

// Re-export the `Guid`, `ScanResult`, `BluetoothDevice` types the SDK exposes
// in its public API so callers don't need a second `flutter_blue_plus`
// import for trivial uses.
export 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show
        BluetoothAdapterState,
        BluetoothBondState,
        BluetoothCharacteristic,
        BluetoothConnectionState,
        BluetoothDevice,
        Guid,
        ScanResult;
