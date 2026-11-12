import "package:flutter_bloc/flutter_bloc.dart";

import "../../server/edge_http_server.dart";
import "../../services/network_info_service.dart";
import "server_event.dart";
import "server_state.dart";

class ServerBloc extends Bloc<ServerEvent, ServerState> {
  ServerBloc({
    required this.httpServer,
    required this.networkInfoService,
  }) : super(const ServerState()) {
    on<ServerStartRequested>(_onStartRequested);
    on<ServerStopRequested>(_onStopRequested);
    on<ServerIpRefreshRequested>(_onIpRefreshRequested);
  }

  final EdgeHttpServer httpServer;
  final NetworkInfoService networkInfoService;

  Future<void> _onStartRequested(
    ServerStartRequested event,
    Emitter<ServerState> emit,
  ) async {
    if (state.isRunning || state.isBusy) return;

    emit(
      state.copyWith(
        status: ServerStatusKind.starting,
        port: event.port,
        clearError: true,
      ),
    );

    try {
      final ip = await networkInfoService.getLocalIpAddress();
      final boundPort = await httpServer.start(port: event.port);
      emit(
        state.copyWith(
          status: ServerStatusKind.running,
          ipAddress: ip,
          port: boundPort,
          startedAt: httpServer.startedAt ?? DateTime.now(),
          clearError: true,
        ),
      );
    } catch (error) {
      emit(
        state.copyWith(
          status: ServerStatusKind.error,
          clearStartedAt: true,
          errorMessage: "Failed to start server on port ${event.port}: $error",
        ),
      );
    }
  }

  Future<void> _onStopRequested(
    ServerStopRequested event,
    Emitter<ServerState> emit,
  ) async {
    if (!state.isRunning && state.status != ServerStatusKind.error) return;

    emit(state.copyWith(status: ServerStatusKind.stopping, clearError: true));
    try {
      await httpServer.stop();
      emit(
        state.copyWith(
          status: ServerStatusKind.stopped,
          clearStartedAt: true,
          clearError: true,
        ),
      );
    } catch (error) {
      emit(
        state.copyWith(
          status: ServerStatusKind.error,
          errorMessage: "Failed to stop server: $error",
        ),
      );
    }
  }

  Future<void> _onIpRefreshRequested(
    ServerIpRefreshRequested event,
    Emitter<ServerState> emit,
  ) async {
    final ip = await networkInfoService.getLocalIpAddress();
    emit(state.copyWith(ipAddress: ip));
  }
}
