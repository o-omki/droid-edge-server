import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:droid_edge_server/models/request_log_entry.dart";
import "package:droid_edge_server/server/edge_http_server.dart";
import "package:flutter_test/flutter_test.dart";

Future<Uint8List?> _diskAssetLoader(String assetKey) async {
  final file = File(assetKey);
  if (!await file.exists()) {
    return null;
  }
  return file.readAsBytes();
}

void main() {
  group("Phase 4 Built-in Zero-Install Web App", () {
    late EdgeHttpServer server;
    late int port;

    setUp(() async {
      server = EdgeHttpServer(webAssetLoader: _diskAssetLoader);
      port = await server.start(port: 0);
    });

    tearDown(() async {
      await server.dispose();
    });

    test("GET / serves bundled index.html and emits RequestLogEntry", () async {
      final logs = <RequestLogEntry>[];
      final sub = server.requestLogs.listen(logs.add);
      addTearDown(sub.cancel);

      final client = HttpClient();
      addTearDown(client.close);

      final request = await client.get("127.0.0.1", port, "/");
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.contentType?.mimeType, "text/html");
      expect(body, contains("Droid Edge Server"));
      expect(body, contains("Raw Text"));
      expect(body, contains("Structured JSON"));
      expect(body, contains("Barcode Scan"));
      expect(body, contains("id=\"dropZone\""));
      expect(body, contains("id=\"copyBoxBtn\""));

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(logs, hasLength(1));
      expect(logs.first.method, "GET");
      expect(logs.first.path, "/");
      expect(logs.first.statusCode, 200);
    });

    test("GET /styles.css and GET /app.js serve bundled static assets",
        () async {
      final client = HttpClient();
      addTearDown(client.close);

      final cssReq = await client.get("127.0.0.1", port, "/styles.css");
      final cssRes = await cssReq.close();
      final cssBody = await utf8.decoder.bind(cssRes).join();
      expect(cssRes.statusCode, HttpStatus.ok);
      expect(cssRes.headers.contentType?.mimeType, "text/css");
      expect(cssBody, contains(".drop-zone"));

      final jsReq = await client.get("127.0.0.1", port, "/app.js");
      final jsRes = await jsReq.close();
      final jsBody = await utf8.decoder.bind(jsRes).join();
      expect(jsRes.statusCode, HttpStatus.ok);
      expect(
        jsRes.headers.contentType?.mimeType,
        anyOf("text/javascript", "application/javascript"),
      );
      expect(jsBody, contains("/v1/ocr"));
      expect(jsBody, contains("/v1/barcode"));
    });

    test("rejects path traversal and unknown paths with JSON 404", () async {
      final client = HttpClient();
      addTearDown(client.close);

      final traversalReq =
          await client.get("127.0.0.1", port, "/../pubspec.yaml");
      final traversalRes = await traversalReq.close();
      final traversalBody = await utf8.decoder.bind(traversalRes).join();
      expect(traversalRes.statusCode, HttpStatus.notFound);
      expect(
        (jsonDecode(traversalBody) as Map<String, dynamic>)["error"],
        "not_found",
      );

      final missingReq =
          await client.get("127.0.0.1", port, "/nonexistent-asset.js");
      final missingRes = await missingReq.close();
      final missingBody = await utf8.decoder.bind(missingRes).join();
      expect(missingRes.statusCode, HttpStatus.notFound);
      expect(
        (jsonDecode(missingBody) as Map<String, dynamic>)["error"],
        "not_found",
      );
    });
  });
}
