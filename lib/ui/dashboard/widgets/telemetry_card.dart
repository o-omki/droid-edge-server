import "package:flutter/material.dart";

import "../../../blocs/server/server_state.dart";
import "../../../blocs/telemetry/telemetry_state.dart";

class TelemetryCard extends StatelessWidget {
  const TelemetryCard({
    super.key,
    required this.telemetryState,
    required this.serverState,
    required this.onRefreshTelemetry,
    required this.onRequestBatteryOptimization,
  });

  final TelemetryState telemetryState;
  final ServerState serverState;
  final VoidCallback onRefreshTelemetry;
  final VoidCallback onRequestBatteryOptimization;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final snapshot = telemetryState.snapshot;

    final batteryText = snapshot.batteryLevel != null
        ? "${snapshot.batteryLevel}% (${snapshot.batteryState})"
        : snapshot.batteryState;

    final tempText = snapshot.batteryTemperatureCelsius != null
        ? "${snapshot.batteryTemperatureCelsius!.toStringAsFixed(1)} °C"
        : "—";

    final thermalText =
        "${snapshot.thermalStatus.toUpperCase()} • $tempText";

    final mdnsText = serverState.mdnsActive
        ? "${serverState.mdnsHostname} (active)"
        : "${serverState.mdnsHostname} (idle)";

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.monitor_heart_rounded,
                  color: colorScheme.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "Device Telemetry & Discovery",
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: "Refresh Telemetry",
                  onPressed: onRefreshTelemetry,
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _TelemetryTile(
                  icon: snapshot.isCharging
                      ? Icons.battery_charging_full_rounded
                      : Icons.battery_std_rounded,
                  label: "Battery",
                  value: batteryText,
                ),
                _TelemetryTile(
                  icon: Icons.lan_rounded,
                  label: "Network",
                  value: snapshot.networkType.toUpperCase(),
                ),
                _TelemetryTile(
                  icon: Icons.thermostat_rounded,
                  label: "Thermal",
                  value: thermalText,
                ),
                _TelemetryTile(
                  icon: Icons.dns_rounded,
                  label: "mDNS Host",
                  value: mdnsText,
                ),
              ],
            ),
            if (!serverState.batteryOptimizationIgnored) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.battery_alert_rounded,
                      color: colorScheme.onTertiaryContainer,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        "Battery optimisation is active and may pause the server when the screen locks.",
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.onTertiaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: onRequestBatteryOptimization,
                      child: const Text("Allow"),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TelemetryTile extends StatelessWidget {
  const _TelemetryTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      constraints: const BoxConstraints(minWidth: 150),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: colorScheme.primary),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                value,
                style: textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

