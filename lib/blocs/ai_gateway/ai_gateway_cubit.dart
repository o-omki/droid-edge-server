import "dart:async";

import "package:flutter/services.dart";
import "package:flutter_bloc/flutter_bloc.dart";

import "../../engines/local_genai_engine.dart";
import "../../models/openai_vision_models.dart";
import "ai_gateway_state.dart";

class AiGatewayCubit extends Cubit<AiGatewayState> {
  AiGatewayCubit({
    required this.openAiJobs,
    required this.localGenAiEngine,
    Future<String?> Function()? tier3ModelFilePicker,
  }) : _tier3ModelFilePicker =
           tier3ModelFilePicker ?? localGenAiEngine.pickTier3ModelFile,
       super(const AiGatewayState());

  static const int maxRecentJobs = 20;

  final Stream<OpenAiJobRecord> openAiJobs;
  final LocalGenAiEngine localGenAiEngine;
  final Future<String?> Function() _tier3ModelFilePicker;
  StreamSubscription<OpenAiJobRecord>? _subscription;

  void start() {
    _subscription ??= openAiJobs.listen((job) {
      if (isClosed) return;
      final updated = [job, ...state.recentJobs];
      if (updated.length > maxRecentJobs) {
        updated.removeRange(maxRecentJobs, updated.length);
      }

      emit(
        state.copyWith(
          totalCompletions: state.totalCompletions + 1,
          tableExtractions:
              state.tableExtractions +
              (job.intent == ExtractionIntent.table ? 1 : 0),
          receiptExtractions:
              state.receiptExtractions +
              (job.intent == ExtractionIntent.receipt ? 1 : 0),
          vcardExtractions:
              state.vcardExtractions +
              (job.intent == ExtractionIntent.vcard ? 1 : 0),
          ocrCompletions:
              state.ocrCompletions +
              (job.intent == ExtractionIntent.ocr ? 1 : 0),
          fallbackCount: state.fallbackCount + (job.fallbackTriggered ? 1 : 0),
          recentJobs: updated,
        ),
      );
    }, onError: (_) {});

    unawaited(refreshCapabilities());
  }

  Future<void> refreshCapabilities() async {
    if (isClosed) return;
    emit(state.copyWith(isCheckingCapabilities: true));
    try {
      final caps = await localGenAiEngine.checkCapabilities();
      String? modelsDir;
      try {
        modelsDir = await localGenAiEngine.getTier3ModelsDirectory();
      } catch (_) {}
      if (!isClosed) {
        emit(
          state.copyWith(
            capabilities: caps,
            tier3ModelsDirectory: modelsDir ?? state.tier3ModelsDirectory,
            isCheckingCapabilities: false,
          ),
        );
      }
    } catch (_) {
      if (!isClosed) {
        emit(state.copyWith(isCheckingCapabilities: false));
      }
    }
  }

  Future<void> toggleTier2(bool enabled) async {
    if (isClosed) return;
    final caps = await localGenAiEngine.checkCapabilities(
      tier2Enabled: enabled,
    );
    if (!isClosed) {
      emit(state.copyWith(capabilities: caps));
    }
  }

  Future<void> toggleTier3(bool enabled, {String? modelPath}) async {
    if (isClosed) return;
    final caps = await localGenAiEngine.checkCapabilities(
      tier3Enabled: enabled,
      tier3ModelPath: modelPath,
    );
    if (!isClosed) {
      emit(state.copyWith(capabilities: caps, clearTier3Error: true));
    }
  }

  /// Updates the Tier 3 `.litertlm` model path, clears Tier 3 when empty, or
  /// automatically enables Tier 3 once the selected file probes as available.
  Future<void> setTier3ModelPath(String? modelPath) async {
    if (isClosed) return;
    final trimmed = modelPath?.trim() ?? "";
    if (trimmed.isEmpty) {
      final caps = await localGenAiEngine.checkCapabilities(
        tier3Enabled: false,
        tier3ModelPath: "",
      );
      if (!isClosed) {
        emit(state.copyWith(capabilities: caps, clearTier3Error: true));
      }
      return;
    }

    var caps = await localGenAiEngine.checkCapabilities(
      tier3ModelPath: trimmed,
    );
    if (caps.tier3Status == AiFeatureAvailability.available &&
        !caps.tier3Enabled) {
      caps = await localGenAiEngine.checkCapabilities(tier3Enabled: true);
    }
    if (!isClosed) {
      emit(state.copyWith(capabilities: caps, clearTier3Error: true));
    }
  }

  /// Launches the local `.litertlm` document picker and binds the chosen path.
  Future<void> pickTier3ModelFile() async {
    if (isClosed || state.isSelectingTier3Model) return;
    emit(state.copyWith(isSelectingTier3Model: true, clearTier3Error: true));
    try {
      final pickedPath = await _tier3ModelFilePicker();
      if (pickedPath != null && pickedPath.trim().isNotEmpty) {
        await setTier3ModelPath(pickedPath);
      }
    } on PlatformException catch (error) {
      if (!isClosed) {
        emit(
          state.copyWith(
            tier3ErrorMessage:
                error.message ?? "Failed to select .litertlm model file.",
          ),
        );
      }
    } catch (_) {
      if (!isClosed) {
        emit(
          state.copyWith(
            tier3ErrorMessage: "Failed to select .litertlm model file.",
          ),
        );
      }
    } finally {
      if (!isClosed) {
        emit(state.copyWith(isSelectingTier3Model: false));
      }
    }
  }

  void clearHistory() {
    emit(
      state.copyWith(
        totalCompletions: 0,
        tableExtractions: 0,
        receiptExtractions: 0,
        vcardExtractions: 0,
        ocrCompletions: 0,
        fallbackCount: 0,
        recentJobs: const [],
      ),
    );
  }

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    return super.close();
  }
}
