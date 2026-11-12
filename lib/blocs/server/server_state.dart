import "package:equatable/equatable.dart";

enum ServerStatusKind { stopped, starting, running, stopping, error }

class ServerState extends Equatable {
  const ServerState({
    this.status = ServerStatusKind.stopped,
    this.ipAddress = "0.0.0.0",
    this.port = 8080,
    this.startedAt,
    this.errorMessage,
  });

  final ServerStatusKind status;
  final String ipAddress;
  final int port;
  final DateTime? startedAt;
  final String? errorMessage;

  bool get isRunning => status == ServerStatusKind.running;
  bool get isBusy =>
      status == ServerStatusKind.starting || status == ServerStatusKind.stopping;

  String get baseUrl => "http://$ipAddress:$port";

  ServerState copyWith({
    ServerStatusKind? status,
    String? ipAddress,
    int? port,
    DateTime? startedAt,
    bool clearStartedAt = false,
    String? errorMessage,
    bool clearError = false,
  }) {
    return ServerState(
      status: status ?? this.status,
      ipAddress: ipAddress ?? this.ipAddress,
      port: port ?? this.port,
      startedAt: clearStartedAt ? null : (startedAt ?? this.startedAt),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }

  @override
  List<Object?> get props => [
        status,
        ipAddress,
        port,
        startedAt,
        errorMessage,
      ];
}

