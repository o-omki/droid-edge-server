import "dart:typed_data";

import "package:droid_edge_server/engines/entity_extraction_engine.dart";
import "package:droid_edge_server/engines/face_detection_engine.dart";
import "package:droid_edge_server/engines/image_payload_processor.dart";
import "package:droid_edge_server/engines/ocr_engine.dart";
import "package:droid_edge_server/engines/pdf_rasterizer.dart";
import "package:droid_edge_server/engines/pii_redaction_engine.dart";
import "package:droid_edge_server/models/document_pipeline_models.dart";
import "package:droid_edge_server/models/geometry_models.dart";
import "package:droid_edge_server/models/ocr_result.dart";
import "package:droid_edge_server/models/openai_vision_models.dart";
import "package:flutter_test/flutter_test.dart";
import "package:image/image.dart" as img;

Uint8List _createBlankTestPng({int width = 640, int height = 440}) {
  final canvas = img.Image(width: width, height: height, numChannels: 3);
  img.fill(canvas, color: img.ColorRgb8(248, 250, 252));
  return Uint8List.fromList(img.encodePng(canvas));
}

OcrTextLine _line(
  String text, {
  required double left,
  required double top,
  required double right,
  required double bottom,
  List<OcrTextElement> elements = const [],
}) {
  return OcrTextLine(
    text: text,
    boundingBox: BoundingBoxRect(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
    ),
    elements: elements,
  );
}

void _expectMaskedPixel(img.Image image, int x, int y) {
  final px = image.getPixel(x, y);
  expect(px.r, 17, reason: "Expected masked R=17 at ($x, $y)");
  expect(px.g, 22, reason: "Expected masked G=22 at ($x, $y)");
  expect(px.b, 29, reason: "Expected masked B=29 at ($x, $y)");
}

void _expectUnmaskedBrightPixel(img.Image image, int x, int y) {
  final px = image.getPixel(x, y);
  expect(px.r, greaterThan(220), reason: "Expected unmasked pixel at ($x, $y)");
}

void main() {
  group("International PII Redaction", () {
    test(
      "redacts English and bilingual German ID cards while preserving non-PII and adjacent columns",
      () async {
        final englishGermanEngine = PiiRedactionEngine(
          ocrEngine: _FixedOcrEngine(
            const OcrResult(
              text: "BUNDESREPUBLIK TESTKARTE",
              script: "latin",
              detectedLanguages: ["en", "de"],
              inferenceMs: 10,
              imageWidth: 640,
              imageHeight: 440,
              blocks: [
                OcrTextBlock(
                  text: "Header",
                  lines: [
                    OcrTextLine(
                      text: "BUNDESREPUBLIK TESTKARTE",
                      boundingBox: BoundingBoxRect(
                        left: 160,
                        top: 25,
                        right: 520,
                        bottom: 52,
                      ),
                    ),
                  ],
                ),
                OcrTextBlock(
                  text: "Fields",
                  lines: [
                    OcrTextLine(
                      text: "Full Name:",
                      boundingBox: BoundingBoxRect(
                        left: 220,
                        top: 70,
                        right: 320,
                        bottom: 86,
                      ),
                    ),
                    OcrTextLine(
                      text: "ANNA TESTER",
                      boundingBox: BoundingBoxRect(
                        left: 220,
                        top: 90,
                        right: 380,
                        bottom: 112,
                      ),
                    ),
                    OcrTextLine(
                      text: "Secondary Name / Father's Name:",
                      boundingBox: BoundingBoxRect(
                        left: 220,
                        top: 120,
                        right: 450,
                        bottom: 136,
                      ),
                    ),
                    OcrTextLine(
                      text: "KARL TESTER",
                      boundingBox: BoundingBoxRect(
                        left: 220,
                        top: 140,
                        right: 380,
                        bottom: 162,
                      ),
                    ),
                    OcrTextLine(
                      text: "Date of Birth:",
                      boundingBox: BoundingBoxRect(
                        left: 220,
                        top: 170,
                        right: 340,
                        bottom: 186,
                      ),
                    ),
                    OcrTextLine(
                      text: "01.01.1990",
                      boundingBox: BoundingBoxRect(
                        left: 220,
                        top: 190,
                        right: 330,
                        bottom: 210,
                      ),
                    ),
                    OcrTextLine(
                      text: "ID Number:",
                      boundingBox: BoundingBoxRect(
                        left: 220,
                        top: 218,
                        right: 320,
                        bottom: 234,
                      ),
                    ),
                    OcrTextLine(
                      text: "L01X00T47",
                      boundingBox: BoundingBoxRect(
                        left: 220,
                        top: 238,
                        right: 340,
                        bottom: 258,
                      ),
                    ),
                    OcrTextLine(
                      text: "Address / Extra Field:",
                      boundingBox: BoundingBoxRect(
                        left: 220,
                        top: 266,
                        right: 390,
                        bottom: 282,
                      ),
                    ),
                    OcrTextLine(
                      text: "TESTWEG 12, 10115 BERLIN",
                      boundingBox: BoundingBoxRect(
                        left: 220,
                        top: 286,
                        right: 500,
                        bottom: 306,
                      ),
                    ),
                  ],
                ),
                OcrTextBlock(
                  text: "MRZ",
                  lines: [
                    OcrTextLine(
                      text: "IDD<<L01X00T471<<<<<<<<<<<<<<<",
                      boundingBox: BoundingBoxRect(
                        left: 40,
                        top: 345,
                        right: 600,
                        bottom: 367,
                      ),
                    ),
                    OcrTextLine(
                      text: "9001015F3001012TESTER<<ANNA<<<<<<",
                      boundingBox: BoundingBoxRect(
                        left: 40,
                        top: 375,
                        right: 600,
                        bottom: 397,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          faceDetectionEngine: _EmptyFaceEngine(),
          pdfRasterizer: _NoOpPdfRasterizer(),
        );

        final blankPng = _createBlankTestPng();
        final res1 = await englishGermanEngine.redactPayloads(
          [blankPng],
          options: const RedactionOptions(outputFormat: RedactionOutputFormat.json),
        );

        expect(res1.sanitizedText, contains("BUNDESREPUBLIK TESTKARTE"));
        expect(res1.sanitizedText, isNot(contains("ANNA TESTER")));
        expect(res1.sanitizedText, isNot(contains("KARL TESTER")));
        expect(res1.sanitizedText, isNot(contains("01.01.1990")));
        expect(res1.sanitizedText, isNot(contains("L01X00T47")));
        expect(res1.sanitizedText, isNot(contains("TESTWEG 12")));
        expect(res1.sanitizedText, isNot(contains("10115 BERLIN")));
        expect(res1.sanitizedText, isNot(contains("IDD<<")));
        expect(res1.sanitizedText, isNot(contains("9001015F")));
        expect(res1.sanitizedText, contains("[REDACTED NAME]"));
        expect(res1.sanitizedText, contains("[REDACTED DOB]"));
        expect(res1.sanitizedText, contains("[REDACTED ID]"));
        expect(res1.sanitizedText, contains("[REDACTED ADDRESS]"));
        expect(res1.sanitizedText, contains("[REDACTED MRZ]"));

        final burned1 = img.decodePng(res1.afterImageBytes)!;
        _expectUnmaskedBrightPixel(burned1, 200, 38);
        _expectMaskedPixel(burned1, 280, 100);
        _expectMaskedPixel(burned1, 280, 150);
        _expectMaskedPixel(burned1, 270, 200);
        _expectMaskedPixel(burned1, 270, 248);
        _expectMaskedPixel(burned1, 350, 296);
        _expectMaskedPixel(burned1, 250, 355);
        _expectMaskedPixel(burned1, 250, 385);

        // Bilingual German Identitätskarte with cross-block document number,
        // side-by-side Place of Birth column, CAN, and 3-line TD1 MRZ.
        final identitaetskarteEngine = PiiRedactionEngine(
          ocrEngine: _FixedOcrEngine(
            OcrResult(
              text: "IDENTITÄTSKARTE",
              script: "latin",
              detectedLanguages: const ["de", "en"],
              inferenceMs: 12,
              imageWidth: 640,
              imageHeight: 440,
              blocks: [
                OcrTextBlock(
                  text: "Title",
                  lines: [
                    _line(
                      "IDENTITÄTSKARTE / IDENTITY CARD",
                      left: 160,
                      top: 20,
                      right: 390,
                      bottom: 36,
                    ),
                    _line(
                      "BUNDESREPUBLIK TESTKARTE",
                      left: 160,
                      top: 38,
                      right: 380,
                      bottom: 58,
                    ),
                  ],
                ),
                // Header and larger-font ID split across separate OCR blocks.
                OcrTextBlock(
                  text: "DocHeader",
                  lines: [
                    _line(
                      "Dokumentennummer / Document No.",
                      left: 400,
                      top: 25,
                      right: 590,
                      bottom: 43,
                    ),
                  ],
                ),
                OcrTextBlock(
                  text: "DocValue",
                  lines: [
                    _line(
                      "L01X00T47",
                      left: 400,
                      top: 47,
                      right: 560,
                      bottom: 71,
                    ),
                  ],
                ),
                OcrTextBlock(
                  text: "Body",
                  lines: [
                    _line(
                      "Name / Surname",
                      left: 230,
                      top: 80,
                      right: 340,
                      bottom: 96,
                    ),
                    _line(
                      "DUMMY",
                      left: 230,
                      top: 99,
                      right: 310,
                      bottom: 117,
                    ),
                    _line(
                      "Vornamen / Given Names",
                      left: 230,
                      top: 120,
                      right: 390,
                      bottom: 136,
                    ),
                    _line(
                      "JOHN",
                      left: 230,
                      top: 139,
                      right: 290,
                      bottom: 157,
                    ),
                    _line(
                      "Geburtsdatum / Date of Birth",
                      left: 230,
                      top: 162,
                      right: 385,
                      bottom: 178,
                    ),
                    _line(
                      "Geburtsort / Place of Birth",
                      left: 410,
                      top: 162,
                      right: 580,
                      bottom: 178,
                    ),
                    _line(
                      "15.10.1990",
                      left: 230,
                      top: 181,
                      right: 325,
                      bottom: 201,
                    ),
                    _line(
                      "BERLIN",
                      left: 410,
                      top: 181,
                      right: 485,
                      bottom: 201,
                    ),
                    _line(
                      "Secondary Name / Zweitname",
                      left: 230,
                      top: 204,
                      right: 410,
                      bottom: 220,
                    ),
                    _line(
                      "ROBERT DUMMY",
                      left: 230,
                      top: 223,
                      right: 375,
                      bottom: 241,
                    ),
                    _line(
                      "Staatsangehörigkeit / Nationality",
                      left: 230,
                      top: 244,
                      right: 420,
                      bottom: 260,
                    ),
                    _line(
                      "D (TEST)",
                      left: 230,
                      top: 263,
                      right: 310,
                      bottom: 281,
                    ),
                    _line(
                      "Anschrift / Address / Extra Field",
                      left: 230,
                      top: 284,
                      right: 450,
                      bottom: 300,
                    ),
                    _line(
                      "12 BAHNHOFSTRASSE, 10115 BERLIN",
                      left: 230,
                      top: 303,
                      right: 550,
                      bottom: 321,
                    ),
                    _line(
                      "Zugangsnummer / CAN",
                      left: 230,
                      top: 324,
                      right: 390,
                      bottom: 340,
                    ),
                    _line(
                      "123456",
                      left: 230,
                      top: 343,
                      right: 310,
                      bottom: 361,
                    ),
                  ],
                ),
                OcrTextBlock(
                  text: "MRZ",
                  lines: [
                    _line(
                      "IDD<<L01X00T471<<<<<<<<<<<<<<<<<",
                      left: 40,
                      top: 370,
                      right: 600,
                      bottom: 388,
                    ),
                    _line(
                      "9010151M2611190D<<<<<<<<<<<<<<<6",
                      left: 40,
                      top: 392,
                      right: 600,
                      bottom: 410,
                    ),
                    _line(
                      "DUMMY<<JOHN<<<<<<<<<<<<<<<<<<<<<",
                      left: 40,
                      top: 414,
                      right: 600,
                      bottom: 432,
                    ),
                  ],
                ),
              ],
            ),
          ),
          faceDetectionEngine: _EmptyFaceEngine(),
          pdfRasterizer: _NoOpPdfRasterizer(),
        );

        final res2 = await identitaetskarteEngine.redactPayloads(
          [blankPng],
          options: const RedactionOptions(outputFormat: RedactionOutputFormat.json),
        );

        expect(res2.sanitizedText, contains("BUNDESREPUBLIK TESTKARTE"));
        expect(res2.sanitizedText, contains("D (TEST)"));
        expect(res2.sanitizedText, contains("BERLIN"));
        expect(res2.sanitizedText, isNot(contains("L01X00T47")));
        expect(res2.sanitizedText, isNot(contains("DUMMY")));
        expect(res2.sanitizedText, isNot(contains("JOHN")));
        expect(res2.sanitizedText, isNot(contains("ROBERT")));
        expect(res2.sanitizedText, isNot(contains("15.10.1990")));
        expect(res2.sanitizedText, isNot(contains("12 BAHNHOFSTRASSE")));
        expect(res2.sanitizedText, isNot(contains("10115")));
        expect(res2.sanitizedText, isNot(contains("123456")));
        expect(res2.sanitizedText, isNot(contains("IDD<<")));
        expect(res2.sanitizedText, isNot(contains("9010151M")));

        final burned2 = img.decodePng(res2.afterImageBytes)!;
        _expectMaskedPixel(burned2, 460, 58);
        _expectMaskedPixel(burned2, 265, 108);
        _expectMaskedPixel(burned2, 260, 148);
        _expectMaskedPixel(burned2, 275, 190);
        _expectUnmaskedBrightPixel(burned2, 445, 190);
        _expectUnmaskedBrightPixel(burned2, 270, 272);
        _expectMaskedPixel(burned2, 350, 312);
        _expectMaskedPixel(burned2, 270, 352);
        _expectMaskedPixel(burned2, 250, 422);
      },
    );

    test(
      "redacts bilingual English/French Passport Card while keeping Issue/Expiry dates and Authority unmasked",
      () async {
        final engine = PiiRedactionEngine(
          ocrEngine: _FixedOcrEngine(
            OcrResult(
              text: "PASSPORT",
              script: "latin",
              detectedLanguages: const ["en", "fr"],
              inferenceMs: 11,
              imageWidth: 640,
              imageHeight: 440,
              blocks: [
                OcrTextBlock(
                  text: "Header",
                  lines: [
                    _line(
                      "REPUBLIC OF UTOPIA - PASSPORT",
                      left: 160,
                      top: 25,
                      right: 450,
                      bottom: 45,
                    ),
                    _line(
                      "Type / Type",
                      left: 240,
                      top: 65,
                      right: 320,
                      bottom: 80,
                    ),
                    _line("P", left: 240, top: 83, right: 258, bottom: 100),
                    _line(
                      "Code / Code",
                      left: 335,
                      top: 65,
                      right: 415,
                      bottom: 80,
                    ),
                    _line("UTO", left: 335, top: 83, right: 375, bottom: 100),
                    _line(
                      "Passport No. / N° de passeport",
                      left: 430,
                      top: 65,
                      right: 590,
                      bottom: 80,
                    ),
                    _line(
                      "P12345678",
                      left: 430,
                      top: 83,
                      right: 540,
                      bottom: 102,
                    ),
                  ],
                ),
                OcrTextBlock(
                  text: "Holder",
                  lines: [
                    _line(
                      "Surname / Nom",
                      left: 240,
                      top: 110,
                      right: 350,
                      bottom: 125,
                    ),
                    _line(
                      "SMITH",
                      left: 240,
                      top: 128,
                      right: 310,
                      bottom: 146,
                    ),
                    _line(
                      "Given Names / Prénoms",
                      left: 240,
                      top: 152,
                      right: 400,
                      bottom: 167,
                    ),
                    _line(
                      "JOHN ALEXANDER",
                      left: 240,
                      top: 170,
                      right: 410,
                      bottom: 188,
                    ),
                    _line(
                      "Nationality / Nationalité",
                      left: 240,
                      top: 194,
                      right: 410,
                      bottom: 209,
                    ),
                    _line(
                      "UTOPIAN / UTOP",
                      left: 240,
                      top: 212,
                      right: 390,
                      bottom: 230,
                    ),
                    _line(
                      "Date of Birth / Date de naissance",
                      left: 240,
                      top: 236,
                      right: 440,
                      bottom: 251,
                    ),
                    _line(
                      "15 AUG / AOÛ 1990",
                      left: 240,
                      top: 254,
                      right: 410,
                      bottom: 272,
                    ),
                    _line(
                      "Sex / Sexe",
                      left: 455,
                      top: 236,
                      right: 530,
                      bottom: 251,
                    ),
                    _line("M", left: 455, top: 254, right: 472, bottom: 272),
                    _line(
                      "Date of Issue / Date de délivrance",
                      left: 240,
                      top: 276,
                      right: 440,
                      bottom: 291,
                    ),
                    _line(
                      "25 NOV / NOV 2020",
                      left: 240,
                      top: 294,
                      right: 405,
                      bottom: 312,
                    ),
                    _line(
                      "Date of Expiry / Date d'expiration",
                      left: 455,
                      top: 276,
                      right: 620,
                      bottom: 291,
                    ),
                    _line(
                      "24 NOV / NOV 2030",
                      left: 455,
                      top: 294,
                      right: 615,
                      bottom: 312,
                    ),
                    _line(
                      "Authority / Autorité",
                      left: 240,
                      top: 316,
                      right: 380,
                      bottom: 331,
                    ),
                    _line(
                      "PASSPORT OFFICE / BUREAU DES PASSEPORTS",
                      left: 240,
                      top: 334,
                      right: 590,
                      bottom: 352,
                    ),
                  ],
                ),
                OcrTextBlock(
                  text: "MRZ",
                  lines: [
                    _line(
                      "P<UTOSMITH<<JOHN<ALEXANDER<<<<<<<<<<<<<<<<<<",
                      left: 40,
                      top: 372,
                      right: 600,
                      bottom: 392,
                    ),
                    _line(
                      "P123456783UT09008153M3011242<<<<<<<<<<<<<<06",
                      left: 40,
                      top: 398,
                      right: 600,
                      bottom: 418,
                    ),
                  ],
                ),
              ],
            ),
          ),
          faceDetectionEngine: _EmptyFaceEngine(),
          pdfRasterizer: _NoOpPdfRasterizer(),
        );

        final res = await engine.redactPayloads(
          [_createBlankTestPng()],
          options: const RedactionOptions(outputFormat: RedactionOutputFormat.json),
        );

        expect(res.sanitizedText, isNot(contains("P12345678")));
        expect(res.sanitizedText, isNot(contains("SMITH")));
        expect(res.sanitizedText, isNot(contains("JOHN ALEXANDER")));
        expect(res.sanitizedText, isNot(contains("15 AUG / AOÛ 1990")));
        expect(res.sanitizedText, isNot(contains("P<UTO")));
        expect(res.sanitizedText, contains("UTOPIAN / UTOP"));
        expect(res.sanitizedText, contains("25 NOV / NOV 2020"));
        expect(res.sanitizedText, contains("24 NOV / NOV 2030"));
        expect(
          res.sanitizedText,
          contains("PASSPORT OFFICE / BUREAU DES PASSEPORTS"),
        );

        final burned = img.decodePng(res.afterImageBytes)!;
        _expectMaskedPixel(burned, 480, 92);
        _expectMaskedPixel(burned, 270, 136);
        _expectMaskedPixel(burned, 300, 178);
        _expectMaskedPixel(burned, 300, 262);
        _expectMaskedPixel(burned, 250, 382);
        _expectMaskedPixel(burned, 250, 408);
        _expectUnmaskedBrightPixel(burned, 300, 302);
        _expectUnmaskedBrightPixel(burned, 350, 342);
      },
    );

    test(
      "redacts Singapore bilingual NRIC card including BLK address lines and keeps non-PII columns",
      () async {
        final engine = PiiRedactionEngine(
          ocrEngine: _FixedOcrEngine(
            OcrResult(
              text: "SINGAPORE",
              script: "latin",
              detectedLanguages: const ["en", "zh"],
              inferenceMs: 9,
              imageWidth: 640,
              imageHeight: 440,
              blocks: [
                OcrTextBlock(
                  text: "Header",
                  lines: [
                    _line(
                      "REPUBLIC OF SINGAPORE - TEST IDENTITY",
                      left: 100,
                      top: 25,
                      right: 540,
                      bottom: 48,
                    ),
                    _line(
                      "IDENTITY CARD / 身份证",
                      left: 100,
                      top: 52,
                      right: 300,
                      bottom: 72,
                    ),
                    _line(
                      "ID NO. / 身份证号码: S1234567D",
                      left: 340,
                      top: 52,
                      right: 570,
                      bottom: 74,
                      elements: const [
                        OcrTextElement(
                          text: "ID",
                          boundingBox: BoundingBoxRect(
                            left: 340,
                            top: 52,
                            right: 360,
                            bottom: 74,
                          ),
                        ),
                        OcrTextElement(
                          text: "NO.",
                          boundingBox: BoundingBoxRect(
                            left: 365,
                            top: 52,
                            right: 392,
                            bottom: 74,
                          ),
                        ),
                        OcrTextElement(
                          text: "/",
                          boundingBox: BoundingBoxRect(
                            left: 396,
                            top: 52,
                            right: 404,
                            bottom: 74,
                          ),
                        ),
                        OcrTextElement(
                          text: "身份证号码:",
                          boundingBox: BoundingBoxRect(
                            left: 408,
                            top: 52,
                            right: 475,
                            bottom: 74,
                          ),
                        ),
                        OcrTextElement(
                          text: "S1234567D",
                          boundingBox: BoundingBoxRect(
                            left: 482,
                            top: 52,
                            right: 570,
                            bottom: 74,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                OcrTextBlock(
                  text: "Details",
                  lines: [
                    _line(
                      "Name / 姓名:",
                      left: 240,
                      top: 95,
                      right: 340,
                      bottom: 112,
                    ),
                    _line(
                      "TAN CHIN HAW JOHN",
                      left: 240,
                      top: 116,
                      right: 440,
                      bottom: 136,
                    ),
                    _line(
                      "Alias / 别名:",
                      left: 240,
                      top: 142,
                      right: 340,
                      bottom: 158,
                    ),
                    _line(
                      "CHEN ZHENHAO / 陈振豪",
                      left: 240,
                      top: 162,
                      right: 470,
                      bottom: 182,
                    ),
                    _line(
                      "Date of Birth / 出生日期:",
                      left: 240,
                      top: 188,
                      right: 400,
                      bottom: 204,
                    ),
                    _line(
                      "Race / 种族:",
                      left: 420,
                      top: 188,
                      right: 530,
                      bottom: 204,
                    ),
                    _line(
                      "15/10/1990",
                      left: 240,
                      top: 208,
                      right: 345,
                      bottom: 228,
                    ),
                    _line(
                      "CHINESE / 华族",
                      left: 420,
                      top: 208,
                      right: 540,
                      bottom: 228,
                    ),
                    _line(
                      "Country of Birth / 出生国:",
                      left: 240,
                      top: 234,
                      right: 410,
                      bottom: 250,
                    ),
                    _line(
                      "SINGAPORE",
                      left: 240,
                      top: 254,
                      right: 360,
                      bottom: 274,
                    ),
                    _line(
                      "Address / 住所:",
                      left: 240,
                      top: 280,
                      right: 360,
                      bottom: 296,
                    ),
                    _line(
                      "BLK 123 BISHAN STREET 12",
                      left: 240,
                      top: 300,
                      right: 475,
                      bottom: 320,
                    ),
                    _line(
                      "#04-123, SINGAPORE 570123",
                      left: 240,
                      top: 324,
                      right: 485,
                      bottom: 344,
                    ),
                    _line(
                      "Status / 身份:",
                      left: 240,
                      top: 352,
                      right: 350,
                      bottom: 368,
                    ),
                    _line(
                      "TEST SUBJECT",
                      left: 240,
                      top: 372,
                      right: 380,
                      bottom: 392,
                    ),
                  ],
                ),
              ],
            ),
          ),
          faceDetectionEngine: _EmptyFaceEngine(),
          pdfRasterizer: _NoOpPdfRasterizer(),
        );

        final res = await engine.redactPayloads(
          [_createBlankTestPng()],
          options: const RedactionOptions(outputFormat: RedactionOutputFormat.json),
        );

        expect(res.sanitizedText, isNot(contains("S1234567D")));
        expect(res.sanitizedText, isNot(contains("TAN CHIN HAW JOHN")));
        expect(res.sanitizedText, isNot(contains("CHEN ZHENHAO")));
        expect(res.sanitizedText, isNot(contains("15/10/1990")));
        expect(res.sanitizedText, isNot(contains("BLK")));
        expect(res.sanitizedText, isNot(contains("BISHAN")));
        expect(res.sanitizedText, isNot(contains("#04-123")));
        expect(res.sanitizedText, isNot(contains("570123")));

        expect(res.sanitizedText, contains("CHINESE / 华族"));
        expect(res.sanitizedText, contains("SINGAPORE"));
        expect(res.sanitizedText, contains("TEST SUBJECT"));

        final burned = img.decodePng(res.afterImageBytes)!;
        _expectMaskedPixel(burned, 520, 62);
        _expectMaskedPixel(burned, 310, 126);
        _expectMaskedPixel(burned, 310, 172);
        _expectMaskedPixel(burned, 280, 218);
        _expectMaskedPixel(burned, 250, 310);
        _expectMaskedPixel(burned, 360, 334);
        _expectUnmaskedBrightPixel(burned, 460, 218);
        _expectUnmaskedBrightPixel(burned, 290, 264);
        _expectUnmaskedBrightPixel(burned, 290, 382);
      },
    );

    test(
      "redacts UK Driving Licence numbered fields, multi-line UK address, and NI while preserving issue/expiry",
      () async {
        final engine = PiiRedactionEngine(
          ocrEngine: _FixedOcrEngine(
            OcrResult(
              text: "UK DL",
              script: "latin",
              detectedLanguages: const ["en"],
              inferenceMs: 10,
              imageWidth: 640,
              imageHeight: 440,
              blocks: [
                OcrTextBlock(
                  text: "Fields",
                  lines: [
                    _line(
                      "DRIVING LICENCE - UK TEST SPECIMEN",
                      left: 180,
                      top: 20,
                      right: 540,
                      bottom: 42,
                    ),
                    _line(
                      "1. Surname",
                      left: 220,
                      top: 55,
                      right: 320,
                      bottom: 70,
                    ),
                    _line(
                      "SMITH",
                      left: 220,
                      top: 73,
                      right: 295,
                      bottom: 91,
                    ),
                    _line(
                      "2. First name(s)",
                      left: 220,
                      top: 95,
                      right: 350,
                      bottom: 110,
                    ),
                    _line(
                      "JOHN DUMMY",
                      left: 220,
                      top: 113,
                      right: 365,
                      bottom: 131,
                    ),
                    _line(
                      "3. Date & Place of Birth",
                      left: 220,
                      top: 136,
                      right: 400,
                      bottom: 151,
                    ),
                    _line(
                      "15.10.1990 LONDON",
                      left: 220,
                      top: 154,
                      right: 430,
                      bottom: 172,
                    ),
                    _line(
                      "4a. Date of Issue",
                      left: 220,
                      top: 176,
                      right: 355,
                      bottom: 191,
                    ),
                    _line(
                      "4b. Date of Expiry",
                      left: 380,
                      top: 176,
                      right: 520,
                      bottom: 191,
                    ),
                    _line(
                      "01.10.2021",
                      left: 220,
                      top: 194,
                      right: 325,
                      bottom: 212,
                    ),
                    _line(
                      "30.09.2031",
                      left: 380,
                      top: 194,
                      right: 485,
                      bottom: 212,
                    ),
                    _line(
                      "4c. Issued by",
                      left: 220,
                      top: 216,
                      right: 330,
                      bottom: 231,
                    ),
                    _line(
                      "DVLA TEST",
                      left: 220,
                      top: 234,
                      right: 335,
                      bottom: 252,
                    ),
                    _line(
                      "5. Licence No",
                      left: 220,
                      top: 256,
                      right: 340,
                      bottom: 271,
                    ),
                    _line(
                      "SMITH901015AB9CD",
                      left: 220,
                      top: 274,
                      right: 470,
                      bottom: 294,
                    ),
                    _line(
                      "8. Address",
                      left: 220,
                      top: 298,
                      right: 320,
                      bottom: 313,
                    ),
                    _line(
                      "221B BAKER STREET,",
                      left: 220,
                      top: 316,
                      right: 420,
                      bottom: 334,
                    ),
                    _line(
                      "LONDON, NW1 6XE",
                      left: 220,
                      top: 337,
                      right: 410,
                      bottom: 355,
                    ),
                    _line(
                      "9. National Insurance No / NI",
                      left: 220,
                      top: 360,
                      right: 440,
                      bottom: 375,
                    ),
                    _line(
                      "QQ 12 34 56 C",
                      left: 220,
                      top: 378,
                      right: 380,
                      bottom: 398,
                    ),
                  ],
                ),
              ],
            ),
          ),
          faceDetectionEngine: _EmptyFaceEngine(),
          pdfRasterizer: _NoOpPdfRasterizer(),
        );

        final res = await engine.redactPayloads(
          [_createBlankTestPng()],
          options: const RedactionOptions(outputFormat: RedactionOutputFormat.json),
        );

        expect(res.sanitizedText, contains("DRIVING LICENCE - UK TEST SPECIMEN"));
        expect(res.sanitizedText, contains("01.10.2021"));
        expect(res.sanitizedText, contains("30.09.2031"));
        expect(res.sanitizedText, contains("DVLA TEST"));
        expect(res.sanitizedText, isNot(contains("SMITH")));
        expect(res.sanitizedText, isNot(contains("JOHN DUMMY")));
        expect(res.sanitizedText, isNot(contains("15.10.1990")));
        expect(res.sanitizedText, isNot(contains("SMITH901015AB9CD")));
        expect(res.sanitizedText, isNot(contains("221B BAKER STREET")));
        expect(res.sanitizedText, isNot(contains("NW1 6XE")));
        expect(res.sanitizedText, isNot(contains("QQ 12 34 56 C")));

        final burned = img.decodePng(res.afterImageBytes)!;
        _expectUnmaskedBrightPixel(burned, 250, 30);
        _expectUnmaskedBrightPixel(burned, 260, 202);
        _expectUnmaskedBrightPixel(burned, 420, 202);
        _expectUnmaskedBrightPixel(burned, 260, 242);
        _expectMaskedPixel(burned, 250, 82);
        _expectMaskedPixel(burned, 270, 122);
        _expectMaskedPixel(burned, 270, 162);
        _expectMaskedPixel(burned, 330, 284);
        _expectMaskedPixel(burned, 300, 325);
        _expectMaskedPixel(burned, 300, 346);
        _expectMaskedPixel(burned, 280, 388);
      },
    );

    test(
      "fallback regexes catch unlabelled international addresses and IDs without headers",
      () async {
        final engine = PiiRedactionEngine(
          ocrEngine: _FixedOcrEngine(
            OcrResult(
              text: "Unlabelled",
              script: "latin",
              detectedLanguages: const ["en", "de"],
              inferenceMs: 8,
              imageWidth: 640,
              imageHeight: 400,
              blocks: [
                OcrTextBlock(
                  text: "Lines",
                  lines: [
                    _line(
                      "TESTWEG 12, 10115 BERLIN",
                      left: 20,
                      top: 20,
                      right: 320,
                      bottom: 40,
                    ),
                    _line(
                      "12 BAHNHOFSTRASSE, 10115 BERLIN",
                      left: 20,
                      top: 50,
                      right: 360,
                      bottom: 70,
                    ),
                    _line(
                      "LONDON, NW1 6XE",
                      left: 20,
                      top: 80,
                      right: 260,
                      bottom: 100,
                    ),
                    _line(
                      "#04-123, SINGAPORE 570123",
                      left: 20,
                      top: 110,
                      right: 320,
                      bottom: 130,
                    ),
                    _line(
                      "S1234567D",
                      left: 20,
                      top: 140,
                      right: 180,
                      bottom: 160,
                    ),
                    _line(
                      "QQ 12 34 56 C",
                      left: 20,
                      top: 170,
                      right: 200,
                      bottom: 190,
                    ),
                    _line(
                      "SMITH901015AB9CD",
                      left: 20,
                      top: 200,
                      right: 260,
                      bottom: 220,
                    ),
                  ],
                ),
              ],
            ),
          ),
          faceDetectionEngine: _EmptyFaceEngine(),
          pdfRasterizer: _NoOpPdfRasterizer(),
        );

        final res = await engine.redactPayloads(
          [_createBlankTestPng(height: 260)],
          options: const RedactionOptions(outputFormat: RedactionOutputFormat.json),
        );

        expect(res.categoryCounts["address"], 4);
        expect(res.categoryCounts["id"], 3);
        expect(res.sanitizedText, isNot(contains("10115")));
        expect(res.sanitizedText, isNot(contains("NW1 6XE")));
        expect(res.sanitizedText, isNot(contains("570123")));
        expect(res.sanitizedText, isNot(contains("S1234567D")));
        expect(res.sanitizedText, isNot(contains("QQ 12 34 56 C")));
        expect(res.sanitizedText, isNot(contains("SMITH901015AB9CD")));
      },
    );

    test(
      "respects preset isolation, keepLast4 on foreign IDs vs MRZ, and extended preset aliases",
      () async {
        expect(
          RedactionPreset.parsePresets("name,dob,mrz,passport"),
          {RedactionPreset.contacts, RedactionPreset.ids},
        );

        final ocr = OcrResult(
          text: "PresetCheck",
          script: "latin",
          detectedLanguages: const ["en", "de"],
          inferenceMs: 6,
          imageWidth: 640,
          imageHeight: 340,
          blocks: [
            OcrTextBlock(
              text: "Card",
              lines: [
                _line("Full Name:", left: 40, top: 20, right: 160, bottom: 36),
                _line(
                  "ANNA TESTER",
                  left: 40,
                  top: 40,
                  right: 200,
                  bottom: 58,
                ),
                _line(
                  "Date of Birth:",
                  left: 40,
                  top: 66,
                  right: 170,
                  bottom: 82,
                ),
                _line("01.01.1990", left: 40, top: 86, right: 160, bottom: 104),
                _line(
                  "ID Number:",
                  left: 40,
                  top: 112,
                  right: 150,
                  bottom: 128,
                ),
                _line("L01X00T47", left: 40, top: 132, right: 170, bottom: 150),
                _line(
                  "ID NO. / 身份证号码: S1234567D",
                  left: 40,
                  top: 158,
                  right: 360,
                  bottom: 176,
                ),
                _line(
                  "Address / Extra Field:",
                  left: 40,
                  top: 184,
                  right: 220,
                  bottom: 200,
                ),
                _line(
                  "TESTWEG 12, 10115 BERLIN",
                  left: 40,
                  top: 204,
                  right: 340,
                  bottom: 224,
                ),
                _line(
                  "IDD<<L01X00T471<<<<<<<<<<<<<<<",
                  left: 40,
                  top: 250,
                  right: 580,
                  bottom: 270,
                ),
              ],
            ),
          ],
        );

        final engine = PiiRedactionEngine(
          ocrEngine: _FixedOcrEngine(ocr),
          faceDetectionEngine: _EmptyFaceEngine(),
          pdfRasterizer: _NoOpPdfRasterizer(),
        );
        final blankPng = _createBlankTestPng(height: 300);

        final addressesOnly = await engine.redactPayloads(
          [blankPng],
          options: const RedactionOptions(
            presets: {RedactionPreset.addresses},
            outputFormat: RedactionOutputFormat.json,
          ),
        );
        expect(addressesOnly.categoryCounts["address"], 1);
        expect(addressesOnly.categoryCounts["id"], 0);
        expect(addressesOnly.categoryCounts["contact"], 0);
        expect(addressesOnly.sanitizedText, contains("ANNA TESTER"));
        expect(addressesOnly.sanitizedText, contains("01.01.1990"));
        expect(addressesOnly.sanitizedText, contains("L01X00T47"));
        expect(addressesOnly.sanitizedText, isNot(contains("TESTWEG 12")));

        final contactsOnly = await engine.redactPayloads(
          [blankPng],
          options: const RedactionOptions(
            presets: {RedactionPreset.contacts},
            outputFormat: RedactionOutputFormat.json,
          ),
        );
        expect(contactsOnly.categoryCounts["id"], 0);
        expect(contactsOnly.categoryCounts["address"], 0);
        expect(contactsOnly.categoryCounts["contact"], 2);
        expect(contactsOnly.sanitizedText, isNot(contains("ANNA TESTER")));
        expect(contactsOnly.sanitizedText, isNot(contains("01.01.1990")));
        expect(contactsOnly.sanitizedText, contains("L01X00T47"));
        expect(contactsOnly.sanitizedText, contains("TESTWEG 12"));

        final idsKeepLast4 = await engine.redactPayloads(
          [blankPng],
          options: const RedactionOptions(
            presets: {RedactionPreset.ids},
            keepLast4: true,
            outputFormat: RedactionOutputFormat.json,
          ),
        );
        expect(idsKeepLast4.sanitizedText, contains("••••0T47"));
        expect(idsKeepLast4.sanitizedText, contains("••••567D"));
        expect(idsKeepLast4.sanitizedText, contains("[REDACTED MRZ]"));
        expect(idsKeepLast4.sanitizedText, isNot(contains("L01X00")));
        expect(idsKeepLast4.sanitizedText, isNot(contains("S1234")));
        expect(idsKeepLast4.sanitizedText, isNot(contains("IDD<<")));
      },
    );

    test(
      "maps cached offline EntityExtractionEngine addresses and IBANs to OCR lines while ignoring dates",
      () async {
        final engine = PiiRedactionEngine(
          ocrEngine: _FixedOcrEngine(
            OcrResult(
              text: "Swiss",
              script: "latin",
              detectedLanguages: const ["en", "de"],
              inferenceMs: 7,
              imageWidth: 640,
              imageHeight: 300,
              blocks: [
                OcrTextBlock(
                  text: "Block",
                  lines: [
                    _line(
                      "Suite 4B, Harbourfront Centre",
                      left: 30,
                      top: 30,
                      right: 320,
                      bottom: 50,
                    ),
                    _line(
                      "3011 Bern",
                      left: 30,
                      top: 56,
                      right: 160,
                      bottom: 76,
                    ),
                    _line(
                      "Transfer ref CH9300762011623852957",
                      left: 30,
                      top: 90,
                      right: 380,
                      bottom: 110,
                    ),
                    _line(
                      "Statement 2026-11-19",
                      left: 30,
                      top: 125,
                      right: 240,
                      bottom: 145,
                    ),
                  ],
                ),
              ],
            ),
          ),
          faceDetectionEngine: _EmptyFaceEngine(),
          pdfRasterizer: _NoOpPdfRasterizer(),
          entityExtractionEngine: _FakeCachedEntityExtractionEngine(
            const [
              ExtractedEntityItem(
                type: "address",
                rawValue: "Suite 4B, Harbourfront Centre\n3011 Bern",
              ),
              ExtractedEntityItem(
                type: "iban",
                rawValue: "CH9300762011623852957",
              ),
              ExtractedEntityItem(
                type: "date_time",
                rawValue: "2026-11-19",
              ),
            ],
          ),
        );

        final res = await engine.redactPayloads(
          [_createBlankTestPng(height: 200)],
          options: const RedactionOptions(outputFormat: RedactionOutputFormat.json),
        );

        expect(res.categoryCounts["address"], 2);
        expect(res.categoryCounts["id"], 1);
        expect(res.sanitizedText, isNot(contains("Harbourfront Centre")));
        expect(res.sanitizedText, isNot(contains("3011 Bern")));
        expect(res.sanitizedText, isNot(contains("CH9300762011623852957")));
        expect(res.sanitizedText, contains("Statement 2026-11-19"));

        final burned = img.decodePng(res.afterImageBytes)!;
        _expectMaskedPixel(burned, 150, 40);
        _expectMaskedPixel(burned, 90, 66);
        _expectMaskedPixel(burned, 260, 100);
        _expectUnmaskedBrightPixel(burned, 120, 135);
      },
    );
  });
}

class _FixedOcrEngine implements OcrEngine {
  _FixedOcrEngine(this.result);

  final OcrResult result;

  @override
  Future<OcrResult> processImage(
    PreparedImagePayload payload, {
    OcrScript script = OcrScript.latin,
  }) async =>
      result;

  @override
  Future<void> dispose() async {}
}

class _EmptyFaceEngine implements FaceDetectionEngine {
  @override
  Future<List<BoundingBoxRect>> detectFaces(
    PreparedImagePayload payload,
  ) async =>
      const [];

  @override
  Future<List<DetectedFaceRegion>> detectOrientedFaces(
    PreparedImagePayload payload,
  ) async =>
      const [];

  @override
  Future<void> dispose() async {}
}

class _NoOpPdfRasterizer implements PdfRasterizer {
  @override
  Future<List<RasterizedPdfPage>> rasterizePdf(
    Uint8List pdfBytes, {
    double dpi = 150.0,
  }) async =>
      const [];

  @override
  Future<void> dispose() async {}
}

class _FakeCachedEntityExtractionEngine implements EntityExtractionEngine {
  _FakeCachedEntityExtractionEngine(this.items);

  final List<ExtractedEntityItem> items;

  @override
  Future<bool> isNativeModelAvailable() async => true;

  @override
  Future<List<ExtractedEntityItem>> extractEntities(String text) async => items;

  @override
  Future<void> dispose() async {}
}
