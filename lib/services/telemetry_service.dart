import "dart:async";

import "package:battery_plus/battery_plus.dart";
import "package:connectivity_plus/connectivity_plus.dart";
import "package:flutter/services.dart";

import "../models/telemetry_snapshot.dart";

class TelemetryService {
  TelemetryService({
    Battery? battery,
    Connectivity? connectivity,
    MethodChannel? thermalChannel,
  })  : _battery = battery ?? Battery(),
        _connectivity = connectivity ?? Connectivity(),
        _thermalChannel = thermalChannel ??
            const MethodChannel("com.example.droid_edge_server/telemetry");

  final Battery _battery;
  final Connectivity _connectivity;
  final MethodChannel _thermalChannel;

  /// Captures a single best-effort [TelemetrySnapshot], tolerating unsupported
  /// platform channels in tests or desktop environments.
  Future<TelemetrySnapshot> readSnapshot() async {
    int? batteryLevel;
    var batteryState = "unknown";
    var networkType = "unknown";
    var thermalStatus = "unknown";
    double? batteryTemperature;

    try {
      batteryLevel = await _battery.batteryLevel;
    } catch (_) {
      // Unavailable on unsupported platforms or headless unit tests.
    }

    try {
      batteryState = mapBatteryState(await _battery.batteryState);
    } catch (_) {}

    try {
      final results = await _connectivity.checkConnectivity();
      networkType = mapConnectivity(results);
    } catch (_) {}

    try {
      final thermal = await _thermalChannel
          .invokeMapMethod<String, dynamic>("getThermalTelemetry");
      if (thermal != null) {
        final rawStatus = thermal["thermalStatus"];
        if (rawStatus is String && rawStatus.isNotEmpty) {
          thermalStatus = rawStatus;
        }
        final rawTemp = thermal["batteryTemperatureC"];
        if (rawTemp is num) {
          batteryTemperature = rawTemp.toDouble();
        }
      }
    } catch (_) {}

    return TelemetrySnapshot(
      batteryLevel: batteryLevel,
      batteryState: batteryState,
      networkType: networkType,
      thermalStatus: thermalStatus,
      batteryTemperatureCelsius: batteryTemperature,
      timestamp: DateTime.now().toUtc(),
    );
  }

  /// Stream of battery state transitions.
  Stream<String> get batteryStateStream =>
      _battery.onBatteryStateChanged.map(mapBatteryState);

  /// Stream of connectivity transport transitions.
  Stream<String> get networkTypeStream =>
      _connectivity.onConnectivityChanged.map(mapConnectivity);

  /// Stream of Android thermal throttling transitions (polled by [TelemetryCubit]).
  Stream<String> get thermalStatusStream => const Stream.empty();

  /// Stream of battery temperature updates (polled by [TelemetryCubit]).
  Stream<double> get batteryTemperatureStream => const Stream.empty();

  static String mapBatteryState(BatteryState state) {
    switch (state) {
      case BatteryState.charging:
        return "charging";
      case BatteryState.discharging:
        return "discharging";
      case BatteryState.full:
        return "full";
      case BatteryState.connectedNotCharging:
        return "connected_not_charging";
      case BatteryState.unknown:
        return "unknown";
    }
  }

  static String mapConnectivity(List<ConnectivityResult> results) {
    if (results.isEmpty || results.contains(ConnectivityResult.none)) {
      if (results.length <= 1) {
        return "none";
      }
    }
    if (results.contains(ConnectivityResult.wifi)) return "wifi";
    if (results.contains(ConnectivityResult.ethernet)) return "ethernet";
    if (results.contains(ConnectivityResult.mobile)) return "mobile";
    if (results.contains(ConnectivityResult.vpn)) return "vpn";
    if (results.contains(ConnectivityResult.bluetooth)) return "bluetooth";
    if (results.contains(ConnectivityResult.other)) return "other";
    return "unknown";
  }
}
