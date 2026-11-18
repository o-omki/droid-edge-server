import "dart:async";

import "package:droid_edge_server/blocs/document_pipeline/document_pipeline_cubit.dart";
import "package:droid_edge_server/models/document_pipeline_models.dart";
import "package:droid_edge_server/ui/dashboard/widgets/document_pipeline_card.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  group("Phase 5 DocumentPipelineCubit & Material 3 Card", () {
    testWidgets("tracks jobs and renders Material 3 card", (
      WidgetTester tester,
    ) async {
      final controller = StreamController<DocumentJobRecord>.broadcast();
      addTearDown(controller.close);

      final cubit = DocumentPipelineCubit(documentJobs: controller.stream)
        ..start();
      addTearDown(cubit.close);

      controller.add(
        DocumentJobRecord(
          id: "job-1",
          timestamp: DateTime(2026, 11, 17, 10, 30),
          type: DocumentJobType.piiRedaction,
          pageCount: 2,
          inputBytes: 240000,
          outputBytes: 120000,
          redactedCount: 5,
          metadataStripped: true,
          processingMs: 142,
        ),
      );
      await tester.pump();

      expect(cubit.state.totalJobs, 1);
      expect(cubit.state.totalPagesProcessed, 2);
      expect(cubit.state.totalRedactionsApplied, 5);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: DocumentPipelineCard(
              state: cubit.state,
              onClear: cubit.clearHistory,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text("Document & Redaction Pipeline"), findsOneWidget);
      expect(find.text("1 total"), findsOneWidget);
      expect(find.text("2 pages"), findsOneWidget);
      expect(find.text("5 masked"), findsOneWidget);
      expect(find.text("PII Redact"), findsOneWidget);

      await tester.tap(find.byTooltip("Clear document history"));
      await tester.pumpAndSettle();
      expect(cubit.state.totalJobs, 0);
    });
  });
}
