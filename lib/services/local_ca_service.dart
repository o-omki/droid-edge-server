import "dart:convert";
import "dart:io";
import "dart:math";
import "dart:typed_data";

import "package:crypto/crypto.dart" as pkg_crypto;
import "package:path_provider/path_provider.dart";
import "package:pointycastle/asn1.dart";
import "package:pointycastle/export.dart";
import "package:share_plus/share_plus.dart";

import "secure_key_store.dart";

/// Holds the generated on-device TLS bundle signed by the persistent local
/// Root CA.
class TlsBundle {
  const TlsBundle({
    required this.caCertPem,
    required this.leafCertPem,
    required this.leafKeyPem,
    required this.caFingerprintSha256,
    required this.sanIps,
    required this.hostname,
  });

  final String caCertPem;
  final String leafCertPem;
  final String leafKeyPem;
  final String caFingerprintSha256;
  final List<String> sanIps;
  final String hostname;
}

/// Manages a persistent on-device ECDSA P-256 Root CA and mints short-lived
/// leaf certificates containing the device's current LAN IP and mDNS SANs.
///
/// Operates 100% offline using pure-Dart cryptographic primitives.
class LocalCaService {
  LocalCaService({SecureKeyStore? keyStore})
    : _keyStore = keyStore ?? FlutterSecureKeyStore();

  static const String caCertStorageKey = "edge_local_ca_cert_pem";
  static const String caKeyStorageKey = "edge_local_ca_key_pem";

  static const String _oidEcPublicKey = "1.2.840.10045.2.1";
  static const String _oidPrime256v1 = "1.2.840.10045.3.1.7";
  static const String _oidEcdsaWithSha256 = "1.2.840.10045.4.3.2";
  static const String _oidCommonName = "2.5.4.3";
  static const String _oidOrganizationName = "2.5.4.10";
  static const String _oidSubjectKeyId = "2.5.29.14";
  static const String _oidKeyUsage = "2.5.29.15";
  static const String _oidSubjectAltName = "2.5.29.17";
  static const String _oidBasicConstraints = "2.5.29.19";
  static const String _oidAuthorityKeyId = "2.5.29.35";
  static const String _oidExtKeyUsage = "2.5.29.37";
  static const String _oidServerAuth = "1.3.6.1.5.5.7.3.1";

  final SecureKeyStore _keyStore;

  /// Returns the existing Root CA certificate, PKCS#8 private key, and SHA-256
  /// fingerprint, generating and persisting a new Root CA on first run.
  Future<({String caCertPem, String caKeyPem, String caFingerprintSha256})>
  getOrCreateCa() async {
    final existingCert = await _keyStore.read(caCertStorageKey);
    final existingKey = await _keyStore.read(caKeyStorageKey);

    if (existingCert != null &&
        existingKey != null &&
        existingCert.contains("BEGIN CERTIFICATE") &&
        existingKey.contains("BEGIN PRIVATE KEY")) {
      try {
        // Verify the stored CA key parses cleanly before reusing it.
        _decodePkcs8EcKeyPair(existingKey);
        final fingerprint = computeCertFingerprintSha256(existingCert);
        return (
          caCertPem: existingCert,
          caKeyPem: existingKey,
          caFingerprintSha256: fingerprint,
        );
      } catch (_) {
        // Regenerate below if stored material was corrupted.
      }
    }

    final caPair = _generateP256KeyPair();
    final caKeyPem = _encodePkcs8EcPrivateKeyPem(caPair.privateKey);
    final caSubject = _buildDistinguishedName(
      commonName: "Droid Edge Server Local Root CA",
      organization: "Droid Edge Server",
    );
    final caPubBytes = _encodeUncompressedEcPoint(caPair.publicKey);
    final caSki = _sha1Digest(caPubBytes);

    final now = DateTime.now().toUtc();
    final notBefore = now.subtract(const Duration(minutes: 5));
    final notAfter = now.add(const Duration(days: 3650));

    final caExtensions = <ASN1Object>[
      _buildBasicConstraintsExtension(isCa: true, pathLenConstraint: 0),
      _buildKeyUsageExtension(
        digitalSignature: false,
        keyEncipherment: false,
        keyCertSign: true,
        cRLSign: true,
      ),
      _buildSubjectKeyIdExtension(caSki),
    ];

    final tbsCa = _buildTbsCertificate(
      serialNumber: _randomPositiveSerial(),
      issuer: caSubject,
      subject: caSubject,
      notBefore: notBefore,
      notAfter: notAfter,
      publicKeyBytes: caPubBytes,
      extensions: caExtensions,
    );

    final caCertPem = _signAndEncodeCertPem(tbsCa, caPair.privateKey);
    await _keyStore.write(caCertStorageKey, caCertPem);
    await _keyStore.write(caKeyStorageKey, caKeyPem);

    return (
      caCertPem: caCertPem,
      caKeyPem: caKeyPem,
      caFingerprintSha256: computeCertFingerprintSha256(caCertPem),
    );
  }

  /// Mints a fresh leaf certificate signed by the persistent Root CA for
  /// [ipAddresses] and [hostname].
  Future<TlsBundle> mintTlsBundle({
    required List<String> ipAddresses,
    String hostname = "android-edge.local",
  }) async {
    final ca = await getOrCreateCa();
    final caPair = _decodePkcs8EcKeyPair(ca.caKeyPem);
    final caPubBytes = _encodeUncompressedEcPoint(caPair.publicKey);
    final caSki = _sha1Digest(caPubBytes);

    final leafPair = _generateP256KeyPair();
    final leafKeyPem = _encodePkcs8EcPrivateKeyPem(leafPair.privateKey);
    final leafPubBytes = _encodeUncompressedEcPoint(leafPair.publicKey);
    final leafSki = _sha1Digest(leafPubBytes);

    final sanIps = <String>[];
    for (final rawIp in ipAddresses) {
      final parsed = InternetAddress.tryParse(rawIp.trim());
      if (parsed != null &&
          parsed.type == InternetAddressType.IPv4 &&
          !parsed.isMulticast &&
          parsed.address != "0.0.0.0" &&
          !sanIps.contains(parsed.address)) {
        sanIps.add(parsed.address);
      }
    }
    if (!sanIps.contains("127.0.0.1")) {
      sanIps.add("127.0.0.1");
    }

    final cleanHost = hostname.trim().isEmpty
        ? "android-edge.local"
        : hostname.trim().toLowerCase();
    final dnsNames = <String>{cleanHost, "localhost"}.toList();

    final caSubject = _buildDistinguishedName(
      commonName: "Droid Edge Server Local Root CA",
      organization: "Droid Edge Server",
    );
    final leafSubject = _buildDistinguishedName(
      commonName: cleanHost,
      organization: "Droid Edge Server",
    );

    final now = DateTime.now().toUtc();
    final notBefore = now.subtract(const Duration(minutes: 5));
    final notAfter = now.add(const Duration(days: 395));

    final leafExtensions = <ASN1Object>[
      _buildBasicConstraintsExtension(isCa: false),
      _buildKeyUsageExtension(
        digitalSignature: true,
        keyEncipherment: true,
        keyCertSign: false,
        cRLSign: false,
      ),
      _buildExtKeyUsageServerAuthExtension(),
      _buildSubjectKeyIdExtension(leafSki),
      _buildAuthorityKeyIdExtension(caSki),
      _buildSanExtension(dnsNames: dnsNames, ipv4Addresses: sanIps),
    ];

    final tbsLeaf = _buildTbsCertificate(
      serialNumber: _randomPositiveSerial(),
      issuer: caSubject,
      subject: leafSubject,
      notBefore: notBefore,
      notAfter: notAfter,
      publicKeyBytes: leafPubBytes,
      extensions: leafExtensions,
    );

    final leafCertPem = _signAndEncodeCertPem(tbsLeaf, caPair.privateKey);
    return TlsBundle(
      caCertPem: ca.caCertPem,
      leafCertPem: leafCertPem,
      leafKeyPem: leafKeyPem,
      caFingerprintSha256: ca.caFingerprintSha256,
      sanIps: sanIps,
      hostname: cleanHost,
    );
  }

  /// Builds a Dart [SecurityContext] configured with the leaf certificate chain
  /// and leaf private key for `shelf_io.serve`.
  SecurityContext buildServerSecurityContext(TlsBundle bundle) {
    final context = SecurityContext();
    final chainPem = "${bundle.leafCertPem}\n${bundle.caCertPem}";
    context.useCertificateChainBytes(utf8.encode(chainPem));
    context.usePrivateKeyBytes(utf8.encode(bundle.leafKeyPem));
    return context;
  }

  /// Writes `droid-edge-ca.crt` to a temporary file and opens the platform
  /// share/save sheet so the user can export and trust the Local Root CA.
  Future<File> exportCaCertificateFile(String caCertPem) async {
    final dir = await getTemporaryDirectory();
    final file = File("${dir.path}/droid-edge-ca.crt");
    await file.writeAsString(caCertPem, flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        subject: "Droid Edge Server Local CA",
        text:
            "Install this Local Root CA certificate on paired LAN devices to "
            "trust HTTPS connections to Droid Edge Server.",
      ),
    );
    return file;
  }

  /// Returns the colon-separated uppercase SHA-256 fingerprint of a PEM
  /// certificate.
  static String computeCertFingerprintSha256(String certPem) {
    final der = _decodePem(certPem, "CERTIFICATE");
    final digest = pkg_crypto.sha256.convert(der).bytes;
    return digest
        .map((b) => b.toRadixString(16).padLeft(2, "0").toUpperCase())
        .join(":");
  }

  static AsymmetricKeyPair<ECPublicKey, ECPrivateKey> _generateP256KeyPair() {
    final domain = ECCurve_secp256r1();
    final secureRandom = _createFortunaRandom();
    final generator = ECKeyGenerator()
      ..init(
        ParametersWithRandom(ECKeyGeneratorParameters(domain), secureRandom),
      );
    final pair = generator.generateKeyPair();
    return AsymmetricKeyPair<ECPublicKey, ECPrivateKey>(
      pair.publicKey,
      pair.privateKey,
    );
  }

  static FortunaRandom _createFortunaRandom() {
    final osRandom = Random.secure();
    final seed = Uint8List.fromList(
      List<int>.generate(32, (_) => osRandom.nextInt(256)),
    );
    return FortunaRandom()..seed(KeyParameter(seed));
  }

  static String _encodePkcs8EcPrivateKeyPem(ECPrivateKey privateKey) {
    final domain = ECCurve_secp256r1();
    final dBytes = _bigIntToFixedBytes(privateKey.d!, 32);
    final pubPoint = domain.G * privateKey.d!;
    final pubBytes = _encodeEcPointBytes(pubPoint!);

    final sec1Key = ASN1Sequence(
      elements: [
        ASN1Integer(BigInt.one),
        ASN1OctetString(octets: dBytes),
        _derTlv(0xA1, ASN1BitString(stringValues: pubBytes).encode()),
      ],
    );

    final algId = ASN1Sequence(
      elements: [
        ASN1ObjectIdentifier.fromIdentifierString(_oidEcPublicKey),
        ASN1ObjectIdentifier.fromIdentifierString(_oidPrime256v1),
      ],
    );

    final pkcs8 = ASN1Sequence(
      elements: [
        ASN1Integer(BigInt.zero),
        algId,
        ASN1OctetString(octets: sec1Key.encode()),
      ],
    );

    return _encodePem(pkcs8.encode(), "PRIVATE KEY");
  }

  static AsymmetricKeyPair<ECPublicKey, ECPrivateKey> _decodePkcs8EcKeyPair(
    String pem,
  ) {
    final der = _decodePem(pem, "PRIVATE KEY");
    final parser = ASN1Parser(der);
    final pkcs8Seq = parser.nextObject() as ASN1Sequence;
    final keyOctets = (pkcs8Seq.elements![2] as ASN1OctetString).octets!;

    final sec1Parser = ASN1Parser(keyOctets);
    final sec1Seq = sec1Parser.nextObject() as ASN1Sequence;
    final dBytes = (sec1Seq.elements![1] as ASN1OctetString).octets!;
    final d = _bytesToBigInt(dBytes);

    final domain = ECCurve_secp256r1();
    final priv = ECPrivateKey(d, domain);
    final pub = ECPublicKey((domain.G * d)!, domain);
    return AsymmetricKeyPair<ECPublicKey, ECPrivateKey>(pub, priv);
  }

  static Uint8List _encodeUncompressedEcPoint(ECPublicKey publicKey) {
    return _encodeEcPointBytes(publicKey.Q!);
  }

  static Uint8List _encodeEcPointBytes(ECPoint point) {
    final x = _bigIntToFixedBytes(point.x!.toBigInteger()!, 32);
    final y = _bigIntToFixedBytes(point.y!.toBigInteger()!, 32);
    return Uint8List.fromList(<int>[0x04, ...x, ...y]);
  }

  static ASN1Sequence _buildDistinguishedName({
    required String commonName,
    required String organization,
  }) {
    return ASN1Sequence(
      elements: [
        ASN1Set(
          elements: [
            ASN1Sequence(
              elements: [
                ASN1ObjectIdentifier.fromIdentifierString(_oidOrganizationName),
                ASN1UTF8String(utf8StringValue: organization),
              ],
            ),
          ],
        ),
        ASN1Set(
          elements: [
            ASN1Sequence(
              elements: [
                ASN1ObjectIdentifier.fromIdentifierString(_oidCommonName),
                ASN1UTF8String(utf8StringValue: commonName),
              ],
            ),
          ],
        ),
      ],
    );
  }

  static ASN1Sequence _buildTbsCertificate({
    required BigInt serialNumber,
    required ASN1Sequence issuer,
    required ASN1Sequence subject,
    required DateTime notBefore,
    required DateTime notAfter,
    required Uint8List publicKeyBytes,
    required List<ASN1Object> extensions,
  }) {
    final sigAlg = ASN1Sequence(
      elements: [
        ASN1ObjectIdentifier.fromIdentifierString(_oidEcdsaWithSha256),
      ],
    );

    final spki = ASN1Sequence(
      elements: [
        ASN1Sequence(
          elements: [
            ASN1ObjectIdentifier.fromIdentifierString(_oidEcPublicKey),
            ASN1ObjectIdentifier.fromIdentifierString(_oidPrime256v1),
          ],
        ),
        ASN1BitString(stringValues: publicKeyBytes),
      ],
    );

    final validity = ASN1Sequence(
      elements: [_encodeX509Time(notBefore), _encodeX509Time(notAfter)],
    );

    final extensionsSeq = ASN1Sequence(elements: extensions);

    return ASN1Sequence(
      elements: [
        _derTlv(0xA0, ASN1Integer(BigInt.from(2)).encode()), // v3
        ASN1Integer(serialNumber),
        sigAlg,
        issuer,
        validity,
        subject,
        spki,
        _derTlv(0xA3, extensionsSeq.encode()),
      ],
    );
  }

  static ASN1Object _encodeX509Time(DateTime dt) {
    final utc = dt.toUtc();
    if (utc.year < 2050) {
      return ASN1UtcTime(utc);
    }
    return ASN1GeneralizedTime(utc);
  }

  static ASN1Sequence _buildBasicConstraintsExtension({
    required bool isCa,
    int? pathLenConstraint,
  }) {
    final seq = ASN1Sequence(
      elements: [
        ASN1Boolean(isCa),
        if (isCa && pathLenConstraint != null)
          ASN1Integer(BigInt.from(pathLenConstraint)),
      ],
    );
    return ASN1Sequence(
      elements: [
        ASN1ObjectIdentifier.fromIdentifierString(_oidBasicConstraints),
        ASN1Boolean(true),
        ASN1OctetString(octets: seq.encode()),
      ],
    );
  }

  static ASN1Sequence _buildKeyUsageExtension({
    required bool digitalSignature,
    required bool keyEncipherment,
    required bool keyCertSign,
    required bool cRLSign,
  }) {
    // KeyUsage bits are ordered MSB-first in byte 0:
    // 0: digitalSignature (0x80), 2: keyEncipherment (0x20),
    // 5: keyCertSign (0x04), 6: cRLSign (0x02).
    var mask = 0;
    if (digitalSignature) mask |= 0x80;
    if (keyEncipherment) mask |= 0x20;
    if (keyCertSign) mask |= 0x04;
    if (cRLSign) mask |= 0x02;

    final unusedBits = _trailingZeroBits(mask);
    final bitString = ASN1BitString(stringValues: [mask])
      ..unusedbits = unusedBits;

    return ASN1Sequence(
      elements: [
        ASN1ObjectIdentifier.fromIdentifierString(_oidKeyUsage),
        ASN1Boolean(true),
        ASN1OctetString(octets: bitString.encode()),
      ],
    );
  }

  static int _trailingZeroBits(int byteValue) {
    if (byteValue == 0) return 0;
    var count = 0;
    var v = byteValue & 0xFF;
    while ((v & 1) == 0 && count < 7) {
      count++;
      v >>= 1;
    }
    return count;
  }

  static ASN1Sequence _buildExtKeyUsageServerAuthExtension() {
    final seq = ASN1Sequence(
      elements: [ASN1ObjectIdentifier.fromIdentifierString(_oidServerAuth)],
    );
    return ASN1Sequence(
      elements: [
        ASN1ObjectIdentifier.fromIdentifierString(_oidExtKeyUsage),
        ASN1OctetString(octets: seq.encode()),
      ],
    );
  }

  static ASN1Sequence _buildSubjectKeyIdExtension(Uint8List keyId) {
    return ASN1Sequence(
      elements: [
        ASN1ObjectIdentifier.fromIdentifierString(_oidSubjectKeyId),
        ASN1OctetString(octets: ASN1OctetString(octets: keyId).encode()),
      ],
    );
  }

  static ASN1Sequence _buildAuthorityKeyIdExtension(Uint8List caKeyId) {
    final seq = ASN1Sequence(elements: [_derTlv(0x80, caKeyId)]);
    return ASN1Sequence(
      elements: [
        ASN1ObjectIdentifier.fromIdentifierString(_oidAuthorityKeyId),
        ASN1OctetString(octets: seq.encode()),
      ],
    );
  }

  static ASN1Sequence _buildSanExtension({
    required List<String> dnsNames,
    required List<String> ipv4Addresses,
  }) {
    final names = <ASN1Object>[
      for (final dns in dnsNames) _derTlv(0x82, ascii.encode(dns)), // dNSName
      for (final ip in ipv4Addresses)
        _derTlv(0x87, InternetAddress(ip).rawAddress), // iPAddress
    ];
    final generalNames = ASN1Sequence(elements: names);
    return ASN1Sequence(
      elements: [
        ASN1ObjectIdentifier.fromIdentifierString(_oidSubjectAltName),
        ASN1OctetString(octets: generalNames.encode()),
      ],
    );
  }

  static String _signAndEncodeCertPem(
    ASN1Sequence tbsCertificate,
    ECPrivateKey signingKey,
  ) {
    final tbsDer = tbsCertificate.encode();
    final signer = ECDSASigner(SHA256Digest(), null)
      ..init(
        true,
        ParametersWithRandom(
          PrivateKeyParameter<ECPrivateKey>(signingKey),
          _createFortunaRandom(),
        ),
      );
    final rawSig = signer.generateSignature(tbsDer) as ECSignature;

    // Normalise S into the lower half of the curve order (canonical ECDSA).
    final n = ECCurve_secp256r1().n;
    final halfN = n >> 1;
    final s = rawSig.s > halfN ? n - rawSig.s : rawSig.s;

    final sigDer = ASN1Sequence(
      elements: [ASN1Integer(rawSig.r), ASN1Integer(s)],
    ).encode();

    final certSeq = ASN1Sequence(
      elements: [
        tbsCertificate,
        ASN1Sequence(
          elements: [
            ASN1ObjectIdentifier.fromIdentifierString(_oidEcdsaWithSha256),
          ],
        ),
        ASN1BitString(stringValues: sigDer),
      ],
    );

    return _encodePem(certSeq.encode(), "CERTIFICATE");
  }

  static _RawDerObject _derTlv(int tag, List<int> content) {
    final len = content.length;
    final header = <int>[tag];
    if (len < 128) {
      header.add(len);
    } else {
      final lenBytes = <int>[];
      var remaining = len;
      while (remaining > 0) {
        lenBytes.insert(0, remaining & 0xFF);
        remaining >>= 8;
      }
      header.add(0x80 | lenBytes.length);
      header.addAll(lenBytes);
    }
    return _RawDerObject(Uint8List.fromList([...header, ...content]));
  }

  static BigInt _randomPositiveSerial() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[0] = (bytes[0] & 0x7F) | 0x01; // Ensure positive non-zero MSB.
    return _bytesToBigInt(Uint8List.fromList(bytes));
  }

  static Uint8List _sha1Digest(Uint8List input) {
    return Uint8List.fromList(pkg_crypto.sha1.convert(input).bytes);
  }

  static Uint8List _bigIntToFixedBytes(BigInt value, int length) {
    final result = Uint8List(length);
    var v = value;
    for (var i = length - 1; i >= 0; i--) {
      result[i] = (v & BigInt.from(0xFF)).toInt();
      v >>= 8;
    }
    return result;
  }

  static BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b);
    }
    return result;
  }

  static String _encodePem(Uint8List der, String label) {
    final b64 = base64Encode(der);
    final buffer = StringBuffer("-----BEGIN $label-----\n");
    for (var i = 0; i < b64.length; i += 64) {
      final end = (i + 64 < b64.length) ? i + 64 : b64.length;
      buffer.writeln(b64.substring(i, end));
    }
    buffer.write("-----END $label-----");
    return buffer.toString();
  }

  static Uint8List _decodePem(String pem, String label) {
    final beginMarker = "-----BEGIN $label-----";
    final endMarker = "-----END $label-----";
    final start = pem.indexOf(beginMarker);
    final end = pem.indexOf(endMarker);
    if (start < 0 || end <= start) {
      throw FormatException("Invalid PEM block for $label.");
    }
    final body = pem
        .substring(start + beginMarker.length, end)
        .replaceAll(RegExp(r"\s+"), "");
    return Uint8List.fromList(base64Decode(body));
  }
}

class _RawDerObject extends ASN1Object {
  _RawDerObject(this._derBytes) : super(tag: _derBytes.first);

  final Uint8List _derBytes;

  @override
  Uint8List encode({
    ASN1EncodingRule encodingRule = ASN1EncodingRule.ENCODING_DER,
  }) => _derBytes;
}
