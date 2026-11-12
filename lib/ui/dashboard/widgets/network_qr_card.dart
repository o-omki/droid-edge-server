import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:pretty_qr_code/pretty_qr_code.dart";

import "../../../blocs/server/server_state.dart";

class NetworkQrCard extends StatelessWidget {
  const NetworkQrCard({
    super.key,
    required this.state,
    required this.onRefreshIp,
  });

  final ServerState state;
  final VoidCallback onRefreshIp;

  Future<void> _copyToClipboard(
    BuildContext context,
    String text,
    String label,
  ) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text("$label copied to clipboard")));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final endpointUrl = state.baseUrl;
    final healthCurl = "curl $endpointUrl/v1/health";

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.wifi_tethering_rounded,
                  color: colorScheme.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "LAN Endpoint & QR",
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: "Refresh Local IP",
                  onPressed: onRefreshIp,
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 112,
                  height: 112,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: colorScheme.outlineVariant),
                  ),
                  child: PrettyQrView.data(
                    data: endpointUrl,
                    decoration: const PrettyQrDecoration(
                      shape: PrettyQrSmoothSymbol(
                        color: Color(0xFF111315),
                        roundFactor: 0.4,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "LOCAL ADDRESS",
                        style: textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: SelectableText(
                          endpointUrl,
                          maxLines: 1,
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontFamily: "monospace",
                            color: state.isRunning
                                ? colorScheme.primary
                                : colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed: () =>
                                _copyToClipboard(context, endpointUrl, "URL"),
                            icon: const Icon(Icons.copy_rounded, size: 16),
                            label: const Text("Copy URL"),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => _copyToClipboard(
                              context,
                              healthCurl,
                              "curl command",
                            ),
                            icon: const Icon(Icons.terminal_rounded, size: 16),
                            label: const Text("Copy curl"),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                healthCurl,
                style: textTheme.bodySmall?.copyWith(
                  fontFamily: "monospace",
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
