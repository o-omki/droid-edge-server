import "dart:async";

import "package:flutter_bloc/flutter_bloc.dart";

import "../../engines/local_genai_engine.dart";
import "../../models/openai_vision_models.dart";
import "ai_gateway_state.dart";

class AiGatewayCubit extends Cubit<AiGatewayState> {
  AiGatewayCubit({
    required this.openAiJobs,
    required this.localGenAiEngine,
  }) : super(const AiGatewayState());

  static const int maxRecentJobs = 20;

  final Stream<OpenAiJobRecord> openAiJobs;
  final LocalGenAiEngine localGenAiEngine;
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
          tableExtractions: state.tableExtractions +
              (job.intent == ExtractionIntent.table ? 1 : 0),
          receiptExtractions: state.receiptExtractions +
              (job.intent == ExtractionIntent.receipt ? 1 : 0),
          vcardExtractions: state.vcardExtractions +
              (job.intent == ExtractionIntent.vcard ? 1 : 0),
          ocrCompletions: state.ocrCompletions +
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
      if (!isClosed) {
        emit(
          state.copyWith(
            capabilities: caps,
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
      emit(state.copyWith(capabilities: caps));
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
