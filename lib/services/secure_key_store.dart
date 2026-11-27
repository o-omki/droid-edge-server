import "package:flutter/services.dart";
import "package:flutter_secure_storage/flutter_secure_storage.dart";

/// Minimal key-value abstraction for persisting sensitive credentials
abstract class SecureKeyStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSecureKeyStore implements SecureKeyStore {
  FlutterSecureKeyStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } on MissingPluginException {
      // Allow graceful fallback in headless or test environments without
      // platform channels.
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } on MissingPluginException {
      // No-op when platform channels are unavailable.
    }
  }
}

/// Volatile in-memory [SecureKeyStore] for unit and widget tests.
class InMemorySecureKeyStore implements SecureKeyStore {
  InMemorySecureKeyStore([Map<String, String>? initialValues])
    : _values = Map<String, String>.from(initialValues ?? const {});

  final Map<String, String> _values;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}
