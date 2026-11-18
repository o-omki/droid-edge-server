import "dart:math" as math;

import "../models/ocr_result.dart";
import "../models/openai_vision_models.dart";
import "entity_extraction_engine.dart";

/// Tier 1 deterministic structured extractors for receipts/invoices/utility bills
/// and business cards (vCard 3.0).
class StructuredExtractionEngine {
  const StructuredExtractionEngine._();

  static final RegExp _utilityKeywordRegex = RegExp(
    r"\b(?:electricity|water\s+bill|gas\s+bill|utility|meter\s+no|kwh|billing\s+period|consumer\s+no|tariff)\b",
    caseSensitive: false,
  );

  static final RegExp _taxInvoiceKeywordRegex = RegExp(
    r"\b(?:tax\s+invoice|gstin|cgst|sgst|igst|vat\s+(?:invoice|no|reg))\b",
    caseSensitive: false,
  );

  static final RegExp _taxHeaderOrIdSkipRegex = RegExp(
    r"\b(?:tax\s+invoice|gstin|vat\s+(?:invoice|no|reg))\b",
    caseSensitive: false,
  );

  static final RegExp _invoiceKeywordRegex = RegExp(
    r"\b(?:invoice|bill\s+to|due\s+date|inv\s*#)\b",
    caseSensitive: false,
  );

  static final RegExp _genericHeaderSkipRegex = RegExp(
    r"^(?:tax\s+invoice|invoice|receipt|cash\s+memo|bill|statement|original|duplicate|customer\s+copy|merchant\s+copy)$",
    caseSensitive: false,
  );

  static final RegExp _subtotalLabelRegex = RegExp(
    r"\b(?:sub\s*-?\s*total|net\s+amount|taxable\s+(?:value|amount))\b",
    caseSensitive: false,
  );

  static final RegExp _taxLabelRegex = RegExp(
    r"\b(?:cgst|sgst|igst|gst|vat|sales\s+tax|service\s+tax|tax(?:\s+amount)?)\b",
    caseSensitive: false,
  );

  static final RegExp _totalLabelRegex = RegExp(
    r"\b(?:grand\s+total|total\s+amount|amount\s+due|balance\s+due|net\s+payable|total\s+payable|amount\s+paid|total)\b",
    caseSensitive: false,
  );

  static final RegExp _nonLineItemLabelRegex = RegExp(
    r"\b(?:subtotal|sub\s*-?\s*total|tax|cgst|sgst|igst|vat|gstin|discount|tip|gratuity|total|balance|amount\s+due|change|cash|card|visa|mastercard|upi|invoice|receipt|bill\s+no|order\s*#|date|time|tel|phone|mobile|email|address|thank\s+you|qty|quantity|unit\s+price|description|item)\b",
    caseSensitive: false,
  );

  static final RegExp _trailingAmountRegex = RegExp(
    r"(?:[$€£¥₹]|USD|EUR|GBP|INR|Rs\.?)?\s*([\d,]+(?:\.\d{1,2}))\s*$",
    caseSensitive: false,
  );

  static final RegExp _qtyPrefixRegex = RegExp(
    r"^(\d+(?:\.\d+)?)\s*[xX×]\s+(.+)$",
  );

  static final RegExp _titleKeywordRegex = RegExp(
    r"\b(?:engineer|developer|architect|manager|director|founder|co-founder|ceo|cto|cfo|coo|cio|cmo|vp|vice\s+president|president|consultant|designer|partner|specialist|analyst|officer|head|lead|doctor|advocate|professor|associate|executive|administrator|coordinator|representative|supervisor|technician)\b",
    caseSensitive: false,
  );

  static final RegExp _orgKeywordRegex = RegExp(
    r"\b(?:inc\.?|llc|llp|ltd\.?|pvt\.?|corp\.?|corporation|company|co\.|technologies|tech|solutions|systems|labs|group|studio|enterprises|services|global|associates|bank|hospital|university|institute|agency|ventures|holdings|networks|industries|media|partners)\b",
    caseSensitive: false,
  );

  static const Set<String> _genericWebmailDomains = {
    "gmail",
    "yahoo",
    "outlook",
    "hotmail",
    "icloud",
    "proton",
    "protonmail",
    "live",
    "aol",
  };

  /// Parses [ocr] and [entities] into a [StructuredReceiptResult].
  static StructuredReceiptResult extractReceiptOrBill(
    OcrResult ocr,
    List<ExtractedEntityItem> entities, {
    String tierUsed = "tier1_deterministic",
  }) {
    final fullText = ocr.text.trim();
    final documentType = _classifyDocumentType(fullText);
    final rows = _extractLogicalRows(ocr);
    final logicalLines = rows
        .map((row) => row.join("  ").trim())
        .where((line) => line.isNotEmpty)
        .toList();

    final merchantName = _detectMerchantName(logicalLines);
    final invoiceNumber = _firstValueByType(entities, "invoice_number") ??
        _fallbackInvoiceNumber(logicalLines);
    final date = _firstNormalizedOrRawByType(entities, "date_time");
    final currency = _detectCurrency(entities, fullText);

    double? subtotal;
    double taxAccumulator = 0.0;
    var hasTax = false;
    double? totalAmount;
    final lineItems = <ReceiptLineItem>[];

    for (var i = 0; i < rows.length; i++) {
      final rowCells = rows[i];
      final line = rowCells.join("  ").trim();
      if (line.isEmpty) continue;

      final lineAmount = _extractTrailingMoney(line);

      if (_subtotalLabelRegex.hasMatch(line) && lineAmount != null) {
        subtotal = lineAmount;
        continue;
      }

      if (_taxLabelRegex.hasMatch(line) &&
          !_taxHeaderOrIdSkipRegex.hasMatch(line) &&
          lineAmount != null) {
        taxAccumulator += lineAmount;
        hasTax = true;
        continue;
      }

      if (_totalLabelRegex.hasMatch(line) &&
          !_subtotalLabelRegex.hasMatch(line) &&
          lineAmount != null) {
        if (totalAmount == null || lineAmount >= totalAmount) {
          totalAmount = lineAmount;
        }
        continue;
      }

      final parsedItem = _tryParseLineItem(rowCells, line);
      if (parsedItem != null) {
        lineItems.add(parsedItem);
      }
    }

    if (totalAmount == null) {
      final moneyAmounts = entities
          .where((e) => e.type == "money" && e.amount != null)
          .map((e) => e.amount!)
          .toList();
      if (moneyAmounts.isNotEmpty) {
        moneyAmounts.sort();
        totalAmount = moneyAmounts.last;
      } else if (lineItems.isNotEmpty) {
        totalAmount = double.parse(
          lineItems
              .fold<double>(0.0, (sum, item) => sum + item.amount)
              .toStringAsFixed(2),
        );
      }
    }

    final taxIds = _uniqueValuesByTypes(entities, const ["tax_id"]);
    final paymentMethods = _uniqueValuesByTypes(
      entities,
      const ["upi", "iban", "payment_card"],
    );
    final phones = _uniqueValuesByTypes(entities, const ["phone"]);
    final emails = _uniqueValuesByTypes(entities, const ["email"]);
    final addresses = _uniqueValuesByTypes(entities, const ["address"]);

    return StructuredReceiptResult(
      documentType: documentType,
      merchantName: merchantName,
      invoiceNumber: invoiceNumber,
      date: date,
      currency: currency,
      subtotal: subtotal,
      taxAmount: hasTax ? double.parse(taxAccumulator.toStringAsFixed(2)) : null,
      totalAmount: totalAmount,
      taxIds: taxIds,
      paymentMethods: paymentMethods,
      phones: phones,
      emails: emails,
      addresses: addresses,
      lineItems: lineItems,
      rawText: fullText,
      tierUsed: tierUsed,
    );
  }

  /// Parses [ocr] and [entities] into a [VCardContactResult] containing an
  /// RFC 2426 vCard 3.0 string.
  static VCardContactResult extractBusinessCard(
    OcrResult ocr,
    List<ExtractedEntityItem> entities,
  ) {
    final phones = _uniqueValuesByTypes(entities, const ["phone"]);
    final emails = _uniqueValuesByTypes(entities, const ["email"]);
    final urls = _uniqueValuesByTypes(
      entities,
      const ["url"],
      preferNormalized: true,
    );
    final addresses = _uniqueValuesByTypes(entities, const ["address"]);

    final candidateLines = _extractCardLinesWithHeight(ocr);

    String? organization;
    String? title;
    final nameCandidates = <({String text, double height, int index})>[];

    for (var i = 0; i < candidateLines.length; i++) {
      final line = candidateLines[i];
      final cleaned = _stripContactPrefixes(line.text);
      if (cleaned.isEmpty) continue;
      if (_isPureContactOrAddressLine(
        cleaned,
        emails: emails,
        phones: phones,
        urls: urls,
        addresses: addresses,
      )) {
        continue;
      }

      if (title == null && _titleKeywordRegex.hasMatch(cleaned)) {
        title = cleaned;
        continue;
      }

      if (organization == null && _orgKeywordRegex.hasMatch(cleaned)) {
        organization = cleaned;
        continue;
      }

      if (_looksLikePersonName(cleaned)) {
        nameCandidates.add((text: cleaned, height: line.height, index: i));
      } else {
        organization ??= cleaned;
      }
    }

    String fullName = "";
    if (nameCandidates.isNotEmpty) {
      nameCandidates.sort((a, b) {
        final heightCmp = b.height.compareTo(a.height);
        if (heightCmp != 0) return heightCmp;
        return a.index.compareTo(b.index);
      });
      fullName = nameCandidates.first.text;
      // Use another non-name candidate line as organisation if still missing.
      if (organization == null && nameCandidates.length > 1) {
        organization = nameCandidates[1].text;
      }
    }

    if (organization == null && emails.isNotEmpty) {
      final domainPart = emails.first.split("@").last.split(".").first;
      if (domainPart.length >= 2 &&
          !_genericWebmailDomains.contains(domainPart.toLowerCase())) {
        organization =
            domainPart[0].toUpperCase() + domainPart.substring(1);
      }
    }

    if (fullName.isEmpty) {
      if (emails.isNotEmpty) {
        final localPart = emails.first.split("@").first;
        final parts = localPart
            .split(RegExp(r"[._\-]+"))
            .where((p) => p.isNotEmpty)
            .map((p) => p[0].toUpperCase() + p.substring(1))
            .toList();
        fullName = parts.isNotEmpty ? parts.join(" ") : "Unknown Contact";
      } else {
        fullName = organization ?? "Unknown Contact";
      }
    }

    final splitName = _splitPersonName(fullName);
    final vcard = _buildVCard30(
      fullName: fullName,
      firstName: splitName.firstName,
      lastName: splitName.lastName,
      organization: organization,
      title: title,
      phones: phones,
      emails: emails,
      urls: urls,
      addresses: addresses,
    );

    return VCardContactResult(
      fullName: fullName,
      firstName: splitName.firstName,
      lastName: splitName.lastName,
      organization: organization,
      title: title,
      phones: phones,
      emails: emails,
      urls: urls,
      addresses: addresses,
      vcardText: vcard,
    );
  }

  static String _classifyDocumentType(String text) {
    if (_utilityKeywordRegex.hasMatch(text)) {
      return "utility_bill";
    }
    if (_taxInvoiceKeywordRegex.hasMatch(text)) {
      return "tax_invoice";
    }
    if (_invoiceKeywordRegex.hasMatch(text)) {
      return "invoice";
    }
    return "receipt";
  }

  static List<List<String>> _extractLogicalRows(OcrResult ocr) {
    final positionedLines = <({String text, double left, double centerY, double height})>[];
    for (final block in ocr.blocks) {
      for (final line in block.lines) {
        final text = line.text.trim();
        if (text.isEmpty) continue;
        final box = line.boundingBox;
        if (box != null) {
          positionedLines.add((
            text: text,
            left: box.left,
            centerY: (box.top + box.bottom) / 2.0,
            height: math.max(1.0, box.height),
          ));
        }
      }
    }

    if (positionedLines.isNotEmpty) {
      final heights = positionedLines.map((l) => l.height).toList()..sort();
      final medianHeight = heights[heights.length ~/ 2];
      final tolerance = math.max(8.0, 0.52 * medianHeight);

      positionedLines.sort((a, b) => a.centerY.compareTo(b.centerY));
      final clusters = <List<({String text, double left, double centerY, double height})>>[];
      final means = <double>[];

      for (final line in positionedLines) {
        if (clusters.isEmpty ||
            (line.centerY - means.last).abs() > tolerance) {
          clusters.add([line]);
          means.add(line.centerY);
        } else {
          final cluster = clusters.last;
          cluster.add(line);
          means[means.length - 1] =
              cluster.fold<double>(0.0, (sum, l) => sum + l.centerY) /
                  cluster.length;
        }
      }

      return clusters.map((cluster) {
        cluster.sort((a, b) => a.left.compareTo(b.left));
        return cluster.map((l) => l.text).toList();
      }).toList();
    }

    return ocr.text
        .split(RegExp(r"\r?\n"))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map((line) => [line])
        .toList();
  }

  static String? _detectMerchantName(List<String> lines) {
    final limit = math.min(5, lines.length);
    for (var i = 0; i < limit; i++) {
      final candidate = lines[i].trim();
      if (candidate.length < 2) continue;
      if (_genericHeaderSkipRegex.hasMatch(candidate)) continue;
      if (RegExp(r"^(?:invoice|bill|date|tel|phone|gstin|vat|pin)\b", caseSensitive: false)
          .hasMatch(candidate)) {
        continue;
      }
      if (!RegExp(r"[A-Za-z]{2,}").hasMatch(candidate)) continue;
      return candidate;
    }
    return null;
  }

  static String? _fallbackInvoiceNumber(List<String> lines) {
    final pattern = RegExp(
      r"\b(?:Invoice|Inv|Bill|Receipt|Consumer|Order)\s*(?:No\.?|#)?\s*[:#\-]\s*([A-Z0-9\-/]{3,24})",
      caseSensitive: false,
    );
    for (final line in lines) {
      final m = pattern.firstMatch(line);
      if (m != null) {
        return m.group(1)?.trim();
      }
    }
    return null;
  }

  static String? _detectCurrency(
    List<ExtractedEntityItem> entities,
    String fullText,
  ) {
    for (final entity in entities) {
      if (entity.type == "money" && entity.currency != null) {
        return entity.currency;
      }
    }
    return DeterministicEntityRegexExtractor.normalizeCurrency(fullText);
  }

  static double? _extractTrailingMoney(String line) {
    final m = _trailingAmountRegex.firstMatch(line.trim());
    if (m == null) return null;
    return double.tryParse(m.group(1)!.replaceAll(",", ""));
  }

  static ReceiptLineItem? _tryParseLineItem(
    List<String> rowCells,
    String fullLine,
  ) {
    if (_nonLineItemLabelRegex.hasMatch(fullLine)) {
      return null;
    }

    if (rowCells.length >= 2) {
      final lastCell = rowCells.last.trim();
      final amount = _parseStrictCellMoney(lastCell);
      if (amount != null && amount > 0) {
        var description = rowCells.first.trim();
        if (description.isNotEmpty &&
            RegExp(r"[A-Za-z]{2,}").hasMatch(description)) {
          double? qty;
          double? unitPrice;
          final qtyPrefixMatch = _qtyPrefixRegex.firstMatch(description);
          if (qtyPrefixMatch != null) {
            qty = double.tryParse(qtyPrefixMatch.group(1)!);
            description = qtyPrefixMatch.group(2)!.trim();
          }
          if (rowCells.length >= 3) {
            qty ??= double.tryParse(rowCells[1].trim());
          }
          if (rowCells.length >= 4) {
            unitPrice = _parseStrictCellMoney(rowCells[2].trim());
          }
          return ReceiptLineItem(
            description: description,
            quantity: qty,
            unitPrice: unitPrice,
            amount: amount,
          );
        }
      }
    }

    final hasExplicitDecimalOrSymbol = RegExp(
      r"(?:[$€£¥₹]|USD|EUR|GBP|INR|Rs\.?)\s*[\d,]+(?:\.\d{1,2})?|\d+\.\d{2}\s*$",
      caseSensitive: false,
    ).hasMatch(fullLine);

    if (!hasExplicitDecimalOrSymbol) {
      return null;
    }

    final amountMatch = _trailingAmountRegex.firstMatch(fullLine);
    if (amountMatch == null) return null;
    final amount = double.tryParse(amountMatch.group(1)!.replaceAll(",", ""));
    if (amount == null || amount <= 0) return null;

    var desc = fullLine.substring(0, amountMatch.start).trim();
    desc = desc.replaceAll(RegExp(r"[\s\-–|]+$"), "").trim();
    if (desc.isEmpty || !RegExp(r"[A-Za-z]{2,}").hasMatch(desc)) {
      return null;
    }

    double? qty;
    final qtyMatch = _qtyPrefixRegex.firstMatch(desc);
    if (qtyMatch != null) {
      qty = double.tryParse(qtyMatch.group(1)!);
      desc = qtyMatch.group(2)!.trim();
    }

    return ReceiptLineItem(
      description: desc,
      quantity: qty,
      amount: amount,
    );
  }

  static double? _parseStrictCellMoney(String cell) {
    final match = RegExp(
      r"^(?:[$€£¥₹]|USD|EUR|GBP|INR|Rs\.?)?\s*([\d,]+(?:\.\d{1,2})?)$",
      caseSensitive: false,
    ).firstMatch(cell.trim());
    if (match == null) return null;
    return double.tryParse(match.group(1)!.replaceAll(",", ""));
  }

  static List<({String text, double height})> _extractCardLinesWithHeight(
    OcrResult ocr,
  ) {
    final result = <({String text, double height})>[];
    for (final block in ocr.blocks) {
      for (final line in block.lines) {
        final text = line.text.trim();
        if (text.isEmpty) continue;
        result.add((text: text, height: line.boundingBox?.height ?? 18.0));
      }
    }
    if (result.isNotEmpty) {
      return result;
    }
    return ocr.text
        .split(RegExp(r"\r?\n"))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map((line) => (text: line, height: 18.0))
        .toList();
  }

  static String _stripContactPrefixes(String text) {
    return text
        .replaceFirst(
          RegExp(
            r"^(?:Tel|Telephone|Phone|Mob|Mobile|Cell|Email|E-mail|Web|Website|URL|Addr|Address)\s*[:\-]\s*",
            caseSensitive: false,
          ),
          "",
        )
        .trim();
  }

  static bool _isPureContactOrAddressLine(
    String line, {
    required List<String> emails,
    required List<String> phones,
    required List<String> urls,
    required List<String> addresses,
  }) {
    final lower = line.toLowerCase();
    for (final email in emails) {
      if (lower.contains(email.toLowerCase())) return true;
    }
    for (final phone in phones) {
      if (line.contains(phone)) return true;
    }
    for (final url in urls) {
      final host = url.replaceFirst(RegExp(r"^https?://"), "").toLowerCase();
      if (lower.contains(host)) return true;
    }
    for (final addr in addresses) {
      if (lower.contains(addr.toLowerCase()) ||
          addr.toLowerCase().contains(lower)) {
        return true;
      }
    }
    if (RegExp(r"^\+?\d[\d\s\-().]{6,}$").hasMatch(line)) return true;
    return false;
  }

  static bool _looksLikePersonName(String line) {
    if (RegExp(r"\d").hasMatch(line)) return false;
    if (line.contains("@") || line.contains("://")) return false;
    final words = line
        .split(RegExp(r"\s+"))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty || words.length > 4) return false;
    return words.every((w) => RegExp(r"^[A-Za-z.'\-]{1,24}$").hasMatch(w));
  }

  static ({String firstName, String lastName}) _splitPersonName(
    String fullName,
  ) {
    final cleaned = fullName
        .replaceFirst(
          RegExp(r"^(?:Dr|Mr|Ms|Mrs|Prof)\.?\s+", caseSensitive: false),
          "",
        )
        .trim();
    final parts = cleaned
        .split(RegExp(r"\s+"))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) {
      return (firstName: fullName, lastName: "");
    }
    if (parts.length == 1) {
      return (firstName: parts.first, lastName: "");
    }
    return (
      firstName: parts.sublist(0, parts.length - 1).join(" "),
      lastName: parts.last,
    );
  }

  static String _buildVCard30({
    required String fullName,
    required String firstName,
    required String lastName,
    String? organization,
    String? title,
    required List<String> phones,
    required List<String> emails,
    required List<String> urls,
    required List<String> addresses,
  }) {
    final lines = <String>[
      "BEGIN:VCARD",
      "VERSION:3.0",
      "N:${_escapeVCardValue(lastName)};${_escapeVCardValue(firstName)};;;",
      "FN:${_escapeVCardValue(fullName)}",
    ];

    if (organization != null && organization.trim().isNotEmpty) {
      lines.add("ORG:${_escapeVCardValue(organization.trim())}");
    }
    if (title != null && title.trim().isNotEmpty) {
      lines.add("TITLE:${_escapeVCardValue(title.trim())}");
    }
    for (var i = 0; i < phones.length; i++) {
      final type = i == 0 ? "WORK,VOICE" : "CELL";
      lines.add("TEL;TYPE=$type:${phones[i].trim()}");
    }
    for (final email in emails) {
      lines.add("EMAIL;TYPE=INTERNET,WORK:${email.trim()}");
    }
    for (final url in urls) {
      lines.add("URL:${url.trim()}");
    }
    for (final addr in addresses) {
      lines.add("ADR;TYPE=WORK:;;${_escapeVCardValue(addr.trim())};;;;");
    }
    lines.add("END:VCARD");
    return lines.join("\n");
  }

  static String _escapeVCardValue(String value) {
    return value
        .replaceAll("\\", "\\\\")
        .replaceAll(";", "\\;")
        .replaceAll(",", "\\,")
        .replaceAll("\r\n", "\\n")
        .replaceAll("\n", "\\n");
  }

  static String? _firstValueByType(
    List<ExtractedEntityItem> entities,
    String type,
  ) {
    for (final entity in entities) {
      if (entity.type == type) {
        return entity.rawValue;
      }
    }
    return null;
  }

  static String? _firstNormalizedOrRawByType(
    List<ExtractedEntityItem> entities,
    String type,
  ) {
    for (final entity in entities) {
      if (entity.type == type) {
        return entity.normalizedValue ?? entity.rawValue;
      }
    }
    return null;
  }

  static List<String> _uniqueValuesByTypes(
    List<ExtractedEntityItem> entities,
    List<String> types, {
    bool preferNormalized = false,
  }) {
    final seen = <String>{};
    final values = <String>[];
    for (final entity in entities) {
      if (!types.contains(entity.type)) continue;
      final candidate = (preferNormalized && entity.normalizedValue != null)
          ? entity.normalizedValue!
          : entity.rawValue;
      final key = candidate.trim().toLowerCase();
      if (key.isNotEmpty && seen.add(key)) {
        values.add(candidate.trim());
      }
    }
    return values;
  }
}
