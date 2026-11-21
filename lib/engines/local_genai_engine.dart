import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter/services.dart";
import "package:google_mlkit_genai_prompt/google_mlkit_genai_prompt.dart";

import "../models/ocr_result.dart";
import "../models/openai_vision_models.dart";
import "entity_extraction_engine.dart";
import "litert_lm_engine.dart";

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

  /// Opens the local document picker to choose a sideloaded `.litertlm` model.
  Future<String?> pickTier3ModelFile() async => null;

  /// Returns the app-owned directory recommended for `adb push` model storage.
  Future<String?> getTier3ModelsDirectory() async => null;

  Future<void> dispose();
}

/// Default 3-tier runtime manager.
///
/// Tier 1 (Deterministic Spatial & Entity) is always ready. Tier 2 queries
/// `google_mlkit_genai_prompt` safely, and Tier 3 runs sideloaded `.litertlm`
/// models via [LiteRtLmEngine] or a custom [LocalSlmRunner] on 5.5 GB+ RAM
/// devices without bundling weights in the APK.
class ThreeTierGenAiRuntime implements LocalGenAiEngine {
  static const double minTier3RamGb = 5.5;

  ThreeTierGenAiRuntime({
    EntityExtractionEngine? entityExtractionEngine,
    Future<AiFeatureAvailability> Function()? tier2StatusChecker,
    Future<String?> Function(String prompt)? tier2Runner,
    LiteRtLmEngine? liteRtLmEngine,
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
         liteRtLmEngine: liteRtLmEngine,
         tier3Runner: tier3Runner ?? liteRtLmEngine?.runInference,
         deviceRamGbProvider: deviceRamGbProvider,
         inferenceTimeout: inferenceTimeout,
         tier2Enabled: initialTier2Enabled,
         tier3Enabled: initialTier3Enabled,
         tier3ModelPath: _normaliseModelPath(initialTier3ModelPath),
       );

  ThreeTierGenAiRuntime._({
    this._entityExtractionEngine,
    this._tier2StatusChecker,
    this._tier2Runner,
    this._liteRtLmEngine,
    this._tier3Runner,
    this._deviceRamGbProvider,
    required this._inferenceTimeout,
    required this._tier2Enabled,
    required this._tier3Enabled,
    required this._tier3ModelPath,
  });

  final EntityExtractionEngine? _entityExtractionEngine;
  final Future<AiFeatureAvailability> Function()? _tier2StatusChecker;
  final Future<String?> Function(String prompt)? _tier2Runner;
  final LiteRtLmEngine? _liteRtLmEngine;
  final LocalSlmRunner? _tier3Runner;
  final Future<double?> Function()? _deviceRamGbProvider;
  final Duration _inferenceTimeout;

  bool _tier2Enabled;
  bool _tier3Enabled;
  String? _tier3ModelPath;
  Prompt? _mlKitPrompt;
  Future<void>? _pendingUnload;

  AiCapabilitiesSnapshot _snapshot = const AiCapabilitiesSnapshot();

  static String? _normaliseModelPath(String? rawPath) {
    if (rawPath == null) return null;
    final trimmed = rawPath.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  AiCapabilitiesSnapshot get currentCapabilities => _snapshot;

  @override
  void configure({
    bool? tier2Enabled,
    bool? tier3Enabled,
    String? tier3ModelPath,
  }) {
    final previousEnabled = _tier3Enabled;
    final previousModelPath = _tier3ModelPath;

    if (tier2Enabled != null) {
      _tier2Enabled = tier2Enabled;
    }
    if (tier3Enabled != null) {
      _tier3Enabled = tier3Enabled;
    }
    if (tier3ModelPath != null) {
      _tier3ModelPath = _normaliseModelPath(tier3ModelPath);
    }

    final pathChanged = _tier3ModelPath != previousModelPath;
    final disabledTier3 = previousEnabled && !_tier3Enabled;
    if (pathChanged || disabledTier3) {
      unawaited(_unloadTier3Model());
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

    final pendingUnload = _pendingUnload;
    if (pendingUnload != null) {
      await pendingUnload;
    }

    final entityDownloaded =
        await (_entityExtractionEngine?.isNativeModelAvailable() ??
            Future<bool>.value(false));
    final tier2Status = await _probeTier2Status();
    final ramGb = await _resolveDeviceRamGb();
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
    final explicitlyRequestedTier3 = normalizedModel == "gemma-local";
    final shouldAttemptTier3 = _tier3Enabled || explicitlyRequestedTier3;
    final wantTier2 = (_tier2Enabled || normalizedModel == "gemini-nano") &&
        (_snapshot.tier2Status == AiFeatureAvailability.available ||
            _tier2Runner != null);

    if (!shouldAttemptTier3 && !wantTier2) {
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

    if (shouldAttemptTier3) {
      final pendingUnload = _pendingUnload;
      if (pendingUnload != null) {
        await pendingUnload;
      }

      final ramGb = _snapshot.deviceRamGb ?? await _resolveDeviceRamGb();
      final liveTier3Status = await _probeTier3Status(ramGb: ramGb);
      _snapshot = _snapshot.copyWith(
        tier3Status: liveTier3Status,
        deviceRamGb: ramGb,
      );

      final tier3Runner = _tier3Runner;
      final modelPath = _tier3ModelPath;
      if (liveTier3Status == AiFeatureAvailability.available &&
          tier3Runner != null &&
          modelPath != null) {
        try {
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
          fallbackTriggered = true;
        } on TimeoutException {
          unawaited(_cancelTier3Inference());
          fallbackTriggered = true;
        } catch (_) {
          fallbackTriggered = true;
        }
      } else {
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

  @override
  Future<String?> pickTier3ModelFile() async {
    return _liteRtLmEngine?.pickModelFile();
  }

  @override
  Future<String?> getTier3ModelsDirectory() async {
    try {
      return await _liteRtLmEngine?.getModelsDirectory();
    } catch (_) {
      return null;
    }
  }

  Future<void> _unloadTier3Model() {
    final existing = _pendingUnload;
    if (existing != null) {
      return existing;
    }
    final engine = _liteRtLmEngine;
    if (engine == null) {
      return Future<void>.value();
    }
    final future = () async {
      try {
        await engine.unloadModel();
      } catch (_) {
      } finally {
        _pendingUnload = null;
      }
    }();
    _pendingUnload = future;
    return future;
  }

  Future<void> _cancelTier3Inference() async {
    try {
      await _liteRtLmEngine?.cancelInference();
    } catch (_) {}
  }

  Future<double?> _resolveDeviceRamGb() async {
    final provider = _deviceRamGbProvider;
    if (provider != null) {
      try {
        return await provider();
      } catch (_) {
        return null;
      }
    }

    final engine = _liteRtLmEngine;
    if (engine != null) {
      try {
        final nativeRam = await engine.getDeviceRamGb();
        if (nativeRam != null) {
          return nativeRam;
        }
      } catch (_) {}
    }

    return _readDeviceRamGb();
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
    if (_tier3Runner == null) {
      return AiFeatureAvailability.unavailable;
    }

    final liteRtLmEngine = _liteRtLmEngine;
    if (liteRtLmEngine != null) {
      try {
        final supported = await liteRtLmEngine.isSupported();
        if (!supported) {
          return AiFeatureAvailability.unavailable;
        }
      } catch (_) {
        return AiFeatureAvailability.unavailable;
      }
    }

    if (ramGb != null && ramGb < minTier3RamGb) {
      return AiFeatureAvailability.unavailable;
    }

    final modelPath = _tier3ModelPath;
    if (modelPath == null || modelPath.isEmpty) {
      return AiFeatureAvailability.downloadable;
    }

    if (!modelPath.toLowerCase().endsWith(".litertlm")) {
      return AiFeatureAvailability.unavailable;
    }

    try {
      final file = File(modelPath);
      final exists = await file.exists();
      if (!exists) {
        return AiFeatureAvailability.downloadable;
      }
      final sizeBytes = await file.length();
      if (sizeBytes <= 0) {
        return AiFeatureAvailability.downloadable;
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

    final liteRtLmEngine = _liteRtLmEngine;
    if (liteRtLmEngine != null) {
      try {
        await liteRtLmEngine.dispose();
      } catch (_) {}
    }
  }
}
