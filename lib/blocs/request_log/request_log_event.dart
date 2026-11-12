import "package:equatable/equatable.dart";

sealed class RequestLogEvent extends Equatable {
  const RequestLogEvent();

  @override
  List<Object?> get props => [];
}

/// Subscribes to the live HTTP request log stream.
final class RequestLogStarted extends RequestLogEvent {
  const RequestLogStarted();
}

/// Clears all logged requests from the dashboard.
final class RequestLogCleared extends RequestLogEvent {
  const RequestLogCleared();
}

