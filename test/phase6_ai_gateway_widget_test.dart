import "dart:async";

import "package:droid_edge_server/blocs/ai_gateway/ai_gateway_cubit.dart";
import "package:droid_edge_server/blocs/server/server_state.dart";
import "package:droid_edge_server/engines/entity_extraction_engine.dart";
import "package:droid_edge_server/engines/local_genai_engine.dart";
import "package:droid_edge_server/models/openai_vision_models.dart";
import "package:droid_edge_server/ui/dashboard/widgets/ai_gateway_card.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  group("Phase 6 AiGatewayCubit & Material 3 Card", () {
    testWidgets("tracks completions, tier toggles, and renders Material 3 card", (
      WidgetTester tester,
    ) async {
      final controller = StreamController<OpenAiJobRecord>.broadcast();
      addTearDown(controller.close);

      final runtime = ThreeTierGenAiRuntime(
        entityExtractionEngine: HybridEntityExtractionEngine(
          enableNativeMlKit: false,
        ),
        tier2StatusChecker: () async => AiFeatureAvailability.available,
        deviceRamGbProvider: () async => 8.0,
      );
      addTearDown(runtime.dispose);

      final cubit = AiGatewayCubit(
        openAiJobs: controller.stream,
        localGenAiEngine: runtime,
      )..start();
      addTearDown(cubit.close);

      await tester.pump();
      await tester.pump();

      controller.add(
        OpenAiJobRecord(
          id: "chatcmpl-local-1",
          timestamp: DateTime(2026, 11, 17, 22, 30),
          requestedModel: "gpt-4o",
          effectiveTier: AiTier.tier1Deterministic,
          intent: ExtractionIntent.table,
          imageCount: 1,
          promptPreview: "Extract table as Markdown",
          promptTokens: 262,
          completionTokens: 48,
          processingMs: 36,
        ),
      );
      controller.add(
        OpenAiJobRecord(
          id: "chatcmpl-local-2",
          timestamp: DateTime(2026, 11, 17, 22, 31),
          requestedModel: "local-vcard",
          effectiveTier: AiTier.tier1Deterministic,
          intent: ExtractionIntent.vcard,
          imageCount: 1,
          promptPreview: "Extract business card vCard",
          promptTokens: 260,
          completionTokens: 32,
          processingMs: 24,
          fallbackTriggered: true,
        ),
      );
      await tester.pump();

      expect(cubit.state.totalCompletions, 2);
      expect(cubit.state.tableExtractions, 1);
      expect(cubit.state.vcardExtractions, 1);
      expect(cubit.state.fallbackCount, 1);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: SingleChildScrollView(
              child: AiGatewayCard(
                state: cubit.state,
                serverState: const ServerState(
                  status: ServerStatusKind.running,
                  ipAddress: "192.168.1.42",
                  port: 8080,
                ),
                onRefreshCapabilities: cubit.refreshCapabilities,
                onToggleTier2: cubit.toggleTier2,
                onClearHistory: cubit.clearHistory,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text("OpenAI Vision & Structured Extraction"),
        findsOneWidget,
      );
      expect(find.text("http://192.168.1.42:8080/v1"), findsOneWidget);
      expect(find.text("Tier 1 Active"), findsOneWidget);
      expect(find.text("2 total"), findsOneWidget);
      expect(find.text("Table"), findsOneWidget);
      expect(find.text("vCard"), findsOneWidget);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(cubit.state.capabilities.tier2Enabled, isTrue);

      await tester.tap(find.byTooltip("Clear AI completion history"));
      await tester.pumpAndSettle();
      expect(cubit.state.totalCompletions, 0);
    });
  });
}
