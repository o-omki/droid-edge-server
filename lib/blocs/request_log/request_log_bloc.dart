import "package:flutter_bloc/flutter_bloc.dart";

import "../../models/request_log_entry.dart";
import "../../server/edge_http_server.dart";
import "request_log_event.dart";
import "request_log_state.dart";

class RequestLogBloc extends Bloc<RequestLogEvent, RequestLogState> {
  RequestLogBloc({required this.httpServer}) : super(const RequestLogState()) {
    on<RequestLogStarted>(_onStarted);
    on<RequestLogCleared>(_onCleared);
  }

  static const int maxEntries = 200;
  final EdgeHttpServer httpServer;

  Future<void> _onStarted(
    RequestLogStarted event,
    Emitter<RequestLogState> emit,
  ) async {
    await emit.forEach<RequestLogEntry>(
      httpServer.requestLogs,
      onData: (entry) {
        final updated = [entry, ...state.entries];
        if (updated.length > maxEntries) {
          updated.removeRange(maxEntries, updated.length);
        }
        return state.copyWith(
          entries: updated,
          totalRequests: state.totalRequests + 1,
        );
      },
    );
  }

  void _onCleared(
    RequestLogCleared event,
    Emitter<RequestLogState> emit,
  ) {
    emit(state.copyWith(entries: const [], totalRequests: 0));
  }
}
