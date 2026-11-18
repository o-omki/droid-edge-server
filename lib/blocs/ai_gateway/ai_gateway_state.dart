import "package:equatable/equatable.dart";

import "../../models/openai_vision_models.dart";

class AiGatewayState extends Equatable {
  const AiGatewayState({
    this.capabilities = const AiCapabilitiesSnapshot(),
    this.totalCompletions = 0,
    this.tableExtractions = 0,
    this.receiptExtractions = 0,
    this.vcardExtractions = 0,
    this.ocrCompletions = 0,
    this.fallbackCount = 0,
    this.recentJobs = const [],
    this.isCheckingCapabilities = false,
  });

  final AiCapabilitiesSnapshot capabilities;
  final int totalCompletions;
  final int tableExtractions;
  final int receiptExtractions;
  final int vcardExtractions;
  final int ocrCompletions;
  final int fallbackCount;
  final List<OpenAiJobRecord> recentJobs;
  final bool isCheckingCapabilities;

  AiGatewayState copyWith({
    AiCapabilitiesSnapshot? capabilities,
    int? totalCompletions,
    int? tableExtractions,
    int? receiptExtractions,
    int? vcardExtractions,
    int? ocrCompletions,
    int? fallbackCount,
    List<OpenAiJobRecord>? recentJobs,
    bool? isCheckingCapabilities,
  }) {
    return AiGatewayState(
      capabilities: capabilities ?? this.capabilities,
      totalCompletions: totalCompletions ?? this.totalCompletions,
      tableExtractions: tableExtractions ?? this.tableExtractions,
      receiptExtractions: receiptExtractions ?? this.receiptExtractions,
      vcardExtractions: vcardExtractions ?? this.vcardExtractions,
      ocrCompletions: ocrCompletions ?? this.ocrCompletions,
      fallbackCount: fallbackCount ?? this.fallbackCount,
      recentJobs: recentJobs ?? this.recentJobs,
      isCheckingCapabilities:
          isCheckingCapabilities ?? this.isCheckingCapabilities,
    );
  }

  @override
  List<Object?> get props => [
        capabilities,
        totalCompletions,
        tableExtractions,
        receiptExtractions,
        vcardExtractions,
        ocrCompletions,
        fallbackCount,
        recentJobs,
        isCheckingCapabilities,
      ];
}
