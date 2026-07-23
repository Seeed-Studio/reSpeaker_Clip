/// WiFi hotspot information returned by the device over BLE (AT command).
class WifiHotspotInfo {
  final bool enabled;
  final String ssid;
  final String password;
  final String ip;
  final int port;
  final int? channel;

  const WifiHotspotInfo({
    required this.enabled,
    required this.ssid,
    required this.password,
    required this.ip,
    required this.port,
    this.channel,
  });

  factory WifiHotspotInfo.fromJson(Map<String, dynamic> json) {
    final data = json['data'] is Map<String, dynamic>
        ? json['data'] as Map<String, dynamic>
        : json;
    // Firmware may report AP up as `running: true` without `enabled`.
    final on = data['enabled'] == true ||
        data['running'] == true ||
        data['ap_running'] == true;
    var ip = (data['ip'] ?? '192.168.4.1').toString().trim();
    if (ip.isEmpty || ip == '0.0.0.0' || ip == '::' || ip == '::0') {
      ip = '192.168.4.1';
    }
    var port = _parseInt(data['port']);
    if (port == null || port <= 0) {
      port = 8089;
    }
    return WifiHotspotInfo(
      enabled: on,
      ssid: (data['ssid'] ?? '').toString().trim(),
      password: (data['password'] ?? '').toString().trim(),
      ip: ip,
      port: port,
      channel: _parseInt(data['channel']),
    );
  }

  /// Legacy HTTP base URL. The transfer protocol is actually UDP on [port];
  /// kept for tools that still probe HTTP.
  String get baseUrl => 'http://$ip:$port';

  bool get isValid => ssid.isNotEmpty && password.isNotEmpty && ip.isNotEmpty;

  static int? _parseInt(Object? v) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  @override
  String toString() =>
      'WifiHotspotInfo(enabled=$enabled, ssid=$ssid, ip=$ip:$port, ch=$channel)';
}
