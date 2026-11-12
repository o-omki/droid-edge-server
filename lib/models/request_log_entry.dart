import "package:equatable/equatable.dart";

/// Immutable record of an HTTP request handled by the edge server.
class RequestLogEntry extends Equatable {
  const RequestLogEntry({
    required this.id,
    required this.timestamp,
    required this.method,
    required this.path,
    required this.statusCode,
    required this.latencyMs,
    this.remoteIp,
  });

  final String id;
  final DateTime timestamp;
  final String method;
  final String path;
  final int statusCode;
  final int latencyMs;
  final String? remoteIp;

  @override
  List<Object?> get props => [
        id,
        timestamp,
        method,
        path,
        statusCode,
        latencyMs,
        remoteIp,
      ];
}

