import "dart:io";

import "package:flutter_foreground_task/flutter_foreground_task.dart";

@pragma("vm:entry-point")
void startForegroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveTaskHandler());
}

class _KeepAliveTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Manages the Android foreground service, CPU wake-lock, Wi-Fi lock, and
/// battery-optimisation exemption so the HTTP server survives screen lock.
class ForegroundServiceManager {
  bool _initialized = false;

  bool get isSupported => Platform.isAndroid;

  Future<void> initialize() async {
    if (!isSupported || _initialized) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: "droid_edge_server_service",
        channelName: "Droid Edge Server",
        channelDescription:
            "Keeps the local offline HTTP server active in the background.",
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _initialized = true;
  }

  Future<void> start({
    required String ipAddress,
    required int port,
    String hostname = "android-edge.local",
  }) async {
    if (!isSupported) return;
    await initialize();

    final permission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    final title = "Edge Server Running (:$port)";
    final body = "http://$ipAddress:$port • http://$hostname:$port";

    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: body,
      );
      return;
    }

    await FlutterForegroundTask.startService(
      serviceId: 2048,
      serviceTypes: const [ForegroundServiceTypes.dataSync],
      notificationTitle: title,
      notificationText: body,
      callback: startForegroundTaskCallback,
    );
  }

  Future<void> stop() async {
    if (!isSupported) return;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }

  /// Returns `true` if the app is exempt from Android Doze/battery limits,
  /// or `true` on non-Android platforms.
  Future<bool> isIgnoringBatteryOptimizations() async {
    if (!isSupported) return true;
    try {
      return await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestIgnoreBatteryOptimization() async {
    if (!isSupported) return true;
    try {
      return await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    } catch (_) {
      return false;
    }
  }
}

