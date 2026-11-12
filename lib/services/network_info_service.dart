import "dart:io";

import "package:network_info_plus/network_info_plus.dart";

/// Looks up the device's active local LAN or Wi-Fi IPv4 address.
class NetworkInfoService {
  NetworkInfoService({NetworkInfo? networkInfo})
      : _networkInfo = networkInfo ?? NetworkInfo();

  final NetworkInfo _networkInfo;

  /// Returns the Wi-Fi IPv4 address where available, falling back to
  /// active network interfaces and finally `127.0.0.1`.
  Future<String> getLocalIpAddress() async {
    try {
      final wifiIp = await _networkInfo.getWifiIP();
      if (wifiIp != null && wifiIp.isNotEmpty && wifiIp != "0.0.0.0") {
        return wifiIp;
      }
    } catch (_) {
      // Fall back to dart:io interface enumeration on platforms or
      // contexts where network_info_plus is unavailable.
    }

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );

      String? fallbackIp;
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          final ip = addr.address;
          if (_isPrivateLanIpv4(ip)) {
            return ip;
          }
          fallbackIp ??= ip;
        }
      }
      if (fallbackIp != null) {
        return fallbackIp;
      }
    } catch (_) {
      // Nothing further to try; fall back to loopback below.
    }

    return "127.0.0.1";
  }

  bool _isPrivateLanIpv4(String ip) {
    if (ip.startsWith("192.168.") || ip.startsWith("10.")) {
      return true;
    }
    if (ip.startsWith("172.")) {
      final parts = ip.split(".");
      if (parts.length >= 2) {
        final secondOctet = int.tryParse(parts[1]);
        if (secondOctet != null && secondOctet >= 16 && secondOctet <= 31) {
          return true;
        }
      }
    }
    return false;
  }
}

