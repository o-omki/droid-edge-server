import "package:equatable/equatable.dart";

class TelemetrySnapshot extends Equatable {
  const TelemetrySnapshot({
    this.batteryLevel,
    this.batteryState = "unknown",
    this.networkType = "unknown",
    this.thermalStatus = "unknown",
    this.batteryTemperatureCelsius,
    required this.timestamp,
  });

  /// Battery charge percentage from 0 to 100, or `null` if unavailable.
  final int? batteryLevel;

  /// Charging state: `charging`, `discharging`, `full`, `connected_not_charging`,
  /// or `unknown`.
  final String batteryState;

  /// Active transport: `wifi`, `ethernet`, `mobile`, `vpn`, `none`, or `unknown`.
  final String networkType;

  /// Android thermal throttling level: `none`, `light`, `moderate`, `severe`,
  /// `critical`, `emergency`, `shutdown`, or `unknown`.
  final String thermalStatus;

  /// Battery temperature in degrees Celsius, or `null` if unavailable.
  final double? batteryTemperatureCelsius;

  /// UTC timestamp when this snapshot was captured.
  final DateTime timestamp;

  bool get isCharging =>
      batteryState == "charging" || batteryState == "full";

  TelemetrySnapshot copyWith({
    int? batteryLevel,
    bool clearBatteryLevel = false,
    String? batteryState,
    String? networkType,
    String? thermalStatus,
    double? batteryTemperatureCelsius,
    bool clearBatteryTemperature = false,
    DateTime? timestamp,
  }) {
    return TelemetrySnapshot(
      batteryLevel:
          clearBatteryLevel ? null : (batteryLevel ?? this.batteryLevel),
      batteryState: batteryState ?? this.batteryState,
      networkType: networkType ?? this.networkType,
      thermalStatus: thermalStatus ?? this.thermalStatus,
      batteryTemperatureCelsius: clearBatteryTemperature
          ? null
          : (batteryTemperatureCelsius ?? this.batteryTemperatureCelsius),
      timestamp: timestamp ?? this.timestamp,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      "battery_percent": batteryLevel,
      "battery_state": batteryState,
      "is_charging": isCharging,
      "network_type": networkType,
      "thermal_status": thermalStatus,
      "battery_temperature_c": batteryTemperatureCelsius,
      "updated_at": timestamp.toUtc().toIso8601String(),
    };
  }

  @override
  List<Object?> get props => [
        batteryLevel,
        batteryState,
        networkType,
        thermalStatus,
        batteryTemperatureCelsius,
        timestamp,
      ];
}

