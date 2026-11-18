import "dart:convert";
import "dart:typed_data";

import "package:shelf/shelf.dart";
import "package:shelf_router/shelf_router.dart";

import "../../engines/image_payload_processor.dart";
import "../../engines/local_genai_engine.dart";
import "../../engines/vision_chat_pipeline.dart";
import "../../models/ocr_result.dart";
import "../../models/openai_vision_models.dart";

/// OpenAI-compatible HTTP route handler for Phase 6:
/// - `GET /v1/models`
/// - `GET /v1/ai/capabilities`
/// - `POST /v1/ai/capabilities`
/// - `POST /v1/chat/completions`
class OpenAiRoutes {
  OpenAiRoutes({
    required this.visionChatPipeline,
    required this.localGenAiEngine,
    this.onJobCompleted,
  });

  final VisionChatPipeline visionChatPipeline;
  final LocalGenAiEngine localGenAiEngine;
  final void Function(OpenAiJobRecord job)? onJobCompleted;

  static const int _modelCreatedEpoch = 1700000000;

  Router get router {
    final router = Router();
    router.get("/v1/models", _handleListModels);
    router.get("/v1/ai/capabilities", _handleGetCapabilities);
    router.post("/v1/ai/capabilities", _handleUpdateCapabilities);
    router.post("/v1/chat/completions", _handleChatCompletions);
    return router;
  }

  Future<Response> _handleListModels(Request request) async {
    final caps = await localGenAiEngine.checkCapabilities();
    final models = <Map<String, dynamic>>[
      _modelEntry("local-edge-vision", ownedBy: "droid-edge-tier1"),
      _modelEntry("local-ocr", ownedBy: "droid-edge-tier1"),
      _modelEntry("local-structured", ownedBy: "droid-edge-tier1"),
      _modelEntry("local-table", ownedBy: "droid-edge-tier1"),
      _modelEntry("local-vcard", ownedBy: "droid-edge-tier1"),
    ];

    if (caps.tier2Status == AiFeatureAvailability.available) {
      models.add(_modelEntry("gemini-nano", ownedBy: "android-aicore"));
    }
    if (caps.tier3Status == AiFeatureAvailability.available) {
      models.add(_modelEntry("gemma-local", ownedBy: "local-litertlm"));
    }

    return Response.ok(
      jsonEncode({
        "object": "list",
        "data": models,
        "x_capabilities": caps.toJson(),
      }),
      headers: const {"content-type": "application/json; charset=utf-8"},
    );
  }

  Future<Response> _handleGetCapabilities(Request request) async {
    final caps = await localGenAiEngine.checkCapabilities();
    return Response.ok(
      jsonEncode({
        "status": "ok",
        ...caps.toJson(),
      }),
      headers: const {"content-type": "application/json; charset=utf-8"},
    );
  }

  Future<Response> _handleUpdateCapabilities(Request request) async {
    try {
      final rawText = await request.readAsString();
      if (rawText.trim().isNotEmpty) {
        final decoded = jsonDecode(rawText);
        if (decoded is! Map<String, dynamic>) {
          return _badRequest("Capabilities payload must be a JSON object.");
        }
        final tier2Enabled = decoded["tier2_enabled"];
        final tier3Enabled = decoded["tier3_enabled"];
        final tier3ModelPath = decoded["tier3_model_path"];

        localGenAiEngine.configure(
          tier2Enabled: tier2Enabled is bool ? tier2Enabled : null,
          tier3Enabled: tier3Enabled is bool ? tier3Enabled : null,
          tier3ModelPath: tier3ModelPath?.toString(),
        );
      }

      final caps = await localGenAiEngine.checkCapabilities();
      return Response.ok(
        jsonEncode({
          "status": "ok",
          ...caps.toJson(),
        }),
        headers: const {"content-type": "application/json; charset=utf-8"},
      );
    } on FormatException {
      return _badRequest("Malformed JSON in capabilities request.");
    }
  }

  Future<Response> _handleChatCompletions(Request request) async {
    try {
      final rawBody = await request.readAsString();
      if (rawBody.trim().isEmpty) {
        return _badRequest("Request body must not be empty.");
      }

      final dynamic decoded;
      try {
        decoded = jsonDecode(rawBody);
      } on FormatException {
        return _badRequest("Malformed JSON request body.");
      }

      if (decoded is! Map<String, dynamic>) {
        return _badRequest("JSON body must be an object.");
      }

      final parsedRequest = _parseChatRequest(
        decoded,
        queryScript: request.url.queryParameters["script"],
      );

      final response = await visionChatPipeline.complete(parsedRequest);

      final preview = parsedRequest.prompt.trim().replaceAll(RegExp(r"\s+"), " ");
      onJobCompleted?.call(
        OpenAiJobRecord(
          id: response.id,
          timestamp: DateTime.now(),
          requestedModel: response.model,
          effectiveTier: response.tierUsed,
          intent: response.intent,
          imageCount: parsedRequest.imagePayloads.length,
          promptPreview:
              preview.length > 72 ? "${preview.substring(0, 72)}…" : preview,
          promptTokens: response.promptTokens,
          completionTokens: response.completionTokens,
          processingMs: response.processingMs,
          streamed: parsedRequest.stream,
          fallbackTriggered: response.fallbackTriggered,
        ),
      );

      if (parsedRequest.stream) {
        final sseBytes = Stream.fromIterable(
          response.toSseEvents().map(utf8.encode),
        );
        return Response.ok(
          sseBytes,
          headers: const {
            "content-type": "text/event-stream; charset=utf-8",
            "cache-control": "no-cache",
            "connection": "keep-alive",
          },
        );
      }

      return Response.ok(
        jsonEncode(response.toOpenAiJson()),
        headers: const {"content-type": "application/json; charset=utf-8"},
      );
    } on ImagePayloadException catch (error) {
      return _badRequest(error.message);
    } on FormatException catch (error) {
      return _badRequest(error.message);
    }
  }

  static ChatCompletionRequest _parseChatRequest(
    Map<String, dynamic> body, {
    String? queryScript,
  }) {
    final rawMessages = body["messages"];
    if (rawMessages is! List || rawMessages.isEmpty) {
      throw const FormatException(
        "Field \"messages\" must be a non-empty array of chat messages.",
      );
    }

    final parsedMessages = <ChatMessage>[];
    final systemPrompts = <String>[];
    final userPrompts = <String>[];
    final latestUserImages = <Uint8List>[];
    final allImages = <Uint8List>[];

    for (var i = 0; i < rawMessages.length; i++) {
      final item = rawMessages[i];
      if (item is! Map<String, dynamic>) {
        throw FormatException("Message at index $i must be a JSON object.");
      }
      final role = (item["role"]?.toString() ?? "user").trim().toLowerCase();
      final content = item["content"];
      final extracted = _extractContentParts(content);

      parsedMessages.add(
        ChatMessage(
          role: role,
          text: extracted.text,
          imageCount: extracted.images.length,
        ),
      );

      if (role == "system" && extracted.text.isNotEmpty) {
        systemPrompts.add(extracted.text);
      } else if (role == "user") {
        if (extracted.text.isNotEmpty) {
          userPrompts.add(extracted.text);
        }
        if (extracted.images.isNotEmpty) {
          latestUserImages
            ..clear()
            ..addAll(extracted.images);
          allImages.addAll(extracted.images);
        }
      } else if (extracted.images.isNotEmpty) {
        allImages.addAll(extracted.images);
      }
    }

    // Convenience fallback if a caller sends top-level base64 `image` alongside messages.
    final topImage = body["image"] ?? body["image_base64"];
    if (topImage is String && topImage.trim().isNotEmpty) {
      final decoded = _decodeImageUrlOrBase64(topImage);
      latestUserImages.add(decoded);
      allImages.add(decoded);
    }

    final effectiveImages =
        latestUserImages.isNotEmpty ? latestUserImages : allImages;

    final primaryUserPrompt =
        userPrompts.isNotEmpty ? userPrompts.last : "";
    final combinedPrompt = [
      ...systemPrompts,
      if (primaryUserPrompt.isNotEmpty) primaryUserPrompt,
    ].join("\n").trim();

    String? responseFormatType;
    final rawRespFormat = body["response_format"];
    if (rawRespFormat is Map<String, dynamic>) {
      final type = rawRespFormat["type"]?.toString().trim().toLowerCase();
      if (type == "json_object" || type == "json_schema") {
        responseFormatType = "json_object";
      } else if (type == "text") {
        responseFormatType = "text";
      } else if (type != null && type.isNotEmpty) {
        throw FormatException(
          "Unsupported response_format type \"$type\". Supported: text, json_object.",
        );
      }
    }

    final stream = body["stream"] == true;
    final model = (body["model"]?.toString() ?? "local-edge-vision").trim();
    final script = OcrScript.fromName(
      body["script"]?.toString() ?? queryScript,
    );

    final temperature = body["temperature"] is num
        ? (body["temperature"] as num).toDouble()
        : null;
    final maxTokens = body["max_tokens"] is num
        ? (body["max_tokens"] as num).toInt()
        : null;

    return ChatCompletionRequest(
      model: model.isEmpty ? "local-edge-vision" : model,
      messages: parsedMessages,
      prompt: combinedPrompt,
      imagePayloads: effectiveImages,
      responseFormatType: responseFormatType,
      stream: stream,
      temperature: temperature,
      maxTokens: maxTokens,
      script: script,
    );
  }

  static ({String text, List<Uint8List> images}) _extractContentParts(
    dynamic content,
  ) {
    if (content == null) {
      return (text: "", images: const []);
    }
    if (content is String) {
      return (text: content.trim(), images: const []);
    }
    if (content is! List) {
      throw const FormatException(
        "Message \"content\" must be a string or an array of content parts.",
      );
    }

    final textParts = <String>[];
    final images = <Uint8List>[];

    for (final part in content) {
      if (part is String && part.trim().isNotEmpty) {
        textParts.add(part.trim());
        continue;
      }
      if (part is! Map<String, dynamic>) {
        continue;
      }

      final type = (part["type"]?.toString() ?? "").trim().toLowerCase();
      if (type == "text" || type == "input_text") {
        final txt = part["text"]?.toString().trim() ?? "";
        if (txt.isNotEmpty) {
          textParts.add(txt);
        }
      } else if (type == "image_url" || type == "input_image") {
        final rawImageUrl = part["image_url"] ?? part["url"];
        String? urlStr;
        if (rawImageUrl is String) {
          urlStr = rawImageUrl;
        } else if (rawImageUrl is Map<String, dynamic>) {
          urlStr = rawImageUrl["url"]?.toString();
        }
        if (urlStr == null || urlStr.trim().isEmpty) {
          throw const ImagePayloadException(
            "Part of type \"image_url\" must contain a non-empty \"url\" string.",
          );
        }
        images.add(_decodeImageUrlOrBase64(urlStr));
      } else if (type == "image_base64" || type == "image") {
        final b64 = part["data"]?.toString() ?? part["image"]?.toString();
        if (b64 != null && b64.trim().isNotEmpty) {
          images.add(_decodeImageUrlOrBase64(b64));
        }
      }
    }

    return (text: textParts.join("\n").trim(), images: images);
  }

  static Uint8List _decodeImageUrlOrBase64(String raw) {
    final trimmed = raw.trim();
    if (trimmed.startsWith("http://") || trimmed.startsWith("https://")) {
      throw const ImagePayloadException(
        "Remote HTTP(S) image_url fetching is disabled because Droid Edge "
        "Server runs 100% offline. Supply a base64 data URI "
        "(data:image/png;base64,...) instead.",
      );
    }
    if (trimmed.startsWith("file://")) {
      throw const ImagePayloadException(
        "Local file:// URIs are rejected for LAN security. Supply a base64 "
        "data URI (data:image/png;base64,...) instead.",
      );
    }

    var encoded = trimmed;
    if (trimmed.startsWith("data:")) {
      final commaIdx = trimmed.indexOf(",");
      if (commaIdx == -1 || commaIdx == trimmed.length - 1) {
        throw const ImagePayloadException(
          "Malformed data URI in \"image_url\".",
        );
      }
      encoded = trimmed.substring(commaIdx + 1);
    }

    try {
      final bytes = Uint8List.fromList(
        base64Decode(encoded.replaceAll(RegExp(r"\s+"), "")),
      );
      if (bytes.isEmpty) {
        throw const ImagePayloadException("Decoded image_url payload is empty.");
      }
      return bytes;
    } on FormatException {
      throw const ImagePayloadException(
        "Invalid base64 encoding in \"image_url\" payload.",
      );
    }
  }

  static Map<String, dynamic> _modelEntry(
    String id, {
    required String ownedBy,
  }) {
    return {
      "id": id,
      "object": "model",
      "created": _modelCreatedEpoch,
      "owned_by": ownedBy,
    };
  }

  static Response _badRequest(String message) {
    return Response.badRequest(
      body: jsonEncode({
        "error": {
          "message": message,
          "type": "invalid_request_error",
          "code": "bad_request",
        },
      }),
      headers: const {"content-type": "application/json; charset=utf-8"},
    );
  }
}
