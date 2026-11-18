import "package:flutter/material.dart";

import "../../../blocs/document_pipeline/document_pipeline_state.dart";
import "../../../models/document_pipeline_models.dart";

/// Material 3 card displaying live statistics and recent jobs from the
/// offline Searchable PDF, PII Redaction, and Batch ZIP pipeline.
class DocumentPipelineCard extends StatelessWidget {
  const DocumentPipelineCard({
    super.key,
    required this.state,
    required this.onClear,
  });

  final DocumentPipelineState state;
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
                  Icons.picture_as_pdf_rounded,
                  color: colorScheme.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "Document & Redaction Pipeline",
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
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    "100% Local",
                    style: textTheme.labelSmall?.copyWith(
                      color: colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (state.recentJobs.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: "Clear document history",
                    onPressed: onClear,
                    icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _PipelineMetricTile(
                  icon: Icons.task_alt_rounded,
                  label: "Jobs",
                  value: "${state.totalJobs} total",
                ),
                _PipelineMetricTile(
                  icon: Icons.description_outlined,
                  label: "Pages OCR'd",
                  value: "${state.totalPagesProcessed} pages",
                ),
                _PipelineMetricTile(
                  icon: Icons.privacy_tip_outlined,
                  label: "PII / Faces",
                  value: "${state.totalRedactionsApplied} masked",
                ),
                const _PipelineMetricTile(
                  icon: Icons.cleaning_services_outlined,
                  label: "EXIF & Metadata",
                  value: "Stripped",
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
                  "Ready for /v1/doc/searchable-pdf, /v1/doc/redact, and /v1/doc/batch-zip.",
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
                    _JobRow(job: state.recentJobs[i]),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _PipelineMetricTile extends StatelessWidget {
  const _PipelineMetricTile({
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
      constraints: const BoxConstraints(minWidth: 140),
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

class _JobRow extends StatelessWidget {
  const _JobRow({required this.job});

  final DocumentJobRecord job;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final badgeColor = switch (job.type) {
      DocumentJobType.searchablePdf => colorScheme.primaryContainer,
      DocumentJobType.piiRedaction => colorScheme.tertiaryContainer,
      DocumentJobType.batchZip => colorScheme.secondaryContainer,
    };
    final badgeFg = switch (job.type) {
      DocumentJobType.searchablePdf => colorScheme.onPrimaryContainer,
      DocumentJobType.piiRedaction => colorScheme.onTertiaryContainer,
      DocumentJobType.batchZip => colorScheme.onSecondaryContainer,
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
              job.type.label,
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
                "${job.pageCount} pg",
                if (job.redactedCount > 0) "${job.redactedCount} masked",
                _formatBytes(job.outputBytes),
              ].join(" • "),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurface,
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

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    return "${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB";
  }
}
