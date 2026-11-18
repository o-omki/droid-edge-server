import "package:flutter/services.dart";
import "package:google_mlkit_entity_extraction/google_mlkit_entity_extraction.dart";

import "../models/openai_vision_models.dart";

abstract class EntityExtractionEngine {
  /// Returns extracted entities for [text] without triggering network calls.
  Future<List<ExtractedEntityItem>> extractEntities(String text);

  /// Whether the optional native ML Kit entity model is already cached offline.
  Future<bool> isNativeModelAvailable();

  Future<void> dispose();
}

/// Hybrid Tier 1 entity extractor combining locally cached Google ML Kit
/// Entity Extraction (when already present on device) with zero-download
/// deterministic regex extractors so 100% of devices operate offline.
class HybridEntityExtractionEngine implements EntityExtractionEngine {
  HybridEntityExtractionEngine({
    EntityExtractorModelManager? modelManager,
    EntityExtractor? extractor,
    bool enableNativeMlKit = true,
  }) : this._(
         modelManager: modelManager,
         extractor: extractor,
         enableNativeMlKit: enableNativeMlKit,
       );

  HybridEntityExtractionEngine._({
    this._modelManager,
    this._extractor,
    this._enableNativeMlKit = true,
  });

  final EntityExtractorModelManager? _modelManager;
  final EntityExtractor? _extractor;
  final bool _enableNativeMlKit;

  EntityExtractorModelManager? _lazyManager;
  EntityExtractor? _lazyExtractor;

  @override
  Future<bool> isNativeModelAvailable() async {
    if (!_enableNativeMlKit) return false;
    try {
      final manager = _modelManager ?? (_lazyManager ??= EntityExtractorModelManager());
      return await manager.isModelDownloaded(
        EntityExtractorLanguage.english.name,
      );
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<ExtractedEntityItem>> extractEntities(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const [];
    }

    final merged = <ExtractedEntityItem>[];
    final seenKeys = <String>{};

    void addUnique(ExtractedEntityItem item) {
      final key = "${item.type}::${item.rawValue.trim().toLowerCase()}";
      if (seenKeys.add(key)) {
        merged.add(item);
      }
    }

    if (_enableNativeMlKit) {
      final downloaded = await isNativeModelAvailable();
      if (downloaded) {
        try {
          final extractor = _extractor ??
              (_lazyExtractor ??= EntityExtractor(
                language: EntityExtractorLanguage.english,
              ));
          final annotations = await extractor.annotateText(trimmed);
          for (final annotation in annotations) {
            for (final entity in annotation.entities) {
              final converted = _convertMlKitEntity(annotation.text, entity);
              if (converted != null) {
                addUnique(converted);
              }
            }
          }
        } on MissingPluginException {
          // Headless test or non-mobile platform; deterministic rules handle it.
        } on PlatformException {
          // Fall back silently to deterministic rules below.
        } catch (_) {
          // Ensure entity extraction never fails offline requests.
        }
      }
    }

    for (final item in DeterministicEntityRegexExtractor.extract(trimmed)) {
      addUnique(item);
    }

    return merged;
  }

  static ExtractedEntityItem? _convertMlKitEntity(
    String rawText,
    Entity entity,
  ) {
    if (entity is DateTimeEntity) {
      final dt = DateTime.fromMillisecondsSinceEpoch(
        entity.timestamp,
        isUtc: true,
      );
      final iso = dt.toIso8601String().split("T").first;
      return ExtractedEntityItem(
        type: "date_time",
        rawValue: rawText,
        normalizedValue: iso,
      );
    }
    if (entity is MoneyEntity) {
      final parsedFromRaw = DeterministicEntityRegexExtractor.parseAmountValue(
        rawText,
      );
      final fallbackAmount =
          entity.integerPart + (entity.fractionPart / 100.0);
      final currencyCode = DeterministicEntityRegexExtractor.normalizeCurrency(
        entity.unnormalizedCurrency.isNotEmpty
            ? entity.unnormalizedCurrency
            : rawText,
      );
      return ExtractedEntityItem(
        type: "money",
        rawValue: rawText,
        currency: currencyCode,
        amount: parsedFromRaw ?? fallbackAmount,
      );
    }
    if (entity is PhoneEntity) {
      return ExtractedEntityItem(
        type: "phone",
        rawValue: rawText,
        normalizedValue: rawText.replaceAll(RegExp(r"\s+"), " ").trim(),
      );
    }
    if (entity is EmailEntity) {
      return ExtractedEntityItem(
        type: "email",
        rawValue: rawText,
        normalizedValue: rawText.trim().toLowerCase(),
      );
    }
    if (entity is AddressEntity) {
      return ExtractedEntityItem(
        type: "address",
        rawValue: rawText,
      );
    }
    if (entity is IbanEntity) {
      return ExtractedEntityItem(
        type: "iban",
        rawValue: rawText,
        normalizedValue: entity.iban,
      );
    }
    if (entity is UrlEntity) {
      return ExtractedEntityItem(
        type: "url",
        rawValue: rawText,
        normalizedValue: rawText.trim(),
      );
    }
    if (entity is PaymentCardEntity) {
      return ExtractedEntityItem(
        type: "payment_card",
        rawValue: rawText,
        normalizedValue: entity.number,
      );
    }
    return null;
  }

  @override
  Future<void> dispose() async {
    final extractor = _lazyExtractor ?? _extractor;
    if (extractor != null) {
      try {
        await extractor.close();
      } catch (_) {}
    }
    _lazyExtractor = null;
  }
}

/// Pure-Dart zero-download deterministic entity extractor used as the universal
/// baseline across all Android devices (including air-gapped handsets).
class DeterministicEntityRegexExtractor {
  const DeterministicEntityRegexExtractor._();

  static final RegExp _emailRegex = RegExp(
    r"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b",
  );

  static final RegExp _upiRegex = RegExp(
    r"\b[A-Za-z0-9._\-]{2,256}@(?:okaxis|okhdfcbank|okicici|oksbi|ybl|ibl|axl|paytm|upi|apl|fbl|kotak|axisbank|hdfcbank|icici|sbi|pnb|boi|barodampay|idfcbank|indus|yesbank|federal|rbl|citi|hsbc|dbs|freecharge|mobikwik|airtel|jio)\b",
    caseSensitive: false,
  );

  static final RegExp _urlRegex = RegExp(
    r"\b(?:https?://|www\.)[A-Za-z0-9.\-]+\.[A-Za-z]{2,}(?:/[^\s,)>]*)?\b",
    caseSensitive: false,
  );

  static final RegExp _domainUrlRegex = RegExp(
    r"(?<![@\w.])\b[a-z0-9][a-z0-9\-]{1,61}\.(?:com|org|net|io|ai|co|in|uk|de|dev|app|tech|biz|info)(?:/[^\s,)>]*)?\b",
    caseSensitive: false,
  );

  static final RegExp _intlOrUsPhoneRegex = RegExp(
    r"(?<!\d)(?:\+\d{1,3}[\s\-.]?)?(?:\(\d{2,4}\)|\d{2,4})[\s\-.]\d{3,4}[\s\-.]\d{3,4}(?!\d)",
  );

  static final RegExp _indianMobileRegex = RegExp(
    r"(?<!\d)(?:\+91[\s\-.]?|91[\s\-.]|0)?[6-9]\d{4}[\s\-]?\d{5}(?!\d)",
  );

  static final RegExp _labeledPhoneRegex = RegExp(
    r"\b(?:Tel|Telephone|Phone|Mobile|Mob|Cell|Fax|Ph)\b\s*[:#\-]?\s*([+\d()\-\s.]{7,20}\d)",
    caseSensitive: false,
  );

  static final RegExp _isoDateRegex = RegExp(
    r"\b(?:19|20)\d{2}[/\-](?:0?[1-9]|1[0-2])[/\-](?:0?[1-9]|[12]\d|3[01])\b",
  );

  static final RegExp _slashDateRegex = RegExp(
    r"\b(?:0?[1-9]|[12]\d|3[01])[/\-](?:0?[1-9]|1[0-2])[/\-](?:(?:19|20)?\d{2})\b",
  );

  static final RegExp _namedMonthDateRegex = RegExp(
    r"\b(?:(?:0?[1-9]|[12]\d|3[01])(?:\s+(?:of\s+)?)?(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?),?\s+(?:19|20)\d{2}|(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+(?:0?[1-9]|[12]\d|3[01]),?\s+(?:19|20)\d{2})\b",
    caseSensitive: false,
  );

  static final RegExp _moneyPrefixRegex = RegExp(
    r"(?:[$€£¥₹]|USD|EUR|GBP|INR|CAD|AUD|Rs\.?)\s*[\d,]+(?:\.\d{1,2})?",
    caseSensitive: false,
  );

  static final RegExp _moneySuffixRegex = RegExp(
    r"\b[\d,]+(?:\.\d{1,2})?\s*(?:USD|EUR|GBP|INR|CAD|AUD)\b",
    caseSensitive: false,
  );

  static final RegExp _gstinRegex = RegExp(
    r"\b\d{2}[A-Z]{5}\d{4}[A-Z][1-9A-Z]Z[0-9A-Z]\b",
  );

  static final RegExp _panRegex = RegExp(r"\b[A-Z]{5}\d{4}[A-Z]\b");

  static final RegExp _labeledTaxIdRegex = RegExp(
    r"\b(?:GSTIN|GST\s*(?:No|ID|#)?|VAT(?:\s*(?:No|ID|#))?|TIN|EIN|PAN|ABN|Tax\s*ID)\b\s*[:#\-]?\s*([A-Z0-9\-]{6,22})",
    caseSensitive: false,
  );

  static final RegExp _invoiceNumberRegex = RegExp(
    r"\b(?:Invoice|Inv|Bill|Receipt|Order|Ref(?:erence)?)\s*(?:No\.?|Num(?:ber)?|#)?\s*[:#\-]\s*([A-Z0-9][A-Z0-9\-/]{2,24})",
    caseSensitive: false,
  );

  static final RegExp _invoiceHashRegex = RegExp(
    r"\b(?:Invoice|Inv|Bill|Receipt|Order)\s+#([A-Z0-9][A-Z0-9\-/]{2,24})",
    caseSensitive: false,
  );

  static final RegExp _ibanRegex = RegExp(
    r"\b[A-Z]{2}\d{2}[A-Z0-9]{10,28}\b",
  );

  static final RegExp _streetAddressRegex = RegExp(
    r"\b\d{1,6}\s+(?:[A-Za-z0-9.#\-]+\s+){1,5}(?:Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Lane|Ln|Drive|Dr|Court|Ct|Way|Parkway|Pkwy|Circle|Cir|Place|Pl|Suite|Ste)\b\.?(?:[,\s]+[A-Za-z0-9\s,\-]{2,45})?",
    caseSensitive: false,
  );

  static final RegExp _postalAddressRegex = RegExp(
    r"\b(?:[A-Za-z.\s]{2,28},\s*[A-Z]{2}\s+\d{5}(?:-\d{4})?|[A-Za-z.\s]{3,28}\s*[,\-]\s*[1-9]\d{2}\s?\d{3})\b",
  );

  static List<ExtractedEntityItem> extract(String text) {
    final items = <ExtractedEntityItem>[];

    for (final m in _emailRegex.allMatches(text)) {
      final raw = m.group(0)!;
      items.add(
        ExtractedEntityItem(
          type: "email",
          rawValue: raw,
          normalizedValue: raw.toLowerCase(),
        ),
      );
    }

    for (final m in _upiRegex.allMatches(text)) {
      final raw = m.group(0)!;
      items.add(
        ExtractedEntityItem(
          type: "upi",
          rawValue: raw,
          normalizedValue: raw.toLowerCase(),
        ),
      );
    }

    for (final m in _urlRegex.allMatches(text)) {
      final raw = m.group(0)!;
      final normalized = raw.toLowerCase().startsWith("http")
          ? raw
          : "https://$raw";
      items.add(
        ExtractedEntityItem(
          type: "url",
          rawValue: raw,
          normalizedValue: normalized,
        ),
      );
    }

    for (final m in _domainUrlRegex.allMatches(text)) {
      final raw = m.group(0)!;
      items.add(
        ExtractedEntityItem(
          type: "url",
          rawValue: raw,
          normalizedValue: "https://$raw",
        ),
      );
    }

    for (final m in _labeledPhoneRegex.allMatches(text)) {
      final raw = m.group(1)?.trim();
      if (raw == null) continue;
      final digits = raw.replaceAll(RegExp(r"\D"), "");
      if (digits.length >= 7 && digits.length <= 15) {
        items.add(ExtractedEntityItem(type: "phone", rawValue: raw));
      }
    }

    for (final m in _indianMobileRegex.allMatches(text)) {
      final raw = m.group(0)!.trim();
      items.add(ExtractedEntityItem(type: "phone", rawValue: raw));
    }

    for (final m in _intlOrUsPhoneRegex.allMatches(text)) {
      final raw = m.group(0)!.trim();
      final digits = raw.replaceAll(RegExp(r"\D"), "");
      if (digits.length >= 7 && digits.length <= 15) {
        items.add(ExtractedEntityItem(type: "phone", rawValue: raw));
      }
    }

    for (final m in _isoDateRegex.allMatches(text)) {
      final raw = m.group(0)!;
      items.add(
        ExtractedEntityItem(
          type: "date_time",
          rawValue: raw,
          normalizedValue: raw.replaceAll("/", "-"),
        ),
      );
    }
    for (final m in _namedMonthDateRegex.allMatches(text)) {
      items.add(ExtractedEntityItem(type: "date_time", rawValue: m.group(0)!));
    }
    for (final m in _slashDateRegex.allMatches(text)) {
      items.add(ExtractedEntityItem(type: "date_time", rawValue: m.group(0)!));
    }

    for (final m in _moneyPrefixRegex.allMatches(text)) {
      final raw = m.group(0)!.trim();
      items.add(
        ExtractedEntityItem(
          type: "money",
          rawValue: raw,
          currency: normalizeCurrency(raw),
          amount: parseAmountValue(raw),
        ),
      );
    }

    for (final m in _moneySuffixRegex.allMatches(text)) {
      final raw = m.group(0)!.trim();
      items.add(
        ExtractedEntityItem(
          type: "money",
          rawValue: raw,
          currency: normalizeCurrency(raw),
          amount: parseAmountValue(raw),
        ),
      );
    }

    for (final m in _gstinRegex.allMatches(text)) {
      items.add(
        ExtractedEntityItem(
          type: "tax_id",
          rawValue: m.group(0)!,
          normalizedValue: "GSTIN:${m.group(0)!}",
        ),
      );
    }

    for (final m in _panRegex.allMatches(text)) {
      items.add(
        ExtractedEntityItem(
          type: "tax_id",
          rawValue: m.group(0)!,
          normalizedValue: "PAN:${m.group(0)!}",
        ),
      );
    }

    for (final m in _labeledTaxIdRegex.allMatches(text)) {
      final val = m.group(1)?.trim();
      if (val != null && val.length >= 6) {
        items.add(ExtractedEntityItem(type: "tax_id", rawValue: val));
      }
    }

    for (final m in _invoiceNumberRegex.allMatches(text)) {
      final val = m.group(1)?.trim();
      if (val != null && RegExp(r"\d").hasMatch(val)) {
        items.add(ExtractedEntityItem(type: "invoice_number", rawValue: val));
      }
    }

    for (final m in _invoiceHashRegex.allMatches(text)) {
      final val = m.group(1)?.trim();
      if (val != null && RegExp(r"\d").hasMatch(val)) {
        items.add(ExtractedEntityItem(type: "invoice_number", rawValue: val));
      }
    }

    for (final m in _ibanRegex.allMatches(text)) {
      items.add(ExtractedEntityItem(type: "iban", rawValue: m.group(0)!));
    }

    for (final m in _streetAddressRegex.allMatches(text)) {
      items.add(
        ExtractedEntityItem(type: "address", rawValue: m.group(0)!.trim()),
      );
    }
    for (final m in _postalAddressRegex.allMatches(text)) {
      items.add(
        ExtractedEntityItem(type: "address", rawValue: m.group(0)!.trim()),
      );
    }

    return items;
  }

  /// Parses the first numeric amount found in [raw].
  static double? parseAmountValue(String raw) {
    final match = RegExp(r"[\d,]+(?:\.\d{1,2})?").firstMatch(raw);
    if (match == null) return null;
    final cleaned = match.group(0)!.replaceAll(",", "");
    return double.tryParse(cleaned);
  }

  /// Normalises a currency symbol or ISO code into a 3-letter currency code.
  static String? normalizeCurrency(String raw) {
    final upper = raw.toUpperCase();
    if (raw.contains("\$") || upper.contains("USD")) return "USD";
    if (raw.contains("₹") || upper.contains("INR") || upper.contains("RS")) {
      return "INR";
    }
    if (raw.contains("€") || upper.contains("EUR")) return "EUR";
    if (raw.contains("£") || upper.contains("GBP")) return "GBP";
    if (raw.contains("¥") || upper.contains("JPY")) return "JPY";
    if (upper.contains("CAD")) return "CAD";
    if (upper.contains("AUD")) return "AUD";
    return null;
  }
}
