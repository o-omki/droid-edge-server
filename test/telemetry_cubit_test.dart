import "dart:async";

import "package:droid_edge_server/blocs/telemetry/telemetry_cubit.dart";
import "package:droid_edge_server/models/telemetry_snapshot.dart";
import "package:droid_edge_server/services/telemetry_service.dart";
import "package:flutter_test/flutter_test.dart";

class _FakeTelemetryService extends TelemetryService {
  _FakeTelemetryService();

  final batteryController = StreamController<String>.broadcast();
  final networkController = StreamController<String>.broadcast();
  final thermalController = StreamController<String>.broadcast();
  final tempController = StreamController<double>.broadcast();

  TelemetrySnapshot nextSnapshot = TelemetrySnapshot(
    batteryLevel: 76,
    batteryState: "discharging",
    networkType: "wifi",
    thermalStatus: "none",
    batteryTemperatureCelsius: 29.0,
    timestamp: DateTime.utc(2026, 11, 12, 12, 0),
  );

  @override
  Future<TelemetrySnapshot> readSnapshot() async => nextSnapshot;

  @override
  Stream<String> get batteryStateStream => batteryController.stream;

  @override
  Stream<String> get networkTypeStream => networkController.stream;

  @override
  Stream<String> get thermalStatusStream => thermalController.stream;

  @override
  Stream<double> get batteryTemperatureStream => tempController.stream;

  Future<void> dispose() async {
    await batteryController.close();
    await networkController.close();
    await thermalController.close();
    await tempController.close();
  }
}

void main() {
  group("TelemetryCubit", () {
    late _FakeTelemetryService service;
    late TelemetryCubit cubit;

    setUp(() {
      service = _FakeTelemetryService();
      cubit = TelemetryCubit(
        telemetryService: service,
        refreshInterval: const Duration(hours: 1),
      );
    });

    tearDown(() async {
      await cubit.close();
      await service.dispose();
    });

    test("loads initial snapshot and reacts to sensor streams", () async {
      await cubit.start();

      expect(cubit.state.isLoading, isFalse);
      expect(cubit.state.snapshot.batteryLevel, 76);
      expect(cubit.state.snapshot.batteryState, "discharging");
      expect(cubit.state.snapshot.networkType, "wifi");
      expect(cubit.state.snapshot.thermalStatus, "none");
      expect(cubit.state.snapshot.batteryTemperatureCelsius, 29.0);

      service.batteryController.add("charging");
      service.networkController.add("ethernet");
      service.thermalController.add("light");
      service.tempController.add(34.5);

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(cubit.state.snapshot.batteryState, "charging");
      expect(cubit.state.snapshot.isCharging, isTrue);
      expect(cubit.state.snapshot.networkType, "ethernet");
      expect(cubit.state.snapshot.thermalStatus, "light");
      expect(cubit.state.snapshot.batteryTemperatureCelsius, 34.5);
    });
  });
}

