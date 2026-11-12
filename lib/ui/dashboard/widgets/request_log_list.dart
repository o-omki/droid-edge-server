import "package:flutter/material.dart";

import "../../../blocs/request_log/request_log_state.dart";
import "../../../models/request_log_entry.dart";

class RequestLogList extends StatelessWidget {
  const RequestLogList({super.key, required this.state, required this.onClear});

  final RequestLogState state;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.receipt_long_rounded,
                  color: colorScheme.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  "Live Request Log",
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    "${state.totalRequests}",
                    style: textTheme.labelSmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Spacer(),
                if (state.entries.isNotEmpty)
                  TextButton.icon(
                    onPressed: onClear,
                    icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                    label: const Text("Clear"),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (state.entries.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 32,
                ),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    Icon(
                      Icons.sensors_rounded,
                      size: 36,
                      color: colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.6,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      "Waiting for HTTP requests",
                      style: textTheme.titleSmall?.copyWith(
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Start the server and hit /v1/health from any LAN device.",
                      textAlign: TextAlign.center,
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 380),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: state.entries.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    return _RequestLogTile(entry: state.entries[index]);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RequestLogTile extends StatelessWidget {
  const _RequestLogTile({required this.entry});

  final RequestLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final (statusBg, statusFg) = _statusColors(colorScheme, entry.statusCode);
    final time = _formatTime(entry.timestamp);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              entry.method,
              style: textTheme.labelSmall?.copyWith(
                color: colorScheme.onSecondaryContainer,
                fontWeight: FontWeight.w700,
                fontFamily: "monospace",
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyMedium?.copyWith(
                    fontFamily: "monospace",
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    time,
                    if (entry.remoteIp != null) entry.remoteIp!,
                  ].join(" • "),
                  style: textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: statusBg,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  "${entry.statusCode}",
                  style: textTheme.labelSmall?.copyWith(
                    color: statusFg,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                "${entry.latencyMs} ms",
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  (Color, Color) _statusColors(ColorScheme scheme, int statusCode) {
    if (statusCode >= 200 && statusCode < 300) {
      return (scheme.primaryContainer, scheme.onPrimaryContainer);
    }
    if (statusCode >= 400 && statusCode < 500) {
      return (scheme.tertiaryContainer, scheme.onTertiaryContainer);
    }
    if (statusCode >= 500) {
      return (scheme.errorContainer, scheme.onErrorContainer);
    }
    return (scheme.surfaceContainerHighest, scheme.onSurfaceVariant);
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, "0");
    final m = dt.minute.toString().padLeft(2, "0");
    final s = dt.second.toString().padLeft(2, "0");
    return "$h:$m:$s";
  }
}
