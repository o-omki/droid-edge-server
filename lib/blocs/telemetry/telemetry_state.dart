import "package:equatable/equatable.dart";

import "../../models/telemetry_snapshot.dart";

class TelemetryState extends Equatable {
  const TelemetryState({
    required this.snapshot,
    this.isLoading = false,
  });

  factory TelemetryState.initial() => TelemetryState(
        snapshot: TelemetrySnapshot(timestamp: DateTime.now().toUtc()),
        isLoading: true,
      );

  final TelemetrySnapshot snapshot;
  final bool isLoading;

  TelemetryState copyWith({
    TelemetrySnapshot? snapshot,
    bool? isLoading,
  }) {
    return TelemetryState(
      snapshot: snapshot ?? this.snapshot,
      isLoading: isLoading ?? this.isLoading,
    );
  }

  @override
  List<Object?> get props => [snapshot, isLoading];
}

