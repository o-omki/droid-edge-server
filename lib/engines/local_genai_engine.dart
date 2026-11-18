import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter/services.dart";
import "package:google_mlkit_genai_prompt/google_mlkit_genai_prompt.dart";

import "../models/ocr_result.dart";
import "../models/openai_vision_models.dart";
import "entity_extraction_engine.dart";

/// Outcome of attempting optional Tier 2 (Gemini Nano) or Tier 3 (LiteRT-LM)
/// refinement over the deterministic Tier 1 baseline.
class GenAiRefinementResult {
  const GenAiRefinementResult({
    this.refinedText,
    required this.tierUsed,
    this.fallbackTriggered = false,
  });

  final String? refinedText;
  final AiTier tierUsed;
  final bool fallbackTriggered;
}

/// Callback signature for pluggable Tier 3 local LiteRT-LM / SLM adapters.
typedef LocalSlmRunner = Future<String?> Function({
  required String prompt,
  required String modelPath,
  required bool forceJson,
});

/// Abstraction managing Tier 2 (OS-managed Gemini Nano via AICore) and Tier 3
/// (pluggable local `.litertlm` runtime) with deterministic fallback to Tier 1.
abstract class LocalGenAiEngine {
  AiCapabilitiesSnapshot get currentCapabilities;

  Future<AiCapabilitiesSnapshot> checkCapabilities({
    bool? tier2Enabled,
    bool? tier3Enabled,
    String? tier3ModelPath,
  });

  Future<GenAiRefinementResult> tryRefineExtraction({
    required ExtractionIntent intent,
    required String userPrompt,
    required OcrResult ocr,
    required String tier1Draft,
    required bool forceJson,
    String? requestedModel,
  });

  void configure({
    bool? tier2Enabled,
    bool? tier3Enabled,
    String? tier3ModelPath,
  });

  Future<void> dispose();
}

/// Default 3-tier runtime manager
///
/// Tier 1 (Deterministic Spatial & Entity) is always ready. Tier 2 queries
/// `google_mlkit_genai_prompt` safely, and Tier 3 exposes an opt-in pluggable
/// local runtime slot for `.litertlm` models on 6 GB+ RAM devices without
/// bundling heavy native FFI binaries in the base APK.
class ThreeTierGenAiRuntime implements LocalGenAiEngine {
  ThreeTierGenAiRuntime({
    EntityExtractionEngine? entityExtractionEngine,
    Future<AiFeatureAvailability> Function()? tier2StatusChecker,
    Future<String?> Function(String prompt)? tier2Runner,
    LocalSlmRunner? tier3Runner,
    Future<double?> Function()? deviceRamGbProvider,
    Duration inferenceTimeout = const Duration(seconds: 6),
    bool initialTier2Enabled = false,
    bool initialTier3Enabled = false,
    String? initialTier3ModelPath,
  }) : this._(
         entityExtractionEngine: entityExtractionEngine,
         tier2StatusChecker: tier2StatusChecker,
         tier2Runner: tier2Runner,
         tier3Runner: tier3Runner,
         deviceRamGbProvider: deviceRamGbProvider,
         inferenceTimeout: inferenceTimeout,
         tier2Enabled: initialTier2Enabled,
         tier3Enabled: initialTier3Enabled,
         tier3ModelPath: initialTier3ModelPath,
       );

  ThreeTierGenAiRuntime._({
    this._entityExtractionEngine,
    this._tier2StatusChecker,
    this._tier2Runner,
    this._tier3Runner,
    this._deviceRamGbProvider,
    required this._inferenceTimeout,
    required this._tier2Enabled,
    required this._tier3Enabled,
    this._tier3ModelPath,
  });

  final EntityExtractionEngine? _entityExtractionEngine;
  final Future<AiFeatureAvailability> Function()? _tier2StatusChecker;
  final Future<String?> Function(String prompt)? _tier2Runner;
  final LocalSlmRunner? _tier3Runner;
  final Future<double?> Function()? _deviceRamGbProvider;
  final Duration _inferenceTimeout;

  bool _tier2Enabled;
  bool _tier3Enabled;
  String? _tier3ModelPath;
  Prompt? _mlKitPrompt;

  AiCapabilitiesSnapshot _snapshot = const AiCapabilitiesSnapshot();

  @override
  AiCapabilitiesSnapshot get currentCapabilities => _snapshot;

  @override
  void configure({
    bool? tier2Enabled,
    bool? tier3Enabled,
    String? tier3ModelPath,
  }) {
    if (tier2Enabled != null) {
      _tier2Enabled = tier2Enabled;
    }
    if (tier3Enabled != null) {
      _tier3Enabled = tier3Enabled;
    }
    if (tier3ModelPath != null) {
      final trimmed = tier3ModelPath.trim();
      _tier3ModelPath = trimmed.isEmpty ? null : trimmed;
    }
    _snapshot = _snapshot.copyWith(
      tier2Enabled: _tier2Enabled,
      tier3Enabled: _tier3Enabled,
      tier3ModelPath: _tier3ModelPath,
      clearTier3ModelPath: _tier3ModelPath == null,
    );
  }

  @override
  Future<AiCapabilitiesSnapshot> checkCapabilities({
    bool? tier2Enabled,
    bool? tier3Enabled,
    String? tier3ModelPath,
  }) async {
    configure(
      tier2Enabled: tier2Enabled,
      tier3Enabled: tier3Enabled,
      tier3ModelPath: tier3ModelPath,
    );

    final entityDownloaded =
        await (_entityExtractionEngine?.isNativeModelAvailable() ??
            Future<bool>.value(false));
    final tier2Status = await _probeTier2Status();
    final ramGb = await (_deviceRamGbProvider?.call() ?? _readDeviceRamGb());
    final tier3Status = await _probeTier3Status(ramGb: ramGb);

    _snapshot = AiCapabilitiesSnapshot(
      tier1Ready: true,
      entityModelDownloaded: entityDownloaded,
      tier2Status: tier2Status,
      tier2Enabled: _tier2Enabled,
      tier3Status: tier3Status,
      tier3Enabled: _tier3Enabled,
      tier3ModelPath: _tier3ModelPath,
      deviceRamGb: ramGb,
    );
    return _snapshot;
  }

  @override
  Future<GenAiRefinementResult> tryRefineExtraction({
    required ExtractionIntent intent,
    required String userPrompt,
    required OcrResult ocr,
    required String tier1Draft,
    required bool forceJson,
    String? requestedModel,
  }) async {
    final normalizedModel = (requestedModel ?? "").trim().toLowerCase();
    final wantTier3 = _tier3Enabled &&
        _tier3Runner != null &&
        _tier3ModelPath != null &&
        _snapshot.tier3Status == AiFeatureAvailability.available;
    final wantTier2 = (_tier2Enabled || normalizedModel == "gemini-nano") &&
        (_snapshot.tier2Status == AiFeatureAvailability.available ||
            _tier2Runner != null);

    if (!wantTier3 && !wantTier2) {
      return const GenAiRefinementResult(
        tierUsed: AiTier.tier1Deterministic,
        fallbackTriggered: false,
      );
    }

    final promptText = _buildRefinementPrompt(
      intent: intent,
      userPrompt: userPrompt,
      ocrText: ocr.text,
      tier1Draft: tier1Draft,
      forceJson: forceJson,
    );

    var fallbackTriggered = false;

    if (wantTier3) {
      try {
        final tier3Runner = _tier3Runner;
        final modelPath = _tier3ModelPath;
        if (modelPath != null) {
          final output = await tier3Runner(
            prompt: promptText,
            modelPath: modelPath,
            forceJson: forceJson,
          ).timeout(_inferenceTimeout);
          final validated = _validateGenAiOutput(output, forceJson: forceJson);
          if (validated != null) {
            return GenAiRefinementResult(
              refinedText: validated,
              tierUsed: AiTier.tier3LiteRtLm,
              fallbackTriggered: false,
            );
          }
        }
        fallbackTriggered = true;
      } catch (_) {
        fallbackTriggered = true;
      }
    }

    if (wantTier2) {
      try {
        final status = _tier2Runner != null
            ? AiFeatureAvailability.available
            : await _probeTier2Status();
        if (status == AiFeatureAvailability.available) {
          final runner = _tier2Runner ?? _runMlKitPromptInference;
          final output = await runner(promptText).timeout(_inferenceTimeout);
          final validated = _validateGenAiOutput(output, forceJson: forceJson);
          if (validated != null) {
            return GenAiRefinementResult(
              refinedText: validated,
              tierUsed: AiTier.tier2GeminiNano,
              fallbackTriggered: fallbackTriggered,
            );
          }
        }
        fallbackTriggered = true;
      } catch (_) {
        fallbackTriggered = true;
      }
    }

    return GenAiRefinementResult(
      tierUsed: AiTier.tier1Deterministic,
      fallbackTriggered: fallbackTriggered,
    );
  }

  Future<AiFeatureAvailability> _probeTier2Status() async {
    final checker = _tier2StatusChecker;
    if (checker != null) {
      try {
        return await checker();
      } catch (_) {
        return AiFeatureAvailability.unavailable;
      }
    }

    if (!Platform.isAndroid) {
      return AiFeatureAvailability.unavailable;
    }

    try {
      final prompt = _mlKitPrompt ??= Prompt();
      final status = await prompt.checkFeatureStatus();
      return AiFeatureAvailability.fromMlKitStatusName(status.name);
    } on MissingPluginException {
      return AiFeatureAvailability.unavailable;
    } on PlatformException {
      return AiFeatureAvailability.unavailable;
    } catch (_) {
      return AiFeatureAvailability.unavailable;
    }
  }

  Future<AiFeatureAvailability> _probeTier3Status({double? ramGb}) async {
    final modelPath = _tier3ModelPath;
    if (_tier3Runner == null || modelPath == null || modelPath.isEmpty) {
      return AiFeatureAvailability.unavailable;
    }
    try {
      final exists = await File(modelPath).exists();
      if (!exists) {
        return AiFeatureAvailability.downloadable;
      }
      if (ramGb != null && ramGb < 5.5) {
        return AiFeatureAvailability.unavailable;
      }
      return AiFeatureAvailability.available;
    } catch (_) {
      return AiFeatureAvailability.unavailable;
    }
  }

  Future<String?> _runMlKitPromptInference(String promptText) async {
    try {
      final prompt = _mlKitPrompt ??= Prompt();
      final response = await prompt.runInference(promptText);
      return response;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      // Expected on devices without AICore or when the plugin returns BUSY /
      // unimplemented inference; caller falls back immediately to Tier 1.
      return null;
    } catch (_) {
      return null;
    }
  }

  static String? _validateGenAiOutput(
    String? raw, {
    required bool forceJson,
  }) {
    if (raw == null) return null;
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    if (!forceJson) {
      return trimmed;
    }

    // Strip optional markdown code fences returned by local SLMs before parsing.
    if (trimmed.startsWith("```")) {
      trimmed = trimmed
          .replaceFirst(RegExp(r"^```(?:json)?\s*", caseSensitive: false), "")
          .replaceFirst(RegExp(r"\s*```$"), "")
          .trim();
    }
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map || decoded is List) {
        return const JsonEncoder.withIndent("  ").convert(decoded);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static String _buildRefinementPrompt({
    required ExtractionIntent intent,
    required String userPrompt,
    required String ocrText,
    required String tier1Draft,
    required bool forceJson,
  }) {
    return "You are an offline document extraction assistant.\n"
        "Intent: ${intent.name}\n"
        "User instruction: $userPrompt\n"
        "${forceJson ? "Return ONLY valid JSON." : "Return concise clean output."}\n\n"
        "OCR text:\n$ocrText\n\n"
        "Tier 1 baseline draft:\n$tier1Draft";
  }

  static Future<double?> _readDeviceRamGb() async {
    try {
      final file = File("/proc/meminfo");
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      final match = RegExp(r"MemTotal:\s+(\d+)\s+kB").firstMatch(content);
      if (match == null) return null;
      final kb = int.tryParse(match.group(1)!);
      if (kb == null || kb <= 0) return null;
      final gb = kb / (1024 * 1024);
      return double.parse(gb.toStringAsFixed(1));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> dispose() async {
    final prompt = _mlKitPrompt;
    _mlKitPrompt = null;
    if (prompt != null) {
      try {
        await prompt.close();
      } catch (_) {}
    }
  }
}
