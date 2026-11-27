import "dart:async";
import "dart:io";

import "package:droid_edge_server/blocs/ai_gateway/ai_gateway_cubit.dart";
import "package:droid_edge_server/blocs/ai_gateway/ai_gateway_state.dart";
import "package:droid_edge_server/blocs/server/server_state.dart";
import "package:droid_edge_server/engines/entity_extraction_engine.dart";
import "package:droid_edge_server/engines/litert_lm_engine.dart";
import "package:droid_edge_server/engines/local_genai_engine.dart";
import "package:droid_edge_server/models/openai_vision_models.dart";
import "package:droid_edge_server/ui/dashboard/widgets/ai_gateway_card.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_bloc/flutter_bloc.dart";
import "package:flutter_test/flutter_test.dart";

class _FakeWidgetLiteRtLmEngine implements LiteRtLmEngine {
  String? modelsDirectory = "/sdcard/Android/data/com.example/files/models";
  String? pickedPath;
  PlatformException? pickException;

  @override
  Future<bool> isSupported() async => true;

  @override
  Future<double?> getDeviceRamGb() async => 8.0;

  @override
  Future<String?> getModelsDirectory() async => modelsDirectory;

  @override
  Future<String?> pickModelFile() async {
    if (pickException != null) {
      throw pickException!;
    }
    return pickedPath;
  }

  @override
  Future<String?> runInference({
    required String prompt,
    required String modelPath,
    required bool forceJson,
  }) async =>
      "ok";

  @override
  Future<void> unloadModel() async {}

  @override
  Future<void> cancelInference() async {}

  @override
  Future<void> dispose() async {}
}

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
      expect(find.text("https://192.168.1.42:8080/v1"), findsOneWidget);
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

    testWidgets(
      "supports Tier 3 .litertlm model picking, toggle, clear, and error banner",
      (WidgetTester tester) async {
      Future<void> pumpWithIo({bool Function()? doneWhen}) async {
        for (var i = 0; i < 40; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          if (doneWhen != null && doneWhen()) {
            break;
          }
        }
        await tester.pumpAndSettle();
      }

      final tempDir = Directory.systemTemp.createTempSync("ai_gateway_tier3_");
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      final pickedModel = File("${tempDir.path}/gemma-picked.litertlm")
        ..writeAsBytesSync(List<int>.filled(64, 1));

      final controller = StreamController<OpenAiJobRecord>.broadcast();
      addTearDown(controller.close);

      final fakeLiteRt = _FakeWidgetLiteRtLmEngine()
        ..pickedPath = pickedModel.path;

      final runtime = ThreeTierGenAiRuntime(
        entityExtractionEngine: HybridEntityExtractionEngine(
          enableNativeMlKit: false,
        ),
        liteRtLmEngine: fakeLiteRt,
        tier2StatusChecker: () async => AiFeatureAvailability.unavailable,
      );
      addTearDown(runtime.dispose);

      final cubit = AiGatewayCubit(
        openAiJobs: controller.stream,
        localGenAiEngine: runtime,
      )..start();
      addTearDown(cubit.close);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: BlocProvider.value(
            value: cubit,
            child: Scaffold(
              body: SingleChildScrollView(
                child: BlocBuilder<AiGatewayCubit, AiGatewayState>(
                  builder: (context, state) {
                    return AiGatewayCard(
                      state: state,
                      serverState: const ServerState(
                        status: ServerStatusKind.running,
                        ipAddress: "192.168.1.42",
                        port: 8080,
                      ),
                      onRefreshCapabilities: cubit.refreshCapabilities,
                      onToggleTier2: cubit.toggleTier2,
                      onToggleTier3: cubit.toggleTier3,
                      onPickTier3Model: cubit.pickTier3ModelFile,
                      onSetTier3ModelPath: cubit.setTier3ModelPath,
                      onClearHistory: cubit.clearHistory,
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text("Tier 1 Active"), findsOneWidget);
      expect(find.byKey(const Key("tier3_switch")), findsNothing);
      expect(find.byKey(const Key("tier3_pick_model_btn")), findsOneWidget);
      expect(find.byKey(const Key("tier3_clear_model_btn")), findsNothing);

      // 1. Pick a .litertlm model file -> auto-enables Tier 3.
      await tester.tap(find.byKey(const Key("tier3_pick_model_btn")));
      await tester.pump();
      await pumpWithIo(doneWhen: () => !cubit.state.isSelectingTier3Model);

      expect(cubit.state.capabilities.tier3Enabled, isTrue);
      expect(
        cubit.state.capabilities.tier3ModelPath,
        pickedModel.path,
      );
      expect(find.text("Tier 3 LiteRT-LM"), findsOneWidget);
      expect(find.byKey(const Key("tier3_switch")), findsOneWidget);
      expect(find.byKey(const Key("tier3_clear_model_btn")), findsOneWidget);
      expect(
        find.textContaining("Ready (Enabled) · gemma-picked.litertlm"),
        findsOneWidget,
      );

      // 2. Toggle Tier 3 off via switch.
      await tester.tap(find.byKey(const Key("tier3_switch")));
      await tester.pump();
      await pumpWithIo(
        doneWhen: () => !cubit.state.capabilities.tier3Enabled,
      );
      expect(cubit.state.capabilities.tier3Enabled, isFalse);
      expect(find.text("Tier 1 Active"), findsOneWidget);

      // 3. Clear selected model path.
      await tester.tap(find.byKey(const Key("tier3_clear_model_btn")));
      await tester.pump();
      await pumpWithIo(
        doneWhen: () => cubit.state.capabilities.tier3ModelPath == null,
      );
      expect(cubit.state.capabilities.tier3ModelPath, isNull);
      expect(find.byKey(const Key("tier3_clear_model_btn")), findsNothing);
      expect(find.byKey(const Key("tier3_switch")), findsNothing);

      // 4. Invalid file picker error shows inline error banner.
      fakeLiteRt.pickException = PlatformException(
        code: "INVALID_MODEL_EXTENSION",
        message: "Please select a valid .litertlm model file.",
      );
      await tester.tap(find.byKey(const Key("tier3_pick_model_btn")));
      await tester.pump();
      await pumpWithIo(doneWhen: () => !cubit.state.isSelectingTier3Model);
      expect(
        find.text("Please select a valid .litertlm model file."),
        findsOneWidget,
      );
    },
    );
  });
}
