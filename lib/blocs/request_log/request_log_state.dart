import "package:equatable/equatable.dart";

import "../../models/request_log_entry.dart";

class RequestLogState extends Equatable {
  const RequestLogState({
    this.entries = const [],
    this.totalRequests = 0,
  });

  /// Logged entries in reverse chronological order (newest first), capped at 200.
  final List<RequestLogEntry> entries;
  final int totalRequests;

  RequestLogState copyWith({
    List<RequestLogEntry>? entries,
    int? totalRequests,
  }) {
    return RequestLogState(
      entries: entries ?? this.entries,
      totalRequests: totalRequests ?? this.totalRequests,
    );
  }

  @override
  List<Object?> get props => [entries, totalRequests];
}

