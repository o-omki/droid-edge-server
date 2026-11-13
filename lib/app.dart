import "package:dynamic_color/dynamic_color.dart";
import "package:flutter/material.dart";
import "package:flutter_bloc/flutter_bloc.dart";

import "blocs/request_log/request_log_bloc.dart";
import "blocs/request_log/request_log_event.dart";
import "blocs/server/server_bloc.dart";
import "blocs/server/server_event.dart";
import "blocs/telemetry/telemetry_cubit.dart";
import "core/theme/app_theme.dart";
import "server/edge_http_server.dart";
import "services/foreground_service_manager.dart";
import "services/mdns_service.dart";
import "services/network_info_service.dart";
import "services/telemetry_service.dart";
import "ui/dashboard/dashboard_screen.dart";

class DroidEdgeApp extends StatefulWidget {
  const DroidEdgeApp({
    super.key,
    this.httpServer,
    this.networkInfoService,
    this.telemetryService,
    this.foregroundServiceManager,
    this.mdnsService,
  });

  final EdgeHttpServer? httpServer;
  final NetworkInfoService? networkInfoService;
  final TelemetryService? telemetryService;
  final ForegroundServiceManager? foregroundServiceManager;
  final MdnsService? mdnsService;

  @override
  State<DroidEdgeApp> createState() => _DroidEdgeAppState();
}

class _DroidEdgeAppState extends State<DroidEdgeApp> {
  late final TelemetryCubit _telemetryCubit;
  late final EdgeHttpServer _httpServer;
  late final NetworkInfoService _networkInfoService;
  late final ForegroundServiceManager _foregroundServiceManager;
  late final MdnsService _mdnsService;
  late final bool _ownsServer;
  ThemeMode _themeMode = ThemeMode.dark;

  @override
  void initState() {
    super.initState();
    _ownsServer = widget.httpServer == null;
    _telemetryCubit = TelemetryCubit(
      telemetryService: widget.telemetryService ?? TelemetryService(),
    )..start();
    _httpServer = widget.httpServer ??
        EdgeHttpServer(
          telemetryProvider: () => _telemetryCubit.state.snapshot,
        );
    _networkInfoService = widget.networkInfoService ?? NetworkInfoService();
    _foregroundServiceManager =
        widget.foregroundServiceManager ?? ForegroundServiceManager();
    _mdnsService = widget.mdnsService ?? MdnsService();
  }

  @override
  void dispose() {
    _telemetryCubit.close();
    if (_ownsServer) {
      _mdnsService.stop();
      _foregroundServiceManager.stop();
      _httpServer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider.value(value: _telemetryCubit),
        BlocProvider(
          create: (_) => ServerBloc(
            httpServer: _httpServer,
            networkInfoService: _networkInfoService,
            foregroundServiceManager: _foregroundServiceManager,
            mdnsService: _mdnsService,
          )
            ..add(const ServerIpRefreshRequested())
            ..add(const ServerBatteryOptimizationChecked()),
        ),
        BlocProvider(
          create: (_) => RequestLogBloc(httpServer: _httpServer)
            ..add(const RequestLogStarted()),
        ),
      ],
      child: DynamicColorBuilder(
        builder: (lightDynamic, darkDynamic) {
          final lightScheme = lightDynamic != null
              ? ColorScheme.fromSeed(
                  seedColor: lightDynamic.primary,
                  brightness: Brightness.light,
                )
              : null;
          final darkScheme = darkDynamic != null
              ? ColorScheme.fromSeed(
                  seedColor: darkDynamic.primary,
                  brightness: Brightness.dark,
                )
              : null;

          return MaterialApp(
            title: "Droid Edge Server",
            debugShowCheckedModeBanner: false,
            themeMode: _themeMode,
            theme: AppTheme.light(dynamicScheme: lightScheme),
            darkTheme: AppTheme.dark(dynamicScheme: darkScheme),
            home: DashboardScreen(
              themeMode: _themeMode,
              onThemeModeChanged: (mode) => setState(() => _themeMode = mode),
            ),
          );
        },
      ),
    );
  }
}
