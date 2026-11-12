import "dart:async";

import "package:flutter/material.dart";

import "../../../blocs/server/server_state.dart";

class ServerControlCard extends StatefulWidget {
  const ServerControlCard({
    super.key,
    required this.state,
    required this.onToggle,
  });

  final ServerState state;
  final VoidCallback onToggle;

  @override
  State<ServerControlCard> createState() => _ServerControlCardState();
}

class _ServerControlCardState extends State<ServerControlCard> {
  Timer? _uptimeTimer;
  Duration _uptime = Duration.zero;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant ServerControlCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.status != widget.state.status ||
        oldWidget.state.startedAt != widget.state.startedAt) {
      _syncTimer();
    }
  }

  @override
  void dispose() {
    _uptimeTimer?.cancel();
    super.dispose();
  }

  void _syncTimer() {
    _uptimeTimer?.cancel();
    if (widget.state.isRunning && widget.state.startedAt != null) {
      _updateUptime();
      _uptimeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) _updateUptime();
      });
    } else {
      _uptime = Duration.zero;
    }
  }

  void _updateUptime() {
    final started = widget.state.startedAt;
    if (started == null) return;
    setState(() {
      _uptime = DateTime.now().difference(started);
    });
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours.toString().padLeft(2, "0");
    final mins = (d.inMinutes % 60).toString().padLeft(2, "0");
    final secs = (d.inSeconds % 60).toString().padLeft(2, "0");
    return "$hours:$mins:$secs";
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isRunning = widget.state.isRunning;
    final isBusy = widget.state.isBusy;
    final hasError = widget.state.status == ServerStatusKind.error;

    final (statusLabel, badgeBg, badgeFg, icon) = switch (widget.state.status) {
      ServerStatusKind.running => (
          "Running",
          colorScheme.primaryContainer,
          colorScheme.onPrimaryContainer,
          Icons.podcasts_rounded,
        ),
      ServerStatusKind.starting => (
          "Starting...",
          colorScheme.secondaryContainer,
          colorScheme.onSecondaryContainer,
          Icons.hourglass_top_rounded,
        ),
      ServerStatusKind.stopping => (
          "Stopping...",
          colorScheme.secondaryContainer,
          colorScheme.onSecondaryContainer,
          Icons.hourglass_bottom_rounded,
        ),
      ServerStatusKind.error => (
          "Error",
          colorScheme.errorContainer,
          colorScheme.onErrorContainer,
          Icons.error_outline_rounded,
        ),
      ServerStatusKind.stopped => (
          "Stopped",
          colorScheme.surfaceContainerHighest,
          colorScheme.onSurfaceVariant,
          Icons.power_settings_new_rounded,
        ),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: badgeBg,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: badgeFg, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Edge HTTP Server",
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: badgeBg,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              statusLabel,
                              style: textTheme.labelSmall?.copyWith(
                                color: badgeFg,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            "Port ${widget.state.port}",
                            style: textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (hasError && widget.state.errorMessage != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  widget.state.errorMessage!,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.timer_outlined,
                          size: 16,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          "Uptime: ${_formatDuration(_uptime)}",
                          style: textTheme.labelMedium?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: isBusy ? null : widget.onToggle,
                  style: isRunning
                      ? FilledButton.styleFrom(
                          backgroundColor: colorScheme.error,
                          foregroundColor: colorScheme.onError,
                        )
                      : null,
                  icon: Icon(
                    isRunning ? Icons.stop_rounded : Icons.play_arrow_rounded,
                  ),
                  label: Text(isRunning ? "Stop Server" : "Start Server"),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

