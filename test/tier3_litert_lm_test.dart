import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:droid_edge_server/engines/entity_extraction_engine.dart";
import "package:droid_edge_server/engines/image_payload_processor.dart";
import "package:droid_edge_server/engines/litert_lm_engine.dart";
import "package:droid_edge_server/engines/local_genai_engine.dart";
import "package:droid_edge_server/engines/ocr_engine.dart";
import "package:droid_edge_server/engines/pdf_rasterizer.dart";
import "package:droid_edge_server/models/geometry_models.dart";
import "package:droid_edge_server/models/ocr_result.dart";
import "package:droid_edge_server/models/openai_vision_models.dart";
import "package:droid_edge_server/server/edge_http_server.dart";
import "package:flutter_test/flutter_test.dart";
import "package:image/image.dart" as img;

class _FakeLiteRtLmEngine implements LiteRtLmEngine {
  bool supported = true;
  double? ramGb = 8.0;
  String? modelsDirectory = "/sdcard/Android/data/com.example/files/models";
  String? pickedModelPath;
  Object? pickError;

  Future<String?> Function({
    required String prompt,
    required String modelPath,
    required bool forceJson,
  })? onRunInference;

  int isSupportedCalls = 0;
  int getDeviceRamCalls = 0;
  int runInferenceCalls = 0;
  int unloadCalls = 0;
  int cancelCalls = 0;
  int disposeCalls = 0;
  String? lastPrompt;
  String? lastModelPath;
  bool? lastForceJson;

  @override
  Future<bool> isSupported() async {
    isSupportedCalls++;
    return supported;
  }

  @override
  Future<double?> getDeviceRamGb() async {
    getDeviceRamCalls++;
    return ramGb;
  }

  @override
  Future<String?> getModelsDirectory() async => modelsDirectory;

  @override
  Future<String?> pickModelFile() async {
    if (pickError != null) {
      throw pickError!;
    }
    return pickedModelPath;
  }

  @override
  Future<String?> runInference({
    required String prompt,
    required String modelPath,
    required bool forceJson,
  }) async {
    runInferenceCalls++;
    lastPrompt = prompt;
    lastModelPath = modelPath;
    lastForceJson = forceJson;
    final handler = onRunInference;
    if (handler != null) {
      return handler(
        prompt: prompt,
        modelPath: modelPath,
        forceJson: forceJson,
      );
    }
    return null;
  }

  @override
  Future<void> unloadModel() async {
    unloadCalls++;
  }

  @override
  Future<void> cancelInference() async {
    cancelCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

class _FakeOcrEngine implements OcrEngine {
  @override
  Future<OcrResult> processImage(
    PreparedImagePayload payload, {
    OcrScript script = OcrScript.latin,
  }) async {
    const text = "TAX INVOICE\n"
        "Acme Coffee Roasters\n"
        "Invoice No: INV-2026-409\n"
        "Date: 2026-11-20\n"
        "Total: \$24.50";
    return OcrResult(
      text: text,
      script: script.name,
      detectedLanguages: const ["en"],
      inferenceMs: 9,
      imageWidth: payload.width ?? 400,
      imageHeight: payload.height ?? 300,
      blocks: const [
        OcrTextBlock(
          text: text,
          boundingBox: BoundingBoxRect(
            left: 16,
            top: 16,
            right: 360,
            bottom: 220,
          ),
          lines: [
            OcrTextLine(
              text: "TAX INVOICE",
              boundingBox: BoundingBoxRect(
                left: 16,
                top: 16,
                right: 200,
                bottom: 40,
              ),
            ),
            OcrTextLine(
              text: "Acme Coffee Roasters",
              boundingBox: BoundingBoxRect(
                left: 16,
                top: 48,
                right: 260,
                bottom: 72,
              ),
            ),
            OcrTextLine(
              text: "Total: \$24.50",
              boundingBox: BoundingBoxRect(
                left: 16,
                top: 140,
                right: 210,
                bottom: 164,
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Future<void> dispose() async {}
}

class _NoOpPdfRasterizer implements PdfRasterizer {
  @override
  Future<List<RasterizedPdfPage>> rasterizePdf(
    Uint8List pdfBytes, {
    double dpi = 180,
  }) async {
    return const [];
  }

  @override
  Future<void> dispose() async {}
}

OcrResult _sampleOcr() {
  return const OcrResult(
    text: "Acme Coffee Roasters\nTotal: \$24.50",
    script: "latin",
    blocks: [],
    detectedLanguages: ["en"],
    inferenceMs: 8,
  );
}

Uint8List _samplePngBytes() {
  final image = img.Image(width: 48, height: 48);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp("litert_lm_tier3_test_");
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<File> createModelFile(String name, {int bytes = 128}) async {
    final file = File("${tempDir.path}/$name");
    await file.writeAsBytes(List<int>.filled(bytes, 42));
    return file;
  }

  group("Tier 3 LiteRT-LM Capability Probing", () {
    test("reports unavailable when no runner is attached", () async {
      final runtime = ThreeTierGenAiRuntime(
        entityExtractionEngine: HybridEntityExtractionEngine(
          enableNativeMlKit: false,
        ),
        deviceRamGbProvider: () async => 8.0,
      );
      addTearDown(runtime.dispose);

      final caps = await runtime.checkCapabilities();
      expect(caps.tier3Status, AiFeatureAvailability.unavailable);
      expect(caps.activeTier, AiTier.tier1Deterministic);
    });

    test("reports unavailable when native platform is unsupported", () async {
      final modelFile = await createModelFile("gemma.litertlm");
      final fakeEngine = _FakeLiteRtLmEngine()..supported = false;
      final runtime = ThreeTierGenAiRuntime(
        entityExtractionEngine: HybridEntityExtractionEngine(
          enableNativeMlKit: false,
        ),
        liteRtLmEngine: fakeEngine,
        initialTier3ModelPath: modelFile.path,
      );
      addTearDown(runtime.dispose);

      final caps = await runtime.checkCapabilities();
      expect(caps.tier3Status, AiFeatureAvailability.unavailable);
      expect(fakeEngine.isSupportedCalls, 1);
    });

    test("reports downloadable when path is unset, missing, or zero-byte", () async {
      final fakeEngine = _FakeLiteRtLmEngine()..ramGb = 8.0;
      final runtime = ThreeTierGenAiRuntime(
        entityExtractionEngine: HybridEntityExtractionEngine(
          enableNativeMlKit: false,
        ),
        liteRtLmEngine: fakeEngine,
      );
      addTearDown(runtime.dispose);

      final unsetCaps = await runtime.checkCapabilities();
      expect(unsetCaps.tier3Status, AiFeatureAvailability.downloadable);

      final missingCaps = await runtime.checkCapabilities(
        tier3ModelPath: "${tempDir.path}/missing.litertlm",
      );
      expect(missingCaps.tier3Status, AiFeatureAvailability.downloadable);

      final emptyFile = await createModelFile("empty.litertlm", bytes: 0);
      final emptyCaps = await runtime.checkCapabilities(
        tier3ModelPath: emptyFile.path,
      );
      expect(emptyCaps.tier3Status, AiFeatureAvailability.downloadable);
    });

    test("rejects non-.litertlm extensions and devices below 5.5 GB RAM", () async {
      final wrongExt = await createModelFile("weights.txt");
      final validModel = await createModelFile("gemma.litertlm");
      final fakeEngine = _FakeLiteRtLmEngine()..ramGb = 8.0;
      final runtime = ThreeTierGenAiRuntime(
        entityExtractionEngine: HybridEntityExtractionEngine(
          enableNativeMlKit: false,
        ),
        liteRtLmEngine: fakeEngine,
      );
      addTearDown(runtime.dispose);

      final badExtCaps = await runtime.checkCapabilities(
        tier3ModelPath: wrongExt.path,
      );
      expect(badExtCaps.tier3Status, AiFeatureAvailability.unavailable);

      fakeEngine.ramGb = 4.0;
      final lowRamCaps = await runtime.checkCapabilities(
        tier3ModelPath: validModel.path,
      );
      expect(lowRamCaps.tier3Status, AiFeatureAvailability.unavailable);
      expect(lowRamCaps.deviceRamGb, 4.0);

      fakeEngine.ramGb = 5.5;
      final boundaryCaps = await runtime.checkCapabilities(
        tier3ModelPath: validModel.path,
      );
      expect(boundaryCaps.tier3Status, AiFeatureAvailability.available);
    });
  });

  group("Tier 3 Inference, Validation, Timeout & Fallback", () {
    test("returns refined text and validated fenced JSON via Tier 3", () async {
      final modelFile = await createModelFile("gemma-3n.litertlm");
      final fakeEngine = _FakeLiteRtLmEngine()
        ..onRunInference = ({
          required String prompt,
          required String modelPath,
          required bool forceJson,
        }) async {
          if (forceJson) {
            return "```json\n{\"merchant\":\"Acme Coffee\",\"total\":24.5}\n```";
          }
          return "Clean Markdown Summary";
        };

      final runtime = ThreeTierGenAiRuntime(
        entityExtractionEngine: HybridEntityExtractionEngine(
          enableNativeMlKit: false,
        ),
        liteRtLmEngine: fakeEngine,
        initialTier3Enabled: true,
        initialTier3ModelPath: modelFile.path,
      );
      addTearDown(runtime.dispose);
      await runtime.checkCapabilities();

      final textRes = await runtime.tryRefineExtraction(
        intent: ExtractionIntent.ocr,
        userPrompt: "Clean OCR",
        ocr: _sampleOcr(),
        tier1Draft: "draft",
        forceJson: false,
      );
      expect(textRes.tierUsed, AiTier.tier3LiteRtLm);
      expect(textRes.fallbackTriggered, isFalse);
      expect(textRes.refinedText, "Clean Markdown Summary");

      final jsonRes = await runtime.tryRefineExtraction(
        intent: ExtractionIntent.receipt,
        userPrompt: "Extract receipt JSON",
        ocr: _sampleOcr(),
        tier1Draft: "{}",
        forceJson: true,
      );
      expect(jsonRes.tierUsed, AiTier.tier3LiteRtLm);
      expect(jsonRes.fallbackTriggered, isFalse);
      expect(
        jsonDecode(jsonRes.refinedText!) as Map<String, dynamic>,
        {"merchant": "Acme Coffee", "total": 24.5},
      );
    });

    test("falls back cleanly to Tier 1 on malformed JSON, timeout, error, or missing file", () async {
      final modelFile = await createModelFile("gemma.litertlm");
      final fakeEngine = _FakeLiteRtLmEngine();
      final runtime = ThreeTierGenAiRuntime(
        entityExtractionEngine: HybridEntityExtractionEngine(
          enableNativeMlKit: false,
        ),
        liteRtLmEngine: fakeEngine,
        inferenceTimeout: const Duration(milliseconds: 50),
        initialTier3Enabled: true,
        initialTier3ModelPath: modelFile.path,
      );
      addTearDown(runtime.dispose);
      await runtime.checkCapabilities();

      // 1. Malformed JSON in JSON mode -> Tier 1 fallback
      fakeEngine.onRunInference = ({
        required String prompt,
        required String modelPath,
        required bool forceJson,
      }) async =>
          "not valid json at all";
      final invalidJsonRes = await runtime.tryRefineExtraction(
        intent: ExtractionIntent.receipt,
        userPrompt: "Parse JSON",
        ocr: _sampleOcr(),
        tier1Draft: "{}",
        forceJson: true,
      );
      expect(invalidJsonRes.tierUsed, AiTier.tier1Deterministic);
      expect(invalidJsonRes.fallbackTriggered, isTrue);

      // 2. Timeout -> calls cancelInference() + Tier 1 fallback
      fakeEngine.onRunInference = ({
        required String prompt,
        required String modelPath,
        required bool forceJson,
      }) async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        return "too late";
      };
      final timeoutRes = await runtime.tryRefineExtraction(
        intent: ExtractionIntent.ocr,
        userPrompt: "Transcribe",
        ocr: _sampleOcr(),
        tier1Draft: "draft",
        forceJson: false,
      );
      expect(timeoutRes.tierUsed, AiTier.tier1Deterministic);
      expect(timeoutRes.fallbackTriggered, isTrue);
      expect(fakeEngine.cancelCalls, 1);

      // 3. Missing file when gemma-local is explicitly requested -> Tier 1 fallback
      await modelFile.delete();
      final missingRes = await runtime.tryRefineExtraction(
        intent: ExtractionIntent.ocr,
        userPrompt: "Transcribe",
        ocr: _sampleOcr(),
        tier1Draft: "draft",
        forceJson: false,
        requestedModel: "gemma-local",
      );
      expect(missingRes.tierUsed, AiTier.tier1Deterministic);
      expect(missingRes.fallbackTriggered, isTrue);
    });

    test("cascades from failed Tier 3 to Tier 2 when Tier 2 is available", () async {
      final modelFile = await createModelFile("gemma.litertlm");
      final fakeEngine = _FakeLiteRtLmEngine()
        ..onRunInference = ({
          required String prompt,
          required String modelPath,
          required bool forceJson,
        }) async =>
            throw StateError("Native crash avoided");

      final runtime = ThreeTierGenAiRuntime(
        entityExtractionEngine: HybridEntityExtractionEngine(
          enableNativeMlKit: false,
        ),
        liteRtLmEngine: fakeEngine,
        tier2StatusChecker: () async => AiFeatureAvailability.available,
        tier2Runner: (_) async => "Tier 2 rescued output",
        initialTier2Enabled: true,
        initialTier3Enabled: true,
        initialTier3ModelPath: modelFile.path,
      );
      addTearDown(runtime.dispose);
      await runtime.checkCapabilities();

      final res = await runtime.tryRefineExtraction(
        intent: ExtractionIntent.ocr,
        userPrompt: "Transcribe",
        ocr: _sampleOcr(),
        tier1Draft: "draft",
        forceJson: false,
      );
      expect(res.tierUsed, AiTier.tier2GeminiNano);
      expect(res.fallbackTriggered, isTrue);
      expect(res.refinedText, "Tier 2 rescued output");
    });

    test("unloads native handles on path change, clear, disable, and dispose", () async {
      final modelA = await createModelFile("model-a.litertlm");
      final modelB = await createModelFile("model-b.litertlm");
      final fakeEngine = _FakeLiteRtLmEngine();
      final runtime = ThreeTierGenAiRuntime(
        entityExtractionEngine: HybridEntityExtractionEngine(
          enableNativeMlKit: false,
        ),
        liteRtLmEngine: fakeEngine,
        initialTier3Enabled: true,
        initialTier3ModelPath: modelA.path,
      );

      await runtime.checkCapabilities();
      expect(fakeEngine.unloadCalls, 0);

      await runtime.checkCapabilities(tier3ModelPath: modelB.path);
      expect(fakeEngine.unloadCalls, 1);

      await runtime.checkCapabilities(tier3Enabled: false);
      expect(fakeEngine.unloadCalls, 2);

      await runtime.checkCapabilities(tier3ModelPath: "");
      expect(fakeEngine.unloadCalls, 3);
      expect(runtime.currentCapabilities.tier3ModelPath, isNull);

      await runtime.dispose();
      expect(fakeEngine.disposeCalls, 1);
    });
  });

  group("Tier 3 End-to-End HTTP Integration", () {
    test("exposes gemma-local in /v1/models when ready and handles /v1/chat/completions", () async {
      final modelFile = await createModelFile("gemma-3n-e2b.litertlm");
      var shouldFail = false;

      final fakeEngine = _FakeLiteRtLmEngine()
        ..ramGb = 8.0
        ..onRunInference = ({
          required String prompt,
          required String modelPath,
          required bool forceJson,
        }) async {
          if (shouldFail) return null;
          return jsonEncode({
            "document_type": "tax_invoice",
            "merchant_name": "Acme Coffee Roasters",
            "total_amount": 24.5,
            "tier_used": "tier3_litert_lm",
          });
        };

      final server = EdgeHttpServer(
        ocrEngine: _FakeOcrEngine(),
        pdfRasterizer: _NoOpPdfRasterizer(),
        entityExtractionEngine: HybridEntityExtractionEngine(
          enableNativeMlKit: false,
        ),
        liteRtLmEngine: fakeEngine,
      );
      final port = await server.start(port: 0);
      addTearDown(server.dispose);

      final client = HttpClient();
      addTearDown(client.close);

      // 1. Before model path is configured, gemma-local is omitted.
      final initialModelsRes =
          await (await client.get("127.0.0.1", port, "/v1/models")).close();
      final initialModelsJson =
          jsonDecode(await utf8.decoder.bind(initialModelsRes).join())
              as Map<String, dynamic>;
      final initialIds = (initialModelsJson["data"] as List<dynamic>)
          .map((e) => (e as Map<String, dynamic>)["id"])
          .toList();
      expect(initialIds, isNot(contains("gemma-local")));

      // 2. Configure Tier 3 via POST /v1/ai/capabilities.
      final capReq =
          await client.post("127.0.0.1", port, "/v1/ai/capabilities");
      capReq.headers.set(HttpHeaders.contentTypeHeader, "application/json");
      capReq.add(
        utf8.encode(
          jsonEncode({
            "tier3_enabled": true,
            "tier3_model_path": modelFile.path,
          }),
        ),
      );
      final capRes = await capReq.close();
      final capJson = jsonDecode(await utf8.decoder.bind(capRes).join())
          as Map<String, dynamic>;
      expect(capRes.statusCode, HttpStatus.ok);
      expect(capJson["active_tier"], "tier3_litert_lm");
      expect(capJson["tier3"]["status"], "available");

      // 3. GET /v1/models now advertises gemma-local.
      final readyModelsRes =
          await (await client.get("127.0.0.1", port, "/v1/models")).close();
      final readyModelsJson =
          jsonDecode(await utf8.decoder.bind(readyModelsRes).join())
              as Map<String, dynamic>;
      final gemmaEntry = (readyModelsJson["data"] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .firstWhere((m) => m["id"] == "gemma-local");
      expect(gemmaEntry["owned_by"], "local-litertlm");

      // 4. POST /v1/chat/completions with gemma-local uses Tier 3.
      final dataUri =
          "data:image/png;base64,${base64Encode(_samplePngBytes())}";
      final chatReq =
          await client.post("127.0.0.1", port, "/v1/chat/completions");
      chatReq.headers.set(HttpHeaders.contentTypeHeader, "application/json");
      chatReq.add(
        utf8.encode(
          jsonEncode({
            "model": "gemma-local",
            "response_format": {"type": "json_object"},
            "messages": [
              {
                "role": "user",
                "content": [
                  {"type": "text", "text": "Extract receipt JSON"},
                  {
                    "type": "image_url",
                    "image_url": {"url": dataUri},
                  },
                ],
              },
            ],
          }),
        ),
      );
      final chatRes = await chatReq.close();
      final chatJson = jsonDecode(await utf8.decoder.bind(chatRes).join())
          as Map<String, dynamic>;
      expect(chatRes.statusCode, HttpStatus.ok);
      expect(chatJson["x_edge_metadata"]["tier_used"], "tier3_litert_lm");
      expect(chatJson["x_edge_metadata"]["fallback_triggered"], isFalse);

      // 5. On native error / null output, falls back cleanly to Tier 1.
      shouldFail = true;
      final failReq =
          await client.post("127.0.0.1", port, "/v1/chat/completions");
      failReq.headers.set(HttpHeaders.contentTypeHeader, "application/json");
      failReq.add(
        utf8.encode(
          jsonEncode({
            "model": "gemma-local",
            "response_format": {"type": "json_object"},
            "messages": [
              {
                "role": "user",
                "content": [
                  {"type": "text", "text": "Extract receipt JSON"},
                  {
                    "type": "image_url",
                    "image_url": {"url": dataUri},
                  },
                ],
              },
            ],
          }),
        ),
      );
      final failRes = await failReq.close();
      final failJson = jsonDecode(await utf8.decoder.bind(failRes).join())
          as Map<String, dynamic>;
      expect(failRes.statusCode, HttpStatus.ok);
      expect(failJson["x_edge_metadata"]["tier_used"], "tier1_deterministic");
      expect(failJson["x_edge_metadata"]["fallback_triggered"], isTrue);

      await server.dispose();
      expect(fakeEngine.disposeCalls, greaterThanOrEqualTo(1));
    });

    test("EdgeHttpServer checks liteRtLmEngine.isSupported even with wired tier3Runner", () async {
      final modelFile = await createModelFile("gemma-unsupported.litertlm");
      final unsupportedEngine = _FakeLiteRtLmEngine()..supported = false;
      final server = EdgeHttpServer(
        ocrEngine: _FakeOcrEngine(),
        pdfRasterizer: _NoOpPdfRasterizer(),
        entityExtractionEngine: HybridEntityExtractionEngine(
          enableNativeMlKit: false,
        ),
        liteRtLmEngine: unsupportedEngine,
      );
      addTearDown(server.dispose);

      final caps = await server.localGenAiEngine.checkCapabilities(
        tier3Enabled: true,
        tier3ModelPath: modelFile.path,
      );
      expect(caps.tier3Status, AiFeatureAvailability.unavailable);
      expect(caps.activeTier, AiTier.tier1Deterministic);
      expect(unsupportedEngine.isSupportedCalls, greaterThanOrEqualTo(1));
    });
  });
}
