import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:droid_edge_server/engines/entity_extraction_engine.dart";
import "package:droid_edge_server/engines/image_payload_processor.dart";
import "package:droid_edge_server/engines/local_genai_engine.dart";
import "package:droid_edge_server/engines/ocr_engine.dart";
import "package:droid_edge_server/engines/pdf_rasterizer.dart";
import "package:droid_edge_server/engines/spatial_table_reconstructor.dart";
import "package:droid_edge_server/engines/structured_extraction_engine.dart";
import "package:droid_edge_server/models/geometry_models.dart";
import "package:droid_edge_server/models/ocr_result.dart";
import "package:droid_edge_server/models/openai_vision_models.dart";
import "package:droid_edge_server/server/edge_http_server.dart";
import "package:flutter_test/flutter_test.dart";
import "package:image/image.dart" as img;

enum _SampleScene {
  table,
  receipt,
  businessCard,
  generalText,
}

class _Phase6FakeOcrEngine implements OcrEngine {
  _SampleScene scene = _SampleScene.generalText;
  int callCount = 0;

  @override
  Future<OcrResult> processImage(
    PreparedImagePayload payload, {
    OcrScript script = OcrScript.latin,
  }) async {
    callCount++;
    switch (scene) {
      case _SampleScene.table:
        return _tableOcrResult(script: script.name);
      case _SampleScene.receipt:
        return _receiptOcrResult(script: script.name);
      case _SampleScene.businessCard:
        return _businessCardOcrResult(script: script.name);
      case _SampleScene.generalText:
        return OcrResult(
          text: "Droid Edge Server\n100% Offline OCR",
          script: script.name,
          blocks: const [
            OcrTextBlock(
              text: "Droid Edge Server\n100% Offline OCR",
              boundingBox: BoundingBoxRect(
                left: 20,
                top: 20,
                right: 300,
                bottom: 80,
              ),
              lines: [
                OcrTextLine(
                  text: "Droid Edge Server",
                  boundingBox: BoundingBoxRect(
                    left: 20,
                    top: 20,
                    right: 260,
                    bottom: 42,
                  ),
                ),
                OcrTextLine(
                  text: "100% Offline OCR",
                  boundingBox: BoundingBoxRect(
                    left: 20,
                    top: 52,
                    right: 240,
                    bottom: 74,
                  ),
                ),
              ],
            ),
          ],
          detectedLanguages: const ["en"],
          inferenceMs: 11,
          imageWidth: payload.width ?? 400,
          imageHeight: payload.height ?? 200,
        );
    }
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

OcrResult _tableOcrResult({String script = "latin"}) {
  return OcrResult(
    text: "Item Name Qty Price Total\n"
        "Espresso Shot 2 \$3.50 \$7.00\n"
        "Butter Croissant 1 \$4.25 \$4.25",
    script: script,
    detectedLanguages: const ["en"],
    inferenceMs: 12,
    imageWidth: 500,
    imageHeight: 220,
    blocks: const [
      OcrTextBlock(
        text: "Table Header",
        boundingBox: BoundingBoxRect(left: 20, top: 20, right: 460, bottom: 42),
        lines: [
          OcrTextLine(
            text: "Item Name Qty Price Total",
            boundingBox: BoundingBoxRect(
              left: 20,
              top: 20,
              right: 460,
              bottom: 42,
            ),
            elements: [
              OcrTextElement(
                text: "Item",
                boundingBox: BoundingBoxRect(
                  left: 20,
                  top: 20,
                  right: 58,
                  bottom: 40,
                ),
              ),
              OcrTextElement(
                text: "Name",
                boundingBox: BoundingBoxRect(
                  left: 65,
                  top: 20,
                  right: 115,
                  bottom: 40,
                ),
              ),
              OcrTextElement(
                text: "Qty",
                boundingBox: BoundingBoxRect(
                  left: 205,
                  top: 20,
                  right: 235,
                  bottom: 40,
                ),
              ),
              OcrTextElement(
                text: "Price",
                boundingBox: BoundingBoxRect(
                  left: 295,
                  top: 20,
                  right: 342,
                  bottom: 40,
                ),
              ),
              OcrTextElement(
                text: "Total",
                boundingBox: BoundingBoxRect(
                  left: 410,
                  top: 20,
                  right: 458,
                  bottom: 40,
                ),
              ),
            ],
          ),
        ],
      ),
      OcrTextBlock(
        text: "Row 1",
        boundingBox: BoundingBoxRect(left: 20, top: 65, right: 460, bottom: 88),
        lines: [
          OcrTextLine(
            text: "Espresso Shot 2 \$3.50 \$7.00",
            boundingBox: BoundingBoxRect(
              left: 20,
              top: 65,
              right: 460,
              bottom: 88,
            ),
            elements: [
              OcrTextElement(
                text: "Espresso",
                boundingBox: BoundingBoxRect(
                  left: 20,
                  top: 65,
                  right: 92,
                  bottom: 85,
                ),
              ),
              OcrTextElement(
                text: "Shot",
                boundingBox: BoundingBoxRect(
                  left: 99,
                  top: 65,
                  right: 138,
                  bottom: 85,
                ),
              ),
              OcrTextElement(
                text: "2",
                boundingBox: BoundingBoxRect(
                  left: 215,
                  top: 65,
                  right: 226,
                  bottom: 85,
                ),
              ),
              OcrTextElement(
                text: "\$3.50",
                boundingBox: BoundingBoxRect(
                  left: 295,
                  top: 65,
                  right: 344,
                  bottom: 85,
                ),
              ),
              OcrTextElement(
                text: "\$7.00",
                boundingBox: BoundingBoxRect(
                  left: 412,
                  top: 65,
                  right: 458,
                  bottom: 85,
                ),
              ),
            ],
          ),
        ],
      ),
      OcrTextBlock(
        text: "Row 2",
        boundingBox: BoundingBoxRect(
          left: 20,
          top: 110,
          right: 460,
          bottom: 133,
        ),
        lines: [
          OcrTextLine(
            text: "Butter Croissant 1 \$4.25 \$4.25",
            boundingBox: BoundingBoxRect(
              left: 20,
              top: 110,
              right: 460,
              bottom: 133,
            ),
            elements: [
              OcrTextElement(
                text: "Butter",
                boundingBox: BoundingBoxRect(
                  left: 20,
                  top: 110,
                  right: 74,
                  bottom: 130,
                ),
              ),
              OcrTextElement(
                text: "Croissant",
                boundingBox: BoundingBoxRect(
                  left: 81,
                  top: 110,
                  right: 158,
                  bottom: 130,
                ),
              ),
              OcrTextElement(
                text: "1",
                boundingBox: BoundingBoxRect(
                  left: 215,
                  top: 110,
                  right: 226,
                  bottom: 130,
                ),
              ),
              OcrTextElement(
                text: "\$4.25",
                boundingBox: BoundingBoxRect(
                  left: 295,
                  top: 110,
                  right: 344,
                  bottom: 130,
                ),
              ),
              OcrTextElement(
                text: "\$4.25",
                boundingBox: BoundingBoxRect(
                  left: 412,
                  top: 110,
                  right: 458,
                  bottom: 130,
                ),
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

OcrResult _receiptOcrResult({String script = "latin"}) {
  const fullText = "TAX INVOICE\n"
      "Acme Coffee Roasters\n"
      "GSTIN: 29ABCDE1234F1Z5\n"
      "Invoice No: INV-2026-409\n"
      "Date: 2026-11-17\n"
      "2 x Cold Brew   ₹400.00\n"
      "1 x Almond Tart ₹180.00\n"
      "Subtotal: ₹580.00\n"
      "CGST 2.5%: ₹14.50\n"
      "SGST 2.5%: ₹14.50\n"
      "Grand Total: ₹609.00\n"
      "Paid via acme@okhdfcbank";

  return OcrResult(
    text: fullText,
    script: script,
    detectedLanguages: const ["en"],
    inferenceMs: 15,
    imageWidth: 480,
    imageHeight: 500,
    blocks: const [
      OcrTextBlock(
        text: fullText,
        lines: [
          OcrTextLine(
            text: "TAX INVOICE",
            boundingBox: BoundingBoxRect(
              left: 160,
              top: 20,
              right: 310,
              bottom: 40,
            ),
          ),
          OcrTextLine(
            text: "Acme Coffee Roasters",
            boundingBox: BoundingBoxRect(
              left: 110,
              top: 50,
              right: 370,
              bottom: 72,
            ),
          ),
          OcrTextLine(
            text: "GSTIN: 29ABCDE1234F1Z5",
            boundingBox: BoundingBoxRect(
              left: 20,
              top: 85,
              right: 260,
              bottom: 105,
            ),
          ),
          OcrTextLine(
            text: "Invoice No: INV-2026-409",
            boundingBox: BoundingBoxRect(
              left: 20,
              top: 115,
              right: 270,
              bottom: 135,
            ),
          ),
          OcrTextLine(
            text: "Date: 2026-11-17",
            boundingBox: BoundingBoxRect(
              left: 20,
              top: 145,
              right: 200,
              bottom: 165,
            ),
          ),
          OcrTextLine(
            text: "2 x Cold Brew",
            boundingBox: BoundingBoxRect(
              left: 20,
              top: 185,
              right: 170,
              bottom: 205,
            ),
          ),
          OcrTextLine(
            text: "₹400.00",
            boundingBox: BoundingBoxRect(
              left: 360,
              top: 185,
              right: 450,
              bottom: 205,
            ),
          ),
          OcrTextLine(
            text: "1 x Almond Tart",
            boundingBox: BoundingBoxRect(
              left: 20,
              top: 215,
              right: 190,
              bottom: 235,
            ),
          ),
          OcrTextLine(
            text: "₹180.00",
            boundingBox: BoundingBoxRect(
              left: 360,
              top: 215,
              right: 450,
              bottom: 235,
            ),
          ),
          OcrTextLine(
            text: "Subtotal:",
            boundingBox: BoundingBoxRect(
              left: 20,
              top: 255,
              right: 110,
              bottom: 275,
            ),
          ),
          OcrTextLine(
            text: "₹580.00",
            boundingBox: BoundingBoxRect(
              left: 360,
              top: 255,
              right: 450,
              bottom: 275,
            ),
          ),
          OcrTextLine(
            text: "CGST 2.5%:",
            boundingBox: BoundingBoxRect(
              left: 20,
              top: 285,
              right: 130,
              bottom: 305,
            ),
          ),
          OcrTextLine(
            text: "₹14.50",
            boundingBox: BoundingBoxRect(
              left: 370,
              top: 285,
              right: 450,
              bottom: 305,
            ),
          ),
          OcrTextLine(
            text: "SGST 2.5%:",
            boundingBox: BoundingBoxRect(
              left: 20,
              top: 315,
              right: 130,
              bottom: 335,
            ),
          ),
          OcrTextLine(
            text: "₹14.50",
            boundingBox: BoundingBoxRect(
              left: 370,
              top: 315,
              right: 450,
              bottom: 335,
            ),
          ),
          OcrTextLine(
            text: "Grand Total:",
            boundingBox: BoundingBoxRect(
              left: 20,
              top: 350,
              right: 145,
              bottom: 372,
            ),
          ),
          OcrTextLine(
            text: "₹609.00",
            boundingBox: BoundingBoxRect(
              left: 355,
              top: 350,
              right: 450,
              bottom: 372,
            ),
          ),
          OcrTextLine(
            text: "Paid via acme@okhdfcbank",
            boundingBox: BoundingBoxRect(
              left: 20,
              top: 390,
              right: 280,
              bottom: 410,
            ),
          ),
        ],
      ),
    ],
  );
}

OcrResult _businessCardOcrResult({String script = "latin"}) {
  const fullText = "Priya Nair\n"
      "Principal Systems Architect\n"
      "CloudScale Technologies Pvt. Ltd.\n"
      "Tel: +91 98765 43210\n"
      "Email: priya.nair@cloudscale.io\n"
      "https://cloudscale.io\n"
      "42 MG Road, Bengaluru 560001";

  return OcrResult(
    text: fullText,
    script: script,
    detectedLanguages: const ["en"],
    inferenceMs: 9,
    imageWidth: 500,
    imageHeight: 300,
    blocks: const [
      OcrTextBlock(
        text: fullText,
        lines: [
          OcrTextLine(
            text: "Priya Nair",
            boundingBox: BoundingBoxRect(
              left: 30,
              top: 25,
              right: 220,
              bottom: 58,
            ),
          ),
          OcrTextLine(
            text: "Principal Systems Architect",
            boundingBox: BoundingBoxRect(
              left: 30,
              top: 64,
              right: 300,
              bottom: 84,
            ),
          ),
          OcrTextLine(
            text: "CloudScale Technologies Pvt. Ltd.",
            boundingBox: BoundingBoxRect(
              left: 30,
              top: 94,
              right: 360,
              bottom: 116,
            ),
          ),
          OcrTextLine(
            text: "Tel: +91 98765 43210",
            boundingBox: BoundingBoxRect(
              left: 30,
              top: 140,
              right: 260,
              bottom: 158,
            ),
          ),
          OcrTextLine(
            text: "Email: priya.nair@cloudscale.io",
            boundingBox: BoundingBoxRect(
              left: 30,
              top: 168,
              right: 310,
              bottom: 186,
            ),
          ),
          OcrTextLine(
            text: "https://cloudscale.io",
            boundingBox: BoundingBoxRect(
              left: 30,
              top: 196,
              right: 240,
              bottom: 214,
            ),
          ),
          OcrTextLine(
            text: "42 MG Road, Bengaluru 560001",
            boundingBox: BoundingBoxRect(
              left: 30,
              top: 224,
              right: 340,
              bottom: 242,
            ),
          ),
        ],
      ),
    ],
  );
}

Uint8List _createSamplePngBytes() {
  final image = img.Image(width: 64, height: 64);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  return Uint8List.fromList(img.encodePng(image));
}

Future<Uint8List?> _diskAssetLoader(String assetKey) async {
  final file = File(assetKey);
  if (!await file.exists()) return null;
  return file.readAsBytes();
}

void main() {
  group("Phase 6 Tier 1 Engines", () {
    test("SpatialTableReconstructor builds GFM Markdown with numeric alignment", () {
      final table = SpatialTableReconstructor.reconstruct(_tableOcrResult());

      expect(table.headers, ["Item Name", "Qty", "Price", "Total"]);
      expect(table.columnAlignments, ["left", "right", "right", "right"]);
      expect(table.rowCount, 2);
      expect(table.rows[0], ["Espresso Shot", "2", "\$3.50", "\$7.00"]);
      expect(table.rows[1], ["Butter Croissant", "1", "\$4.25", "\$4.25"]);
      expect(
        table.markdown,
        "| Item Name | Qty | Price | Total |\n"
        "| --- | ---: | ---: | ---: |\n"
        "| Espresso Shot | 2 | \$3.50 | \$7.00 |\n"
        "| Butter Croissant | 1 | \$4.25 | \$4.25 |",
      );
    });

    test("StructuredExtractionEngine extracts receipt/tax invoice JSON accurately", () async {
      final extractor = HybridEntityExtractionEngine(enableNativeMlKit: false);
      final ocr = _receiptOcrResult();
      final entities = await extractor.extractEntities(ocr.text);
      final receipt = StructuredExtractionEngine.extractReceiptOrBill(
        ocr,
        entities,
      );

      expect(receipt.documentType, "tax_invoice");
      expect(receipt.merchantName, "Acme Coffee Roasters");
      expect(receipt.invoiceNumber, "INV-2026-409");
      expect(receipt.date, "2026-11-17");
      expect(receipt.currency, "INR");
      expect(receipt.subtotal, 580.0);
      expect(receipt.taxAmount, 29.0);
      expect(receipt.totalAmount, 609.0);
      expect(receipt.taxIds, contains("29ABCDE1234F1Z5"));
      expect(receipt.paymentMethods, contains("acme@okhdfcbank"));
      expect(receipt.lineItems, hasLength(2));
      expect(receipt.lineItems.first.description, "Cold Brew");
      expect(receipt.lineItems.first.quantity, 2);
      expect(receipt.lineItems.first.amount, 400.0);
    });

    test("StructuredExtractionEngine produces valid RFC 2426 vCard 3.0", () async {
      final extractor = HybridEntityExtractionEngine(enableNativeMlKit: false);
      final ocr = _businessCardOcrResult();
      final entities = await extractor.extractEntities(ocr.text);
      final card = StructuredExtractionEngine.extractBusinessCard(
        ocr,
        entities,
      );

      expect(card.fullName, "Priya Nair");
      expect(card.firstName, "Priya");
      expect(card.lastName, "Nair");
      expect(card.title, "Principal Systems Architect");
      expect(card.organization, "CloudScale Technologies Pvt. Ltd.");
      expect(card.phones, contains("+91 98765 43210"));
      expect(card.emails, contains("priya.nair@cloudscale.io"));
      expect(card.urls, contains("https://cloudscale.io"));
      expect(card.vcardText, startsWith("BEGIN:VCARD\nVERSION:3.0"));
      expect(card.vcardText, contains("N:Nair;Priya;;;"));
      expect(card.vcardText, contains("FN:Priya Nair"));
      expect(card.vcardText, contains("ORG:CloudScale Technologies Pvt. Ltd."));
      expect(card.vcardText, contains("TITLE:Principal Systems Architect"));
      expect(card.vcardText, endsWith("END:VCARD"));
    });
  });

  group("Phase 6 OpenAI HTTP Gateway & 3-Tier Fallback", () {
    late _Phase6FakeOcrEngine fakeOcr;
    late ThreeTierGenAiRuntime genAiRuntime;
    late EdgeHttpServer server;
    late int port;
    late String sampleDataUri;

    setUp(() async {
      fakeOcr = _Phase6FakeOcrEngine();
      genAiRuntime = ThreeTierGenAiRuntime(
        entityExtractionEngine: HybridEntityExtractionEngine(
          enableNativeMlKit: false,
        ),
        deviceRamGbProvider: () async => 8.0,
      );
      server = EdgeHttpServer(
        ocrEngine: fakeOcr,
        pdfRasterizer: _NoOpPdfRasterizer(),
        entityExtractionEngine: HybridEntityExtractionEngine(
          enableNativeMlKit: false,
        ),
        localGenAiEngine: genAiRuntime,
        webAssetLoader: _diskAssetLoader,
      );
      port = await server.start(port: 0);
      sampleDataUri =
          "data:image/png;base64,${base64Encode(_createSamplePngBytes())}";
    });

    tearDown(() async {
      await server.dispose();
    });

    Future<({int status, HttpHeaders headers, String body})> postJson(
      String path,
      Map<String, dynamic> payload,
    ) async {
      final client = HttpClient();
      try {
        final req = await client.post("127.0.0.1", port, path);
        req.headers.set(
          HttpHeaders.contentTypeHeader,
          "application/json; charset=utf-8",
        );
        req.add(utf8.encode(jsonEncode(payload)));
        final res = await req.close();
        final body = await utf8.decoder.bind(res).join();
        return (status: res.statusCode, headers: res.headers, body: body);
      } finally {
        client.close();
      }
    }

    test("GET /v1/models and OPTIONS preflight return OpenAI model list & CORS", () async {
      final client = HttpClient();
      addTearDown(client.close);

      final optReq = await client.open("OPTIONS", "127.0.0.1", port, "/v1/chat/completions");
      final optRes = await optReq.close();
      expect(optRes.statusCode, HttpStatus.ok);
      expect(optRes.headers.value("access-control-allow-origin"), "*");

      final req = await client.get("127.0.0.1", port, "/v1/models");
      final res = await req.close();
      final json = jsonDecode(await utf8.decoder.bind(res).join())
          as Map<String, dynamic>;

      expect(res.statusCode, HttpStatus.ok);
      expect(json["object"], "list");
      final ids = (json["data"] as List<dynamic>)
          .map((m) => (m as Map<String, dynamic>)["id"])
          .toList();
      expect(
        ids,
        containsAll([
          "local-edge-vision",
          "local-ocr",
          "local-structured",
          "local-table",
          "local-vcard",
        ]),
      );
    });

    test("POST /v1/chat/completions routes table, receipt JSON, vCard, and OCR intents", () async {
      final jobs = <OpenAiJobRecord>[];
      final sub = server.openAiJobs.listen(jobs.add);
      addTearDown(sub.cancel);

      // 1. Table -> Markdown
      fakeOcr.scene = _SampleScene.table;
      final tableRes = await postJson("/v1/chat/completions", {
        "model": "gpt-4o",
        "messages": [
          {
            "role": "user",
            "content": [
              {"type": "text", "text": "Extract the table as Markdown"},
              {
                "type": "image_url",
                "image_url": {"url": sampleDataUri},
              },
            ],
          },
        ],
      });
      expect(tableRes.status, HttpStatus.ok);
      final tableJson = jsonDecode(tableRes.body) as Map<String, dynamic>;
      expect(tableJson["object"], "chat.completion");
      expect(tableJson["model"], "gpt-4o");
      final tableContent =
          (tableJson["choices"] as List).first["message"]["content"] as String;
      expect(tableContent, contains("| Item Name | Qty | Price | Total |"));
      expect(tableContent, contains("| Espresso Shot | 2 | \$3.50 | \$7.00 |"));

      // 2. Receipt -> Structured JSON
      fakeOcr.scene = _SampleScene.receipt;
      final receiptRes = await postJson("/v1/chat/completions", {
        "model": "gpt-4-vision-preview",
        "response_format": {"type": "json_object"},
        "messages": [
          {
            "role": "user",
            "content": [
              {"type": "text", "text": "Parse receipt JSON"},
              {
                "type": "image_url",
                "image_url": {"url": sampleDataUri},
              },
            ],
          },
        ],
      });
      expect(receiptRes.status, HttpStatus.ok);
      final receiptWrapper =
          jsonDecode(receiptRes.body) as Map<String, dynamic>;
      final receiptPayload = jsonDecode(
        (receiptWrapper["choices"] as List).first["message"]["content"]
            as String,
      ) as Map<String, dynamic>;
      expect(receiptPayload["merchant_name"], "Acme Coffee Roasters");
      expect(receiptPayload["total_amount"], 609.0);
      expect(receiptPayload["tax_amount"], 29.0);

      // 3. Business card -> vCard 3.0
      fakeOcr.scene = _SampleScene.businessCard;
      final vcardRes = await postJson("/v1/chat/completions", {
        "model": "local-ocr",
        "messages": [
          {
            "role": "user",
            "content": [
              {"type": "text", "text": "Extract business card as vCard"},
              {
                "type": "image_url",
                "image_url": {"url": sampleDataUri},
              },
            ],
          },
        ],
      });
      expect(vcardRes.status, HttpStatus.ok);
      final vcardWrapper = jsonDecode(vcardRes.body) as Map<String, dynamic>;
      final vcardContent =
          (vcardWrapper["choices"] as List).first["message"]["content"]
              as String;
      expect(vcardContent, contains("BEGIN:VCARD"));
      expect(vcardContent, contains("FN:Priya Nair"));
      expect(vcardContent, contains("END:VCARD"));

      // 4. Default OCR with response_format json_object guarantee
      fakeOcr.scene = _SampleScene.generalText;
      final ocrJsonRes = await postJson("/v1/chat/completions", {
        "model": "local-ocr",
        "messages": [
          {
            "role": "user",
            "content": [
              {"type": "text", "text": "Transcribe text"},
              {
                "type": "image_url",
                "image_url": {"url": sampleDataUri},
              },
            ],
          },
        ],
      });
      expect(ocrJsonRes.status, HttpStatus.ok);
      final ocrJson = jsonDecode(ocrJsonRes.body) as Map<String, dynamic>;
      expect(
        (ocrJson["choices"] as List).first["message"]["content"],
        "Droid Edge Server\n100% Offline OCR",
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(jobs, hasLength(4));
      expect(
        jobs.map((j) => j.intent).toList(),
        [
          ExtractionIntent.table,
          ExtractionIntent.receipt,
          ExtractionIntent.vcard,
          ExtractionIntent.ocr,
        ],
      );
    });

    test("POST /v1/chat/completions supports SSE stream: true", () async {
      fakeOcr.scene = _SampleScene.table;
      final res = await postJson("/v1/chat/completions", {
        "model": "local-table",
        "stream": true,
        "messages": [
          {
            "role": "user",
            "content": [
              {"type": "text", "text": "Extract table"},
              {
                "type": "image_url",
                "image_url": {"url": sampleDataUri},
              },
            ],
          },
        ],
      });

      expect(res.status, HttpStatus.ok);
      expect(res.headers.contentType?.mimeType, "text/event-stream");
      expect(res.body, contains("chat.completion.chunk"));
      expect(res.body.trim(), endsWith("data: [DONE]"));

      final assembled = StringBuffer();
      for (final line in const LineSplitter().convert(res.body)) {
        if (!line.startsWith("data: ") || line == "data: [DONE]") continue;
        final chunk =
            jsonDecode(line.substring(6)) as Map<String, dynamic>;
        final delta =
            (chunk["choices"] as List).first["delta"] as Map<String, dynamic>;
        if (delta["content"] is String) {
          assembled.write(delta["content"] as String);
        }
      }
      expect(assembled.toString(), contains("| Espresso Shot | 2 |"));
    });

    test("Tier 2 BUSY/error or invalid JSON falls back gracefully to Tier 1", () async {
      final failingGenAi = ThreeTierGenAiRuntime(
        entityExtractionEngine: HybridEntityExtractionEngine(
          enableNativeMlKit: false,
        ),
        initialTier2Enabled: true,
        tier2StatusChecker: () async => AiFeatureAvailability.available,
        tier2Runner: (_) async => throw StateError("AICore BUSY"),
      );
      final fallbackServer = EdgeHttpServer(
        ocrEngine: _Phase6FakeOcrEngine()..scene = _SampleScene.receipt,
        pdfRasterizer: _NoOpPdfRasterizer(),
        entityExtractionEngine: HybridEntityExtractionEngine(
          enableNativeMlKit: false,
        ),
        localGenAiEngine: failingGenAi,
      );
      final fPort = await fallbackServer.start(port: 0);
      addTearDown(fallbackServer.dispose);

      final client = HttpClient();
      addTearDown(client.close);
      final req = await client.post("127.0.0.1", fPort, "/v1/chat/completions");
      req.headers.set(HttpHeaders.contentTypeHeader, "application/json");
      req.add(
        utf8.encode(
          jsonEncode({
            "model": "gpt-4o",
            "response_format": {"type": "json_object"},
            "messages": [
              {
                "role": "user",
                "content": [
                  {"type": "text", "text": "Extract receipt JSON"},
                  {
                    "type": "image_url",
                    "image_url": {"url": sampleDataUri},
                  },
                ],
              },
            ],
          }),
        ),
      );

      final res = await req.close();
      final body = jsonDecode(await utf8.decoder.bind(res).join())
          as Map<String, dynamic>;

      expect(res.statusCode, HttpStatus.ok);
      expect(body["x_edge_metadata"]["tier_used"], "tier1_deterministic");
      expect(body["x_edge_metadata"]["fallback_triggered"], true);
      final contentJson = jsonDecode(
        (body["choices"] as List).first["message"]["content"] as String,
      ) as Map<String, dynamic>;
      expect(contentJson["merchant_name"], "Acme Coffee Roasters");
    });

    test("Rejects remote HTTP image URLs to preserve 100% offline guarantee", () async {
      final res = await postJson("/v1/chat/completions", {
        "model": "gpt-4o",
        "messages": [
          {
            "role": "user",
            "content": [
              {"type": "text", "text": "OCR this"},
              {
                "type": "image_url",
                "image_url": {"url": "https://example.com/secret.png"},
              },
            ],
          },
        ],
      });

      expect(res.status, HttpStatus.badRequest);
      final err = jsonDecode(res.body) as Map<String, dynamic>;
      expect(err["error"]["message"], contains("100% offline"));
    });

    test("Web UI serves AI Extract mode backed by /v1/chat/completions", () async {
      final client = HttpClient();
      addTearDown(client.close);

      final htmlRes = await (await client.get("127.0.0.1", port, "/")).close();
      final html = await utf8.decoder.bind(htmlRes).join();
      expect(html, contains("AI Extract"));
      expect(html, contains("id=\"aiControlsGroup\""));

      final jsRes =
          await (await client.get("127.0.0.1", port, "/app.js")).close();
      final js = await utf8.decoder.bind(jsRes).join();
      expect(js, contains("/v1/chat/completions"));
    });
  });
}
