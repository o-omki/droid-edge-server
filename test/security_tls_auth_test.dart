import "dart:convert";
import "dart:io";

import "package:droid_edge_server/server/edge_http_server.dart";
import "package:droid_edge_server/services/local_ca_service.dart";
import "package:droid_edge_server/services/pairing_token_service.dart";
import "package:droid_edge_server/services/secure_key_store.dart";
import "package:flutter_test/flutter_test.dart";

Future<String?> _fakeAssetLoader(String assetKey) async => null;

void main() {
  group("LAN TLS, Bearer Auth, Host & Origin Hardening", () {
    late EdgeHttpServer server;
    late int port;

    setUp(() async {
      server = EdgeHttpServer(
        webAssetLoader: (key) async {
          if (key == "assets/web/index.html") {
            return utf8.encode("<html><body>Droid Edge</body></html>");
          }
          final str = await _fakeAssetLoader(key);
          return str == null ? null : utf8.encode(str);
        },
      );
      port = await server.start(port: 0, bindAddress: "127.0.0.1");
    });

    tearDown(() async {
      await server.dispose();
    });

    test("unpaired clients receive 401 with WWW-Authenticate on all /v1 routes",
        () async {
      final client = HttpClient();
      addTearDown(client.close);

      for (final target in [
        ("GET", "/v1/health"),
        ("GET", "/v1/status"),
        ("GET", "/v1/models"),
        ("GET", "/v1/ai/capabilities"),
        ("POST", "/v1/ocr"),
        ("POST", "/v1/ai/capabilities"),
        ("POST", "/v1/chat/completions"),
      ]) {
        final req = await client.open(target.$1, "127.0.0.1", port, target.$2);
        final res = await req.close();
        final body = jsonDecode(await utf8.decoder.bind(res).join())
            as Map<String, dynamic>;
        expect(res.statusCode, HttpStatus.unauthorized, reason: target.$2);
        expect(res.headers.value("www-authenticate"), startsWith("Bearer"));
        expect(body["error"], "unauthorized");
      }
    });

    test("rejects unexpected Host header with 403 forbidden_host", () async {
      final client = HttpClient();
      addTearDown(client.close);

      final req = await client.get("127.0.0.1", port, "/v1/status");
      req.headers.set(HttpHeaders.hostHeader, "evil.rebind.example:$port");
      req.headers.set(
        HttpHeaders.authorizationHeader,
        "Bearer ${server.authToken}",
      );
      final res = await req.close();
      final body = jsonDecode(await utf8.decoder.bind(res).join())
          as Map<String, dynamic>;

      expect(res.statusCode, HttpStatus.forbidden);
      expect(body["error"], "forbidden_host");
    });

    test(
        "rejects OPTIONS preflight and cross-origin Origin headers with 403 and emits no wildcard CORS",
        () async {
      final client = HttpClient();
      addTearDown(client.close);

      final optReq =
          await client.open("OPTIONS", "127.0.0.1", port, "/v1/status");
      optReq.headers.set("origin", "https://attacker.example");
      final optRes = await optReq.close();
      expect(optRes.statusCode, HttpStatus.forbidden);
      expect(optRes.headers.value("access-control-allow-origin"), isNull);

      final crossReq = await client.post("127.0.0.1", port, "/v1/ocr");
      crossReq.headers.set("origin", "https://attacker.example");
      crossReq.headers.set(
        HttpHeaders.authorizationHeader,
        "Bearer ${server.authToken}",
      );
      final crossRes = await crossReq.close();
      final crossBody = jsonDecode(await utf8.decoder.bind(crossRes).join())
          as Map<String, dynamic>;
      expect(crossRes.statusCode, HttpStatus.forbidden);
      expect(crossRes.headers.value("access-control-allow-origin"), isNull);
      expect(crossBody["error"], "forbidden_origin");

      // Same-origin browser requests from the bound authority are permitted.
      final sameOriginReq = await client.get("127.0.0.1", port, "/v1/status");
      sameOriginReq.headers.set("origin", "http://127.0.0.1:$port");
      sameOriginReq.headers.set(
        HttpHeaders.authorizationHeader,
        "Bearer ${server.authToken}",
      );
      final sameOriginRes = await sameOriginReq.close();
      expect(sameOriginRes.statusCode, HttpStatus.ok);
      expect(sameOriginRes.headers.value("access-control-allow-origin"), isNull);
    });

    test(
        "rejects non-JSON Content-Type on capabilities and chat completions with 415",
        () async {
      final client = HttpClient();
      addTearDown(client.close);

      for (final path in ["/v1/ai/capabilities", "/v1/chat/completions"]) {
        final req = await client.post("127.0.0.1", port, path);
        req.headers.set(
          HttpHeaders.authorizationHeader,
          "Bearer ${server.authToken}",
        );
        req.headers.set(HttpHeaders.contentTypeHeader, "text/plain");
        req.write("{\"tier2_enabled\": true}");
        final res = await req.close();
        final body = jsonDecode(await utf8.decoder.bind(res).join())
            as Map<String, dynamic>;
        expect(res.statusCode, HttpStatus.unsupportedMediaType, reason: path);
        expect(body["error"], "unsupported_media_type");
      }
    });

    test("serves static Web UI shell without auth and includes security headers",
        () async {
      final client = HttpClient();
      addTearDown(client.close);

      final req = await client.get("127.0.0.1", port, "/");
      final res = await req.close();
      final body = await utf8.decoder.bind(res).join();

      expect(res.statusCode, HttpStatus.ok);
      expect(body, contains("Droid Edge"));
      expect(res.headers.value("x-content-type-options"), "nosniff");
      expect(res.headers.value("x-frame-options"), "DENY");
      expect(
        res.headers.value("content-security-policy"),
        contains("frame-ancestors 'none'"),
      );
      expect(res.headers.value("access-control-allow-origin"), isNull);
    });

    test("rate limits repeated failed authentication attempts with 429",
        () async {
      final client = HttpClient();
      addTearDown(client.close);

      for (var i = 0; i < 20; i++) {
        final req = await client.get("127.0.0.1", port, "/v1/status");
        req.headers.set(HttpHeaders.authorizationHeader, "Bearer wrong-$i");
        final res = await req.close();
        await res.drain<void>();
        expect(res.statusCode, HttpStatus.unauthorized);
      }

      final blockedReq = await client.get("127.0.0.1", port, "/v1/status");
      blockedReq.headers.set(
        HttpHeaders.authorizationHeader,
        "Bearer ${server.authToken}",
      );
      final blockedRes = await blockedReq.close();
      expect(blockedRes.statusCode, 429);
      expect(blockedRes.headers.value("retry-after"), isNotNull);
    });

    test(
        "LocalCaService mints verifiable TLS chain and leaf cert rotation keeps same Root CA",
        () async {
      final keyStore = InMemorySecureKeyStore();
      final caService = LocalCaService(keyStore: keyStore);
      final tokenService = PairingTokenService(keyStore: keyStore);
      final token = await tokenService.getOrCreateToken();

      final bundle1 = await caService.mintTlsBundle(
        ipAddresses: const ["192.168.1.42", "127.0.0.1"],
        hostname: "android-edge.local",
      );
      final bundle2 = await caService.mintTlsBundle(
        ipAddresses: const ["192.168.1.99", "127.0.0.1"],
        hostname: "android-edge.local",
      );

      expect(bundle1.caCertPem, equals(bundle2.caCertPem));
      expect(
        bundle1.caFingerprintSha256,
        equals(bundle2.caFingerprintSha256),
      );
      expect(bundle1.leafCertPem, isNot(equals(bundle2.leafCertPem)));

      final tlsServer = EdgeHttpServer(authToken: token);
      addTearDown(tlsServer.dispose);
      final tlsPort = await tlsServer.start(
        port: 0,
        bindAddress: "127.0.0.1",
        securityContext: caService.buildServerSecurityContext(bundle2),
        allowedHosts: const {"127.0.0.1", "localhost", "android-edge.local"},
      );

      // Trust ONLY the exported Local Root CA (no badCertificateCallback).
      final clientContext = SecurityContext()
        ..setTrustedCertificatesBytes(utf8.encode(bundle2.caCertPem));
      final tlsClient = HttpClient(context: clientContext);
      addTearDown(tlsClient.close);

      final getReq = await tlsClient.getUrl(
        Uri.parse("https://127.0.0.1:$tlsPort/v1/status"),
      );
      getReq.headers.set(HttpHeaders.authorizationHeader, "Bearer $token");
      final getRes = await getReq.close();
      final statusJson = jsonDecode(await utf8.decoder.bind(getRes).join())
          as Map<String, dynamic>;
      expect(getRes.statusCode, HttpStatus.ok);
      expect(statusJson["status"], "ok");

      final postReq = await tlsClient.postUrl(
        Uri.parse("https://127.0.0.1:$tlsPort/v1/ai/capabilities"),
      );
      postReq.headers.set(HttpHeaders.authorizationHeader, "Bearer $token");
      postReq.headers.set(
        HttpHeaders.contentTypeHeader,
        "application/json; charset=utf-8",
      );
      postReq.write(jsonEncode({"tier2_enabled": false}));
      final postRes = await postReq.close();
      expect(postRes.statusCode, HttpStatus.ok);
    });

    test("PairingTokenService verifyToken uses constant-time digest check", () {
      const token = "des_abcdefghijklmnopqrstuvwxyz0123456789ABCDEF";
      expect(PairingTokenService.verifyToken(token, token), isTrue);
      expect(PairingTokenService.verifyToken("${token}x", token), isFalse);
      expect(PairingTokenService.verifyToken("", token), isFalse);
      expect(PairingTokenService.verifyToken(token, ""), isFalse);
    });
  });
}
