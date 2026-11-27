import "package:equatable/equatable.dart";

enum ServerStatusKind { stopped, starting, running, stopping, error }

class ServerState extends Equatable {
  const ServerState({
    this.status = ServerStatusKind.stopped,
    this.ipAddress = "0.0.0.0",
    this.port = 8080,
    this.startedAt,
    this.errorMessage,
    this.mdnsHostname = "android-edge.local",
    this.mdnsActive = false,
    this.batteryOptimizationIgnored = true,
    this.tlsEnabled = true,
    this.pairingToken = "",
    this.caFingerprintSha256 = "",
    this.caCertPem = "",
  });

  final ServerStatusKind status;
  final String ipAddress;
  final int port;
  final DateTime? startedAt;
  final String? errorMessage;
  final String mdnsHostname;
  final bool mdnsActive;
  final bool batteryOptimizationIgnored;
  final bool tlsEnabled;
  final String pairingToken;
  final String caFingerprintSha256;
  final String caCertPem;

  bool get isRunning => status == ServerStatusKind.running;
  bool get isBusy =>
      status == ServerStatusKind.starting || status == ServerStatusKind.stopping;

  String get scheme => tlsEnabled ? "https" : "http";
  String get baseUrl => "$scheme://$ipAddress:$port";
  String get mdnsUrl => "$scheme://$mdnsHostname:$port";

  ServerState copyWith({
    ServerStatusKind? status,
    String? ipAddress,
    int? port,
    DateTime? startedAt,
    bool clearStartedAt = false,
    String? errorMessage,
    bool clearError = false,
    String? mdnsHostname,
    bool? mdnsActive,
    bool? batteryOptimizationIgnored,
    bool? tlsEnabled,
    String? pairingToken,
    String? caFingerprintSha256,
    String? caCertPem,
  }) {
    return ServerState(
      status: status ?? this.status,
      ipAddress: ipAddress ?? this.ipAddress,
      port: port ?? this.port,
      startedAt: clearStartedAt ? null : (startedAt ?? this.startedAt),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      mdnsHostname: mdnsHostname ?? this.mdnsHostname,
      mdnsActive: mdnsActive ?? this.mdnsActive,
      batteryOptimizationIgnored:
          batteryOptimizationIgnored ?? this.batteryOptimizationIgnored,
      tlsEnabled: tlsEnabled ?? this.tlsEnabled,
      pairingToken: pairingToken ?? this.pairingToken,
      caFingerprintSha256:
          caFingerprintSha256 ?? this.caFingerprintSha256,
      caCertPem: caCertPem ?? this.caCertPem,
    );
  }

  @override
  List<Object?> get props => [
        status,
        ipAddress,
        port,
        startedAt,
        errorMessage,
        mdnsHostname,
        mdnsActive,
        batteryOptimizationIgnored,
        tlsEnabled,
        pairingToken,
        caFingerprintSha256,
        caCertPem,
      ];
}

