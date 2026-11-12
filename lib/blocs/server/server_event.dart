import "package:equatable/equatable.dart";

sealed class ServerEvent extends Equatable {
  const ServerEvent();

  @override
  List<Object?> get props => [];
}

/// Starts the embedded HTTP server on [port].
final class ServerStartRequested extends ServerEvent {
  const ServerStartRequested({this.port = 8080});

  final int port;

  @override
  List<Object?> get props => [port];
}

/// Stops the embedded HTTP server.
final class ServerStopRequested extends ServerEvent {
  const ServerStopRequested();
}

/// Refreshes the device's local Wi-Fi or LAN IP address.
final class ServerIpRefreshRequested extends ServerEvent {
  const ServerIpRefreshRequested();
}

