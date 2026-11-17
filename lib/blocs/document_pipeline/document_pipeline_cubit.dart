import "dart:async";

import "package:flutter_bloc/flutter_bloc.dart";

import "../../models/document_pipeline_models.dart";
import "document_pipeline_state.dart";

/// Subscribes to completed document pipeline jobs and maintains aggregate
/// counters and recent history for the dashboard
class DocumentPipelineCubit extends Cubit<DocumentPipelineState> {
  DocumentPipelineCubit({required this.documentJobs})
    : super(const DocumentPipelineState());

  static const int maxRecentJobs = 20;

  final Stream<DocumentJobRecord> documentJobs;
  StreamSubscription<DocumentJobRecord>? _subscription;

  void start() {
    _subscription ??= documentJobs.listen((job) {
      if (isClosed) return;
      final updated = [job, ...state.recentJobs];
      if (updated.length > maxRecentJobs) {
        updated.removeRange(maxRecentJobs, updated.length);
      }
      emit(
        state.copyWith(
          totalJobs: state.totalJobs + 1,
          totalPagesProcessed: state.totalPagesProcessed + job.pageCount,
          totalRedactionsApplied:
              state.totalRedactionsApplied + job.redactedCount,
          totalInputBytes: state.totalInputBytes + job.inputBytes,
          totalOutputBytes: state.totalOutputBytes + job.outputBytes,
          recentJobs: updated,
        ),
      );
    }, onError: (_) {});
  }

  void clearHistory() {
    emit(const DocumentPipelineState());
  }

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    return super.close();
  }
}
