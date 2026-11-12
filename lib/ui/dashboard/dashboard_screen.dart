import "package:flutter/material.dart";
import "package:flutter_bloc/flutter_bloc.dart";

import "../../blocs/request_log/request_log_bloc.dart";
import "../../blocs/request_log/request_log_event.dart";
import "../../blocs/request_log/request_log_state.dart";
import "../../blocs/server/server_bloc.dart";
import "../../blocs/server/server_event.dart";
import "../../blocs/server/server_state.dart";
import "widgets/network_qr_card.dart";
import "widgets/request_log_list.dart";
import "widgets/server_control_card.dart";

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Droid Edge Server"),
        actions: [
          PopupMenuButton<ThemeMode>(
            tooltip: "Theme mode",
            initialValue: themeMode,
            icon: Icon(switch (themeMode) {
              ThemeMode.system => Icons.brightness_auto_rounded,
              ThemeMode.light => Icons.light_mode_rounded,
              ThemeMode.dark => Icons.dark_mode_rounded,
            }),
            onSelected: onThemeModeChanged,
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: ThemeMode.system,
                child: ListTile(
                  leading: Icon(Icons.brightness_auto_rounded),
                  title: Text("System"),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: ThemeMode.light,
                child: ListTile(
                  leading: Icon(Icons.light_mode_rounded),
                  title: Text("Light"),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: ThemeMode.dark,
                child: ListTile(
                  leading: Icon(Icons.dark_mode_rounded),
                  title: Text("Dark"),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                BlocBuilder<ServerBloc, ServerState>(
                  builder: (context, serverState) {
                    return Column(
                      children: [
                        ServerControlCard(
                          state: serverState,
                          onToggle: () {
                            final bloc = context.read<ServerBloc>();
                            if (serverState.isRunning) {
                              bloc.add(const ServerStopRequested());
                            } else {
                              bloc.add(
                                ServerStartRequested(port: serverState.port),
                              );
                            }
                          },
                        ),
                        const SizedBox(height: 16),
                        NetworkQrCard(
                          state: serverState,
                          onRefreshIp: () => context.read<ServerBloc>().add(
                            const ServerIpRefreshRequested(),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                BlocBuilder<RequestLogBloc, RequestLogState>(
                  builder: (context, logState) {
                    return RequestLogList(
                      state: logState,
                      onClear: () => context.read<RequestLogBloc>().add(
                        const RequestLogCleared(),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
