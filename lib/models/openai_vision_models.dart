import "dart:convert";
import "dart:typed_data";

import "package:equatable/equatable.dart";

import "ocr_result.dart";

/// Structured extraction intent derived from an OpenAI chat prompt, requested
/// model alias, and optional `response_format`.
enum ExtractionIntent {
  table("Table"),
  receipt("Receipt / Bill"),
  vcard("vCard"),
  ocr("Vision OCR");

  const ExtractionIntent(this.label);

  final String label;

  static final RegExp _tableIntentRegex = RegExp(
    r"\b(?:table|markdown\s+table|tabular|columns?|rows?|grid|csv)\b",
    caseSensitive: false,
  );

  static final RegExp _vcardIntentRegex = RegExp(
    r"(?:\b(?:vcard|business\s+card|contact\s+card|visiting\s+card|contact\s+info(?:rmation)?|contact\s+details)\b|\.vcf\b)",
    caseSensitive: false,
  );

  static final RegExp _receiptIntentRegex = RegExp(
    r"\b(?:receipt|invoice|bill|utility|tax|gstin|line\s+items?|merchant|total\s+amount|parse\s+json|extract\s+json|structured\s+json)\b",
    caseSensitive: false,
  );

  /// Detects the extraction intent from [prompt], optional [responseFormatType],
  /// and optional [requestedModel].
  static ExtractionIntent detect({
    required String prompt,
    String? responseFormatType,
    String? requestedModel,
  }) {
    final modelNorm = (requestedModel ?? "").trim().toLowerCase();
    if (modelNorm == "local-table") {
      return ExtractionIntent.table;
    }
    if (modelNorm == "local-vcard") {
      return ExtractionIntent.vcard;
    }

    if (_tableIntentRegex.hasMatch(prompt)) {
      return ExtractionIntent.table;
    }
    if (_vcardIntentRegex.hasMatch(prompt)) {
      return ExtractionIntent.vcard;
    }
    if (modelNorm == "local-structured" ||
        _receiptIntentRegex.hasMatch(prompt) ||
        responseFormatType == "json_object") {
      return ExtractionIntent.receipt;
    }
    return ExtractionIntent.ocr;
  }
}

/// Execution tier within the 3-tier offline extraction architecture.
enum AiTier {
  tier1Deterministic(
    id: "tier1_deterministic",
    label: "Tier 1 · Deterministic Spatial & Entity",
  ),
  tier2GeminiNano(
    id: "tier2_gemini_nano",
    label: "Tier 2 · Gemini Nano (AICore)",
  ),
  tier3LiteRtLm(
    id: "tier3_litert_lm",
    label: "Tier 3 · Local LiteRT-LM",
  );

  const AiTier({
    required this.id,
    required this.label,
  });

  final String id;
  final String label;
}

/// Availability state reported for optional on-device GenAI runtimes.
enum AiFeatureAvailability {
  available,
  downloadable,
  downloading,
  unavailable,
  disabled;

  static AiFeatureAvailability fromMlKitStatusName(String rawName) {
    switch (rawName.trim().toLowerCase()) {
      case "available":
        return AiFeatureAvailability.available;
      case "downloadable":
        return AiFeatureAvailability.downloadable;
      case "downloading":
        return AiFeatureAvailability.downloading;
      case "disabled":
        return AiFeatureAvailability.disabled;
      default:
        return AiFeatureAvailability.unavailable;
    }
  }
}

/// Snapshot of all three extraction tiers and device runtime readiness.
class AiCapabilitiesSnapshot extends Equatable {
  const AiCapabilitiesSnapshot({
    this.tier1Ready = true,
    this.entityModelDownloaded = false,
    this.tier2Status = AiFeatureAvailability.unavailable,
    this.tier2Enabled = false,
    this.tier3Status = AiFeatureAvailability.unavailable,
    this.tier3Enabled = false,
    this.tier3ModelPath,
    this.deviceRamGb,
  });

  final bool tier1Ready;
  final bool entityModelDownloaded;
  final AiFeatureAvailability tier2Status;
  final bool tier2Enabled;
  final AiFeatureAvailability tier3Status;
  final bool tier3Enabled;
  final String? tier3ModelPath;
  final double? deviceRamGb;

  /// Highest currently active tier taking user opt-in flags and availability
  /// into account.
  AiTier get activeTier {
    if (tier3Enabled && tier3Status == AiFeatureAvailability.available) {
      return AiTier.tier3LiteRtLm;
    }
    if (tier2Enabled && tier2Status == AiFeatureAvailability.available) {
      return AiTier.tier2GeminiNano;
    }
    return AiTier.tier1Deterministic;
  }

  AiCapabilitiesSnapshot copyWith({
    bool? tier1Ready,
    bool? entityModelDownloaded,
    AiFeatureAvailability? tier2Status,
    bool? tier2Enabled,
    AiFeatureAvailability? tier3Status,
    bool? tier3Enabled,
    String? tier3ModelPath,
    bool clearTier3ModelPath = false,
    double? deviceRamGb,
  }) {
    return AiCapabilitiesSnapshot(
      tier1Ready: tier1Ready ?? this.tier1Ready,
      entityModelDownloaded:
          entityModelDownloaded ?? this.entityModelDownloaded,
      tier2Status: tier2Status ?? this.tier2Status,
      tier2Enabled: tier2Enabled ?? this.tier2Enabled,
      tier3Status: tier3Status ?? this.tier3Status,
      tier3Enabled: tier3Enabled ?? this.tier3Enabled,
      tier3ModelPath: clearTier3ModelPath
          ? null
          : (tier3ModelPath ?? this.tier3ModelPath),
      deviceRamGb: deviceRamGb ?? this.deviceRamGb,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      "active_tier": activeTier.id,
      "tier1": {
        "ready": tier1Ready,
        "entity_model_downloaded": entityModelDownloaded,
      },
      "tier2": {
        "status": tier2Status.name,
        "enabled": tier2Enabled,
      },
      "tier3": {
        "status": tier3Status.name,
        "enabled": tier3Enabled,
        "model_path": tier3ModelPath,
        "device_ram_gb": deviceRamGb,
      },
    };
  }

  @override
  List<Object?> get props => [
        tier1Ready,
        entityModelDownloaded,
        tier2Status,
        tier2Enabled,
        tier3Status,
        tier3Enabled,
        tier3ModelPath,
        deviceRamGb,
      ];
}

/// Normalised entity extracted by ML Kit Entity Extraction or deterministic
/// offline rules.
class ExtractedEntityItem extends Equatable {
  const ExtractedEntityItem({
    required this.type,
    required this.rawValue,
    this.normalizedValue,
    this.currency,
    this.amount,
  });

  final String type;
  final String rawValue;
  final String? normalizedValue;
  final String? currency;
  final double? amount;

  Map<String, dynamic> toJson() {
    return {
      "type": type,
      "raw_value": rawValue,
      if (normalizedValue != null) "normalized_value": normalizedValue,
      if (currency != null) "currency": currency,
      if (amount != null) "amount": amount,
    };
  }

  @override
  List<Object?> get props => [
        type,
        rawValue,
        normalizedValue,
        currency,
        amount,
      ];
}

/// Output of the 2D spatial bounding-box table reconstructor.
class SpatialTableResult extends Equatable {
  const SpatialTableResult({
    required this.markdown,
    required this.headers,
    required this.rows,
    required this.columnAlignments,
  });

  final String markdown;
  final List<String> headers;
  final List<List<String>> rows;
  final List<String> columnAlignments;

  int get rowCount => rows.length;
  int get columnCount => headers.length;

  Map<String, dynamic> toJson() {
    return {
      "row_count": rowCount,
      "column_count": columnCount,
      "headers": headers,
      "column_alignments": columnAlignments,
      "rows": rows,
      "markdown": markdown,
    };
  }

  @override
  List<Object?> get props => [markdown, headers, rows, columnAlignments];
}

/// Line item parsed from a receipt, invoice, or utility bill.
class ReceiptLineItem extends Equatable {
  const ReceiptLineItem({
    required this.description,
    this.quantity,
    this.unitPrice,
    required this.amount,
  });

  final String description;
  final double? quantity;
  final double? unitPrice;
  final double amount;

  Map<String, dynamic> toJson() {
    return {
      "description": description,
      if (quantity != null) "quantity": quantity,
      if (unitPrice != null) "unit_price": unitPrice,
      "amount": amount,
    };
  }

  @override
  List<Object?> get props => [description, quantity, unitPrice, amount];
}

/// Structured JSON representation of a receipt, tax invoice, or utility bill.
class StructuredReceiptResult extends Equatable {
  const StructuredReceiptResult({
    required this.documentType,
    this.merchantName,
    this.invoiceNumber,
    this.date,
    this.currency,
    this.subtotal,
    this.taxAmount,
    this.totalAmount,
    this.taxIds = const [],
    this.paymentMethods = const [],
    this.phones = const [],
    this.emails = const [],
    this.addresses = const [],
    this.lineItems = const [],
    required this.rawText,
    required this.tierUsed,
  });

  final String documentType;
  final String? merchantName;
  final String? invoiceNumber;
  final String? date;
  final String? currency;
  final double? subtotal;
  final double? taxAmount;
  final double? totalAmount;
  final List<String> taxIds;
  final List<String> paymentMethods;
  final List<String> phones;
  final List<String> emails;
  final List<String> addresses;
  final List<ReceiptLineItem> lineItems;
  final String rawText;
  final String tierUsed;

  Map<String, dynamic> toJson() {
    return {
      "document_type": documentType,
      "merchant_name": merchantName,
      "invoice_number": invoiceNumber,
      "date": date,
      "currency": currency,
      "subtotal": subtotal,
      "tax_amount": taxAmount,
      "total_amount": totalAmount,
      "tax_ids": taxIds,
      "payment_methods": paymentMethods,
      "phones": phones,
      "emails": emails,
      "addresses": addresses,
      "line_items": lineItems.map((item) => item.toJson()).toList(),
      "tier_used": tierUsed,
      "raw_text": rawText,
    };
  }

  @override
  List<Object?> get props => [
        documentType,
        merchantName,
        invoiceNumber,
        date,
        currency,
        subtotal,
        taxAmount,
        totalAmount,
        taxIds,
        paymentMethods,
        phones,
        emails,
        addresses,
        lineItems,
        rawText,
        tierUsed,
      ];
}

/// Structured contact fields and RFC 2426 vCard 3.0 payload extracted from a
/// business card.
class VCardContactResult extends Equatable {
  const VCardContactResult({
    required this.fullName,
    required this.firstName,
    required this.lastName,
    this.organization,
    this.title,
    this.phones = const [],
    this.emails = const [],
    this.urls = const [],
    this.addresses = const [],
    this.note,
    required this.vcardText,
  });

  final String fullName;
  final String firstName;
  final String lastName;
  final String? organization;
  final String? title;
  final List<String> phones;
  final List<String> emails;
  final List<String> urls;
  final List<String> addresses;
  final String? note;
  final String vcardText;

  Map<String, dynamic> toJson() {
    return {
      "full_name": fullName,
      "first_name": firstName,
      "last_name": lastName,
      "organization": organization,
      "title": title,
      "phones": phones,
      "emails": emails,
      "urls": urls,
      "addresses": addresses,
      if (note != null) "note": note,
      "vcard": vcardText,
    };
  }

  @override
  List<Object?> get props => [
        fullName,
        firstName,
        lastName,
        organization,
        title,
        phones,
        emails,
        urls,
        addresses,
        note,
        vcardText,
      ];
}

/// Simplified representation of an OpenAI chat message.
class ChatMessage extends Equatable {
  const ChatMessage({
    required this.role,
    required this.text,
    this.imageCount = 0,
  });

  final String role;
  final String text;
  final int imageCount;

  @override
  List<Object?> get props => [role, text, imageCount];
}

/// Parsed OpenAI `/v1/chat/completions` vision/extraction request.
class ChatCompletionRequest {
  const ChatCompletionRequest({
    required this.model,
    required this.messages,
    required this.prompt,
    required this.imagePayloads,
    this.responseFormatType,
    this.stream = false,
    this.temperature,
    this.maxTokens,
    this.script = OcrScript.latin,
  });

  final String model;
  final List<ChatMessage> messages;
  final String prompt;
  final List<Uint8List> imagePayloads;
  final String? responseFormatType;
  final bool stream;
  final double? temperature;
  final int? maxTokens;
  final OcrScript script;
}

/// Result returned by [VisionChatPipeline] and serialised into OpenAI
/// `chat.completion` JSON or SSE chunks.
class ChatCompletionResponse {
  const ChatCompletionResponse({
    required this.id,
    required this.created,
    required this.model,
    required this.content,
    this.finishReason = "stop",
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    required this.intent,
    required this.tierUsed,
    required this.processingMs,
    this.fallbackTriggered = false,
  });

  final String id;
  final int created;
  final String model;
  final String content;
  final String finishReason;
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final ExtractionIntent intent;
  final AiTier tierUsed;
  final int processingMs;
  final bool fallbackTriggered;

  Map<String, dynamic> toOpenAiJson() {
    return {
      "id": id,
      "object": "chat.completion",
      "created": created,
      "model": model,
      "choices": [
        {
          "index": 0,
          "message": {
            "role": "assistant",
            "content": content,
          },
          "finish_reason": finishReason,
        },
      ],
      "usage": {
        "prompt_tokens": promptTokens,
        "completion_tokens": completionTokens,
        "total_tokens": totalTokens,
      },
      "x_edge_metadata": {
        "intent": intent.name,
        "tier_used": tierUsed.id,
        "processing_ms": processingMs,
        "fallback_triggered": fallbackTriggered,
      },
    };
  }

  /// Formats this completion as standard OpenAI Server-Sent Events (`SSE`)
  /// `chat.completion.chunk` lines terminated by `data: [DONE]`.
  List<String> toSseEvents({int chunkSize = 120}) {
    final events = <String>[
      _formatSseChunk(
        delta: const {"role": "assistant", "content": ""},
        finishReason: null,
      ),
    ];

    if (content.isNotEmpty) {
      for (var i = 0; i < content.length; i += chunkSize) {
        final end = (i + chunkSize < content.length)
            ? i + chunkSize
            : content.length;
        events.add(
          _formatSseChunk(
            delta: {"content": content.substring(i, end)},
            finishReason: null,
          ),
        );
      }
    }

    events.add(
      _formatSseChunk(
        delta: const <String, dynamic>{},
        finishReason: finishReason,
      ),
    );
    events.add("data: [DONE]\n\n");
    return events;
  }

  String _formatSseChunk({
    required Map<String, dynamic> delta,
    required String? finishReason,
  }) {
    final payload = {
      "id": id,
      "object": "chat.completion.chunk",
      "created": created,
      "model": model,
      "choices": [
        {
          "index": 0,
          "delta": delta,
          "finish_reason": finishReason,
        },
      ],
    };
    return "data: ${jsonEncode(payload)}\n\n";
  }
}

/// Telemetry record emitted for each completed `/v1/chat/completions` job.
class OpenAiJobRecord extends Equatable {
  const OpenAiJobRecord({
    required this.id,
    required this.timestamp,
    required this.requestedModel,
    required this.effectiveTier,
    required this.intent,
    required this.imageCount,
    required this.promptPreview,
    required this.promptTokens,
    required this.completionTokens,
    required this.processingMs,
    this.streamed = false,
    this.fallbackTriggered = false,
  });

  final String id;
  final DateTime timestamp;
  final String requestedModel;
  final AiTier effectiveTier;
  final ExtractionIntent intent;
  final int imageCount;
  final String promptPreview;
  final int promptTokens;
  final int completionTokens;
  final int processingMs;
  final bool streamed;
  final bool fallbackTriggered;

  @override
  List<Object?> get props => [
        id,
        timestamp,
        requestedModel,
        effectiveTier,
        intent,
        imageCount,
        promptPreview,
        promptTokens,
        completionTokens,
        processingMs,
        streamed,
        fallbackTriggered,
      ];
}
