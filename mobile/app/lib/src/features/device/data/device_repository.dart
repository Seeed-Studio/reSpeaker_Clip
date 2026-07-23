import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sensecraft_voice/sensecraft_voice.dart';
import 'package:sqflite/sqflite.dart';

import '../../../core/db/db_provider.dart';

/// Avoid re-marking every device offline when [deviceRepositoryProvider] is
/// recreated for the same open [Database] (e.g. after a locale-driven rebuild).
final _offlineMarkedDbInstances = <Database>{};

final deviceRepositoryProvider = FutureProvider<DeviceRepository>((ref) async {
  // Devices live in the account-independent global DB so a bound device stays
  // available across logout / account switch (hardware is not account state).
  final db = await ref.watch(globalDatabaseProvider.future);
  final repo = DeviceRepository(db);
  // After cold start the OS has torn down BLE, but DB may still say online.
  // Mark all devices offline once per DB open — not on every repo refresh.
  if (_offlineMarkedDbInstances.add(db)) {
    await repo.markAllOffline();
  }
  ref.onDispose(() {
    _offlineMarkedDbInstances.remove(db);
  });
  return repo;
});

class DeviceRepository {
  final Database db;

  DeviceRepository(this.db);

  /// On app startup, ensure all devices start as "offline" in the local DB.
  ///
  /// This avoids showing stale "online" status for devices that were connected
  /// in the previous app session but whose BLE connection has since been
  /// dropped by the OS when the app was killed/restarted.
  Future<void> markAllOffline() async {
    await db.update(
      'devices',
      {
        'is_online': 0,
      },
      where: 'is_online = 1',
    );
  }

  /// List all devices, online devices first.
  Future<List<Device>> listAll() async {
    final rows = await db.query(
      'devices',
      orderBy: 'is_online DESC, updated_at DESC',
    );
    return rows.map(_fromRow).toList();
  }

  /// Get device by ID.
  Future<Device?> getById(String id) async {
    final rows = await db.query('devices', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Upsert device (create or update).
  Future<void> upsert(Device device) async {
    final now = DateTime.now().toIso8601String();
    await db.insert(
      'devices',
      {
        'id': device.id,
        'name': device.name,
        'sn': device.sn,
        'model': device.model,
        'battery_percent': device.batteryPercent,
        'recording_mode': device.recordingMode.index,
        'firmware_version': device.firmwareVersion,
        'has_firmware_update': device.hasFirmwareUpdate ? 1 : 0,
        'is_online': device.isOnline ? 1 : 0,
        'last_seen': device.lastSeen?.toIso8601String(),
        'created_at': device.createdAt.toIso8601String(),
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Update device online status and battery.
  Future<void> updateStatus({
    required String id,
    bool? isOnline,
    int? batteryPercent,
  }) async {
    final now = DateTime.now().toIso8601String();
    final updates = <String, Object?>{'updated_at': now};
    if (isOnline != null) {
      updates['is_online'] = isOnline ? 1 : 0;
      if (isOnline) {
        updates['last_seen'] = now;
      }
    }
    if (batteryPercent != null) {
      updates['battery_percent'] = batteryPercent;
    }
    await db.update('devices', updates, where: 'id = ?', whereArgs: [id]);
  }

  /// Update device name (user customization).
  Future<void> updateName(String id, String name) async {
    final now = DateTime.now().toIso8601String();
    await db.update(
      'devices',
      {'name': name, 'updated_at': now},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Update device recording mode (normal/enhanced).
  Future<void> updateRecordingMode(String id, RecordingMode mode) async {
    final now = DateTime.now().toIso8601String();
    await db.update(
      'devices',
      {'recording_mode': mode.index, 'updated_at': now},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Update firmware info (version + update indicator).
  Future<void> updateFirmwareInfo({
    required String id,
    String? firmwareVersion,
    bool? hasFirmwareUpdate,
  }) async {
    final now = DateTime.now().toIso8601String();
    final updates = <String, Object?>{'updated_at': now};
    if (firmwareVersion != null) updates['firmware_version'] = firmwareVersion;
    if (hasFirmwareUpdate != null) updates['has_firmware_update'] = hasFirmwareUpdate ? 1 : 0;
    await db.update('devices', updates, where: 'id = ?', whereArgs: [id]);
  }

  /// Delete device.
  Future<void> delete(String id) async {
    await db.delete('devices', where: 'id = ?', whereArgs: [id]);
  }

  Device _fromRow(Map<String, Object?> r) {
    DateTime? parseDt(Object? v) => v is String ? DateTime.tryParse(v) : null;
    int parseInt(Object? v, int fallback) => v is int ? v : fallback;
    return Device(
      id: r['id'] as String,
      name: r['name'] as String,
      sn: r['sn'] as String?,
      model: r['model'] as String,
      batteryPercent: r['battery_percent'] as int?,
      recordingMode: RecordingMode.values[parseInt(r['recording_mode'], 0).clamp(0, RecordingMode.values.length - 1)],
      firmwareVersion: r['firmware_version'] as String?,
      hasFirmwareUpdate: (r['has_firmware_update'] as int? ?? 0) == 1,
      isOnline: (r['is_online'] as int) == 1,
      lastSeen: parseDt(r['last_seen']),
      createdAt: parseDt(r['created_at']) ?? DateTime.now(),
      updatedAt: parseDt(r['updated_at']) ?? DateTime.now(),
    );
  }
}
