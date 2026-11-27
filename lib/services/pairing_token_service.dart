import "dart:convert";
import "dart:math";

import "package:crypto/crypto.dart";

import "secure_key_store.dart";

/// Manages the per-device Bearer pairing credential stored in [SecureKeyStore].
class PairingTokenService {
  PairingTokenService({SecureKeyStore? keyStore})
    : _keyStore = keyStore ?? FlutterSecureKeyStore();

  static const String storageKey = "edge_pairing_token";
  static const String tokenPrefix = "des_";

  final SecureKeyStore _keyStore;

  static String generateToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final encoded = base64UrlEncode(bytes).replaceAll("=", "");
    return "$tokenPrefix$encoded";
  }

  /// Returns the persisted pairing token, generating and storing one if absent.
  Future<String> getOrCreateToken() async {
    final existing = await _keyStore.read(storageKey);
    if (existing != null && existing.trim().isNotEmpty) {
      return existing.trim();
    }
    final fresh = generateToken();
    await _keyStore.write(storageKey, fresh);
    return fresh;
  }

  Future<String> rotateToken() async {
    final fresh = generateToken();
    await _keyStore.write(storageKey, fresh);
    return fresh;
  }

  /// Constant-time comparison of [candidate] against [expected] via SHA-256
  /// digests so response timing cannot leak token length or prefix matches.
  static bool verifyToken(String candidate, String expected) {
    if (candidate.isEmpty || expected.isEmpty) {
      return false;
    }
    final candidateDigest = sha256.convert(utf8.encode(candidate)).bytes;
    final expectedDigest = sha256.convert(utf8.encode(expected)).bytes;
    if (candidateDigest.length != expectedDigest.length) {
      return false;
    }
    var diff = 0;
    for (var i = 0; i < candidateDigest.length; i++) {
      diff |= candidateDigest[i] ^ expectedDigest[i];
    }
    return diff == 0;
  }
}

/// Sliding-window per-IP rate limiter for failed authentication attempts
class AuthRateLimiter {
  AuthRateLimiter({
    this.maxFailures = 20,
    this.window = const Duration(seconds: 60),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int maxFailures;
  final Duration window;
  final DateTime Function() _clock;
  final Map<String, List<DateTime>> _failures = {};

  bool isBlocked(String clientIp) {
    final entries = _prune(clientIp);
    return entries.length >= maxFailures;
  }

  void recordFailure(String clientIp) {
    final entries = _prune(clientIp);
    entries.add(_clock());
    _failures[clientIp] = entries;
  }

  void reset(String clientIp) {
    _failures.remove(clientIp);
  }

  int retryAfterSeconds(String clientIp) {
    final entries = _prune(clientIp);
    if (entries.isEmpty) return 0;
    final oldest = entries.first;
    final expiresAt = oldest.add(window);
    final remaining = expiresAt.difference(_clock()).inSeconds;
    return remaining > 0 ? remaining : 1;
  }

  List<DateTime> _prune(String clientIp) {
    final now = _clock();
    final cutoff = now.subtract(window);
    final list = _failures[clientIp];
    if (list == null) return <DateTime>[];
    list.removeWhere((ts) => ts.isBefore(cutoff));
    if (list.isEmpty) {
      _failures.remove(clientIp);
      return <DateTime>[];
    }
    return list;
  }
}
