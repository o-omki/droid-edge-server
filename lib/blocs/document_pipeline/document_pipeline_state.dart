import "package:equatable/equatable.dart";

import "../../models/document_pipeline_models.dart";

class DocumentPipelineState extends Equatable {
  const DocumentPipelineState({
    this.totalJobs = 0,
    this.totalPagesProcessed = 0,
    this.totalRedactionsApplied = 0,
    this.totalInputBytes = 0,
    this.totalOutputBytes = 0,
    this.recentJobs = const [],
  });

  final int totalJobs;
  final int totalPagesProcessed;
  final int totalRedactionsApplied;
  final int totalInputBytes;
  final int totalOutputBytes;
  final List<DocumentJobRecord> recentJobs;

  DocumentPipelineState copyWith({
    int? totalJobs,
    int? totalPagesProcessed,
    int? totalRedactionsApplied,
    int? totalInputBytes,
    int? totalOutputBytes,
    List<DocumentJobRecord>? recentJobs,
  }) {
    return DocumentPipelineState(
      totalJobs: totalJobs ?? this.totalJobs,
      totalPagesProcessed: totalPagesProcessed ?? this.totalPagesProcessed,
      totalRedactionsApplied:
          totalRedactionsApplied ?? this.totalRedactionsApplied,
      totalInputBytes: totalInputBytes ?? this.totalInputBytes,
      totalOutputBytes: totalOutputBytes ?? this.totalOutputBytes,
      recentJobs: recentJobs ?? this.recentJobs,
    );
  }

  @override
  List<Object?> get props => [
        totalJobs,
        totalPagesProcessed,
        totalRedactionsApplied,
        totalInputBytes,
        totalOutputBytes,
        recentJobs,
      ];
}
