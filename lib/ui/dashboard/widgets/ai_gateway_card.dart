import "package:flutter/material.dart";
import "package:flutter/services.dart";

import "../../../blocs/ai_gateway/ai_gateway_state.dart";
import "../../../blocs/server/server_state.dart";
import "../../../models/openai_vision_models.dart";

class AiGatewayCard extends StatelessWidget {
  const AiGatewayCard({
    super.key,
    required this.state,
    required this.serverState,
    required this.onRefreshCapabilities,
    required this.onToggleTier2,
    required this.onClearHistory,
  });

  final AiGatewayState state;
  final ServerState serverState;
  final VoidCallback onRefreshCapabilities;
  final ValueChanged<bool> onToggleTier2;
  final VoidCallback onClearHistory;

  Future<void> _copyBaseUrl(BuildContext context, String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text("OpenAI Base URL copied to clipboard")),
      );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final caps = state.capabilities;
    final activeTier = caps.activeTier;
    final openAiBaseUrl = "${serverState.baseUrl}/v1";

    final activeTierBadgeLabel = switch (activeTier) {
      AiTier.tier1Deterministic => "Tier 1 Active",
      AiTier.tier2GeminiNano => "Tier 2 AICore",
      AiTier.tier3LiteRtLm => "Tier 3 LiteRT-LM",
    };

    final tier2Label = switch (caps.tier2Status) {
      AiFeatureAvailability.available =>
        caps.tier2Enabled ? "Available (Enabled)" : "Available (Off)",
      AiFeatureAvailability.downloadable => "Downloadable via AICore",
      AiFeatureAvailability.downloading => "Downloading…",
      AiFeatureAvailability.disabled => "Disabled",
      AiFeatureAvailability.unavailable => "Unavailable on Device",
    };

    final tier2CanToggle =
        caps.tier2Status == AiFeatureAvailability.available ||
        caps.tier2Status == AiFeatureAvailability.downloadable;

    final ramNote = caps.deviceRamGb != null
        ? " · ${caps.deviceRamGb!.toStringAsFixed(1)} GB RAM"
        : "";
    final tier3Label = switch (caps.tier3Status) {
      AiFeatureAvailability.available => "Model Loaded$ramNote",
      AiFeatureAvailability.downloadable => "Adapter Ready · Model Missing$ramNote",
      AiFeatureAvailability.downloading => "Downloading…",
      AiFeatureAvailability.disabled => "Disabled",
      AiFeatureAvailability.unavailable => "Opt-in Slot (6 GB+ RAM)$ramNote",
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.hub_rounded,
                  color: colorScheme.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "OpenAI Vision & Structured Extraction",
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    activeTierBadgeLabel,
                    style: textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSecondaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: "Refresh AI capabilities",
                  onPressed: state.isCheckingCapabilities
                      ? null
                      : onRefreshCapabilities,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                ),
                if (state.recentJobs.isNotEmpty)
                  IconButton(
                    tooltip: "Clear AI completion history",
                    onPressed: onClearHistory,
                    icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Text(
                    "BASE URL",
                    style: textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      letterSpacing: 0.7,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      openAiBaseUrl,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        fontFamily: "monospace",
                        fontWeight: FontWeight.w600,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: "Copy OpenAI Base URL",
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _copyBaseUrl(context, openAiBaseUrl),
                    icon: const Icon(Icons.copy_rounded, size: 16),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _TierStatusRow(
              badge: "Tier 1",
              title: "Deterministic Spatial & Entity",
              subtitle: caps.entityModelDownloaded
                  ? "Ready · 100% of Devices (ML Kit Entities + Regex)"
                  : "Ready · 100% of Devices (Zero-Download Rules)",
              isActive: activeTier == AiTier.tier1Deterministic,
            ),
            const SizedBox(height: 8),
            _TierStatusRow(
              badge: "Tier 2",
              title: "Gemini Nano (AICore)",
              subtitle: tier2Label,
              isActive: activeTier == AiTier.tier2GeminiNano,
              trailing: tier2CanToggle
                  ? Switch(
                      value: caps.tier2Enabled,
                      onChanged: onToggleTier2,
                    )
                  : null,
            ),
            const SizedBox(height: 8),
            _TierStatusRow(
              badge: "Tier 3",
              title: "Local LiteRT-LM",
              subtitle: tier3Label,
              isActive: activeTier == AiTier.tier3LiteRtLm,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _AiMetricTile(
                  icon: Icons.auto_awesome_outlined,
                  label: "Completions",
                  value: "${state.totalCompletions} total",
                ),
                _AiMetricTile(
                  icon: Icons.table_chart_outlined,
                  label: "Tables",
                  value: "${state.tableExtractions} md",
                ),
                _AiMetricTile(
                  icon: Icons.receipt_long_outlined,
                  label: "Receipts",
                  value: "${state.receiptExtractions} json",
                ),
                _AiMetricTile(
                  icon: Icons.contact_page_outlined,
                  label: "vCards",
                  value: "${state.vcardExtractions} vcf",
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (state.recentJobs.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  "Ready for /v1/models and /v1/chat/completions (Paperless-GPT, n8n, Obsidian, OpenAI SDKs).",
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              Column(
                children: [
                  for (var i = 0; i < state.recentJobs.length && i < 4; i++) ...[
                    if (i > 0) const SizedBox(height: 8),
                    _OpenAiJobRow(job: state.recentJobs[i]),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _TierStatusRow extends StatelessWidget {
  const _TierStatusRow({
    required this.badge,
    required this.title,
    required this.subtitle,
    required this.isActive,
    this.trailing,
  });

  final String badge;
  final String title;
  final String subtitle;
  final bool isActive;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        border: isActive
            ? Border.all(color: colorScheme.primary.withValues(alpha: 0.45))
            : null,
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isActive
                  ? colorScheme.primaryContainer
                  : colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              badge,
              style: textTheme.labelSmall?.copyWith(
                color: isActive
                    ? colorScheme.onPrimaryContainer
                    : colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
                  style: textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _AiMetricTile extends StatelessWidget {
  const _AiMetricTile({
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
      constraints: const BoxConstraints(minWidth: 132),
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
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OpenAiJobRow extends StatelessWidget {
  const _OpenAiJobRow({required this.job});

  final OpenAiJobRecord job;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final badgeColor = switch (job.intent) {
      ExtractionIntent.table => colorScheme.primaryContainer,
      ExtractionIntent.receipt => colorScheme.tertiaryContainer,
      ExtractionIntent.vcard => colorScheme.secondaryContainer,
      ExtractionIntent.ocr => colorScheme.surfaceContainerHighest,
    };
    final badgeFg = switch (job.intent) {
      ExtractionIntent.table => colorScheme.onPrimaryContainer,
      ExtractionIntent.receipt => colorScheme.onTertiaryContainer,
      ExtractionIntent.vcard => colorScheme.onSecondaryContainer,
      ExtractionIntent.ocr => colorScheme.onSurfaceVariant,
    };

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
              color: badgeColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              job.intent.label,
              style: textTheme.labelSmall?.copyWith(
                color: badgeFg,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              [
                job.requestedModel,
                "${job.completionTokens} tok",
                if (job.fallbackTriggered) "Tier 1 fallback",
              ].join(" • "),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            "${job.processingMs} ms",
            style: textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
