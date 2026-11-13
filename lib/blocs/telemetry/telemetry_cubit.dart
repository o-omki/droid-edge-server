import "dart:async";

import "package:flutter_bloc/flutter_bloc.dart";

import "../../services/telemetry_service.dart";
import "telemetry_state.dart";

/// Streams device hardware telemetry (battery, network type, thermal state)
/// for both the Material 3 dashboard and `GET /v1/status`.
class TelemetryCubit extends Cubit<TelemetryState> {
  TelemetryCubit({
    required this.telemetryService,
    this.refreshInterval = const Duration(seconds: 30),
  }) : super(TelemetryState.initial());

  final TelemetryService telemetryService;
  final Duration refreshInterval;

  StreamSubscription<String>? _batteryStateSub;
  StreamSubscription<String>? _networkSub;
  StreamSubscription<String>? _thermalSub;
  StreamSubscription<double>? _tempSub;
  Timer? _pollTimer;

  /// Begins listening to telemetry streams and periodic battery level updates.
  Future<void> start() async {
    await refresh();

    _batteryStateSub ??= telemetryService.batteryStateStream.listen(
      (batteryState) {
        if (isClosed) return;
        emit(
          state.copyWith(
            snapshot: state.snapshot.copyWith(
              batteryState: batteryState,
              timestamp: DateTime.now().toUtc(),
            ),
          ),
        );
      },
      onError: (_) {},
    );

    _networkSub ??= telemetryService.networkTypeStream.listen(
      (networkType) {
        if (isClosed) return;
        emit(
          state.copyWith(
            snapshot: state.snapshot.copyWith(
              networkType: networkType,
              timestamp: DateTime.now().toUtc(),
            ),
          ),
        );
      },
      onError: (_) {},
    );

    _thermalSub ??= telemetryService.thermalStatusStream.listen(
      (thermalStatus) {
        if (isClosed) return;
        emit(
          state.copyWith(
            snapshot: state.snapshot.copyWith(
              thermalStatus: thermalStatus,
              timestamp: DateTime.now().toUtc(),
            ),
          ),
        );
      },
      onError: (_) {},
    );

    _tempSub ??= telemetryService.batteryTemperatureStream.listen(
      (tempCelsius) {
        if (isClosed) return;
        emit(
          state.copyWith(
            snapshot: state.snapshot.copyWith(
              batteryTemperatureCelsius: tempCelsius,
              timestamp: DateTime.now().toUtc(),
            ),
          ),
        );
      },
      onError: (_) {},
    );

    _pollTimer ??= Timer.periodic(refreshInterval, (_) => refresh());
  }

  /// Refreshes all telemetry values from the underlying device sensors.
  Future<void> refresh() async {
    final snapshot = await telemetryService.readSnapshot();
    if (isClosed) return;
    emit(state.copyWith(snapshot: snapshot, isLoading: false));
  }

  @override
  Future<void> close() async {
    _pollTimer?.cancel();
    await _batteryStateSub?.cancel();
    await _networkSub?.cancel();
    await _thermalSub?.cancel();
    await _tempSub?.cancel();
    return super.close();
  }
}
