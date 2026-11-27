import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:pretty_qr_code/pretty_qr_code.dart";

import "../../../blocs/server/server_state.dart";

class NetworkQrCard extends StatefulWidget {
  const NetworkQrCard({
    super.key,
    required this.state,
    required this.onRefreshIp,
    this.onRotateToken,
    this.onExportCaCert,
  });

  final ServerState state;
  final VoidCallback onRefreshIp;
  final VoidCallback? onRotateToken;
  final Future<void> Function()? onExportCaCert;

  @override
  State<NetworkQrCard> createState() => _NetworkQrCardState();
}

class _NetworkQrCardState extends State<NetworkQrCard> {
  bool _showToken = false;
  bool _exportingCa = false;

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

  Future<void> _confirmRotateToken(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Rotate Pairing Token?"),
        content: const Text(
          "Existing paired browsers and scripts will need the new Bearer "
          "token immediately.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text("Cancel"),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text("Rotate"),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      widget.onRotateToken?.call();
    }
  }

  Future<void> _handleExportCa(BuildContext context) async {
    final exporter = widget.onExportCaCert;
    if (exporter == null || _exportingCa) return;
    setState(() => _exportingCa = true);
    try {
      await exporter();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text("Failed to export CA certificate: $error")),
        );
    } finally {
      if (mounted) {
        setState(() => _exportingCa = false);
      }
    }
  }

  String _maskedToken(String token) {
    if (token.isEmpty) return "Initialising…";
    if (_showToken) return token;
    if (token.length <= 12) return "••••••••";
    return "${token.substring(0, 8)}••••••••${token.substring(token.length - 4)}";
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final endpointUrl = state.baseUrl;
    final token = state.pairingToken;
    final visibleToken = token.isEmpty ? "<TOKEN>" : _maskedToken(token);
    final rawCurl = state.tlsEnabled
        ? "curl --cacert droid-edge-ca.crt "
              "-H \"Authorization: Bearer ${token.isEmpty ? "<TOKEN>" : token}\" "
              "${state.mdnsUrl}/v1/status"
        : "curl -H \"Authorization: Bearer ${token.isEmpty ? "<TOKEN>" : token}\" "
              "${state.mdnsUrl}/v1/status";
    final previewCurl = state.tlsEnabled
        ? "curl --cacert droid-edge-ca.crt "
              "-H \"Authorization: Bearer $visibleToken\" "
              "${state.mdnsUrl}/v1/status"
        : "curl -H \"Authorization: Bearer $visibleToken\" "
              "${state.mdnsUrl}/v1/status";

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  state.tlsEnabled
                      ? Icons.verified_user_rounded
                      : Icons.wifi_tethering_rounded,
                  color: colorScheme.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "LAN Endpoint & Pairing",
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (state.tlsEnabled)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      "HTTPS (Local CA)",
                      style: textTheme.labelSmall?.copyWith(
                        color: colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                IconButton(
                  tooltip: "Refresh Local IP",
                  onPressed: widget.onRefreshIp,
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
                              rawCurl,
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
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.key_rounded,
                        size: 16,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        "PAIRING TOKEN (BEARER)",
                        style: textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: _showToken ? "Hide token" : "Reveal token",
                        visualDensity: VisualDensity.compact,
                        onPressed: token.isEmpty
                            ? null
                            : () => setState(() => _showToken = !_showToken),
                        icon: Icon(
                          _showToken
                              ? Icons.visibility_off_rounded
                              : Icons.visibility_rounded,
                          size: 18,
                        ),
                      ),
                    ],
                  ),
                  SelectableText(
                    _maskedToken(token),
                    style: textTheme.bodyMedium?.copyWith(
                      fontFamily: "monospace",
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: token.isEmpty
                            ? null
                            : () => _copyToClipboard(
                                context,
                                token,
                                "Pairing token",
                              ),
                        icon: const Icon(Icons.copy_rounded, size: 16),
                        label: const Text("Copy Token"),
                      ),
                      OutlinedButton.icon(
                        onPressed: widget.onRotateToken == null
                            ? null
                            : () => _confirmRotateToken(context),
                        icon: const Icon(Icons.autorenew_rounded, size: 16),
                        label: const Text("Rotate Token"),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (state.tlsEnabled && state.caFingerprintSha256.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "LOCAL ROOT CA SHA-256 FINGERPRINT",
                      style: textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      state.caFingerprintSha256,
                      style: textTheme.bodySmall?.copyWith(
                        fontFamily: "monospace",
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed:
                              _exportingCa || widget.onExportCaCert == null
                              ? null
                              : () => _handleExportCa(context),
                          icon: const Icon(Icons.download_rounded, size: 16),
                          label: Text(
                            _exportingCa ? "Exporting…" : "Export CA (.crt)",
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: state.caCertPem.isEmpty
                              ? null
                              : () => _copyToClipboard(
                                  context,
                                  state.caCertPem,
                                  "CA certificate PEM",
                                ),
                          icon: const Icon(
                            Icons.content_copy_rounded,
                            size: 16,
                          ),
                          label: const Text("Copy CA PEM"),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                previewCurl,
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
