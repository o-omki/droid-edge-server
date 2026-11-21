import "dart:io";

import "package:flutter/services.dart";

/// Native Android bridge abstraction for on-device LiteRT-LM
/// (`.litertlm`) model execution and local model selection.
abstract class LiteRtLmEngine {
  /// Runs a single-turn inference request against the `.litertlm` model at
  /// [modelPath]. Returns `null` when unavailable, unsupported, or failed.
  Future<String?> runInference({
    required String prompt,
    required String modelPath,
    required bool forceJson,
  });

  Future<bool> isSupported();

  Future<double?> getDeviceRamGb();

  Future<String?> pickModelFile();

  Future<String?> getModelsDirectory();

  Future<void> unloadModel();

  Future<void> cancelInference();

  Future<void> dispose();
}

/// Platform-channel implementation of [LiteRtLmEngine] backed by Android's
/// `com.google.ai.edge.litertlm:litertlm-android` runtime.
///
/// Construction is strictly lazy and performs no platform calls until a method
/// is explicitly invoked.
class MethodChannelLiteRtLmEngine implements LiteRtLmEngine {
  MethodChannelLiteRtLmEngine({
    MethodChannel? channel,
    bool? isAndroidOverride,
  })  : _channel = channel ?? const MethodChannel(channelName),
        _isAndroid = isAndroidOverride ?? Platform.isAndroid;

  static const String channelName = "com.example.droid_edge_server/litert_lm";

  final MethodChannel _channel;
  final bool _isAndroid;
  bool _disposed = false;

  @override
  Future<bool> isSupported() async {
    if (!_isAndroid || _disposed) {
      return false;
    }
    try {
      final supported = await _channel.invokeMethod<bool>("isSupported");
      return supported == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<double?> getDeviceRamGb() async {
    if (!_isAndroid || _disposed) {
      return null;
    }
    try {
      final result = await _channel.invokeMethod<dynamic>("getDeviceRamGb");
      if (result is num) {
        return result.toDouble();
      }
      return null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> getModelsDirectory() async {
    if (!_isAndroid || _disposed) {
      return null;
    }
    try {
      final path = await _channel.invokeMethod<String>("getModelsDirectory");
      final trimmed = path?.trim();
      if (trimmed == null || trimmed.isEmpty) {
        return null;
      }
      return trimmed;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> pickModelFile() async {
    if (!_isAndroid || _disposed) {
      return null;
    }
    try {
      final path = await _channel.invokeMethod<String>("pickModelFile");
      final trimmed = path?.trim();
      if (trimmed == null || trimmed.isEmpty) {
        return null;
      }
      return trimmed;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<String?> runInference({
    required String prompt,
    required String modelPath,
    required bool forceJson,
  }) async {
    if (!_isAndroid || _disposed) {
      return null;
    }
    try {
      final response = await _channel.invokeMethod<String>(
        "runInference",
        <String, dynamic>{
          "prompt": prompt,
          "modelPath": modelPath,
          "forceJson": forceJson,
        },
      );
      if (response == null || response.trim().isEmpty) {
        return null;
      }
      return response;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      // Expected on OOM, missing/corrupt weights, or unsupported hardware;
      // ThreeTierGenAiRuntime immediately falls back to Tier 2 or Tier 1.
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _invokeVoidSafely(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // Safe no-op when invoked outside Android or in unit tests.
    } on PlatformException {
      // Best-effort native cleanup/cancellation must not block fallback.
    } catch (_) {
      // Ignore unexpected channel teardown errors.
    }
  }

  @override
  Future<void> cancelInference() async {
    if (!_isAndroid || _disposed) {
      return;
    }
    await _invokeVoidSafely("cancelInference");
  }

  @override
  Future<void> unloadModel() async {
    if (!_isAndroid || _disposed) {
      return;
    }
    await _invokeVoidSafely("unloadModel");
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    if (!_isAndroid) {
      return;
    }
    await _invokeVoidSafely("dispose");
  }
}
