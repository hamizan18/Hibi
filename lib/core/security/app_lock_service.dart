import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import '../database/app_database.dart';
import '../services/app_clock.dart';
import 'privacy_deletion_service.dart';

/// Abstraction over secure device storage (Android Keystore via
/// FlutterSecureStorage in production; in-memory fake in unit/widget tests).
/// Never exported in backups and never logged.
abstract class SecureKeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSecureStorageAdapter implements SecureKeyValueStore {
  const FlutterSecureStorageAdapter([
    this._storage = const FlutterSecureStorage(),
  ]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class InMemorySecureKeyValueStore implements SecureKeyValueStore {
  final Map<String, String> _map = <String, String>{};

  @override
  Future<String?> read(String key) async => _map[key];

  @override
  Future<void> write(String key, String value) async {
    _map[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _map.remove(key);
  }
}

/// Abstraction over platform biometrics (Android BiometricPrompt via local_auth).
/// Never stores biometric credentials.
abstract class BiometricGateway {
  Future<bool> isBiometricAvailable();
  Future<bool> authenticate({required String localizedReason});
}

class LocalAuthBiometricGateway implements BiometricGateway {
  LocalAuthBiometricGateway([LocalAuthentication? auth])
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> isBiometricAvailable() async {
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    try {
      final supported = await _auth.isDeviceSupported();
      final canCheck = await _auth.canCheckBiometrics;
      if (!supported || !canCheck) return false;
      final available = await _auth.getAvailableBiometrics();
      return available.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate({required String localizedReason}) async {
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    try {
      return await _auth.authenticate(
        localizedReason: localizedReason,
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }
}

/// Controls Android FLAG_SECURE for recent-app preview protection.
abstract class PrivacyWindowGateway {
  Future<void> setSecureFlag(bool enabled);
}

class AndroidPrivacyWindowGateway implements PrivacyWindowGateway {
  static const _channel = MethodChannel('com.example.hibi/privacy_window');

  @override
  Future<void> setSecureFlag(bool enabled) async {
    try {
      await _channel.invokeMethod<bool>('setSecureFlag', {'enabled': enabled});
    } catch (_) {
      // Unsupported platform or host test environment; ignore safely.
    }
  }
}

/// Vetted PBKDF2-HMAC-SHA256 salted PIN verifier (100,000 iterations, 256-bit
/// derived key, 128-bit random salt, constant-time comparison).
class PinVerifier {
  const PinVerifier._();

  static const int iterations = 100000;
  static const int hashBits = 256;
  static const int saltBytesLength = 16;

  static void validatePinFormat(String pin) {
    final trimmed = pin.trim();
    if (trimmed != pin) {
      throw ArgumentError('PIN must not contain leading or trailing spaces');
    }
    if (!RegExp(r'^\d{4,12}$').hasMatch(pin)) {
      throw ArgumentError('PIN must be 4 to 12 numeric digits');
    }
  }

  static Future<String> createEncodedVerifier(
    String pin, {
    Random? random,
  }) async {
    validatePinFormat(pin);
    final rng = random ?? Random.secure();
    final salt = List<int>.generate(saltBytesLength, (_) => rng.nextInt(256));
    final hash = await _derive(pin, salt, iterations);
    return jsonEncode({
      'alg': 'pbkdf2_hmac_sha256',
      'iter': iterations,
      'salt': base64Encode(salt),
      'hash': base64Encode(hash),
    });
  }

  static Future<bool> verify(
    String candidatePin,
    String encodedVerifier,
  ) async {
    if (candidatePin.isEmpty) return false;
    try {
      final map = jsonDecode(encodedVerifier) as Map<String, dynamic>;
      if (map['alg'] != 'pbkdf2_hmac_sha256') return false;
      final iter = map['iter'] as int;
      final salt = base64Decode(map['salt'] as String);
      final expected = base64Decode(map['hash'] as String);
      final actual = await _derive(candidatePin, salt, iter);
      return _constantTimeEquals(actual, expected);
    } catch (_) {
      return false;
    }
  }

  static Future<List<int>> _derive(String pin, List<int> salt, int iter) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iter,
      bits: hashBits,
    );
    final secretKey = await pbkdf2.deriveKeyFromPassword(
      password: pin,
      nonce: salt,
    );
    return secretKey.extractBytes();
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

class AppLockConfig {
  const AppLockConfig({
    required this.isPinEnabled,
    required this.isBiometricEnabled,
    required this.lockOnResume,
    required this.protectRecentAppPreview,
    required this.failedAttempts,
    required this.lockedUntilUtc,
  });

  final bool isPinEnabled;
  final bool isBiometricEnabled;
  final bool lockOnResume;
  final bool protectRecentAppPreview;
  final int failedAttempts;
  final DateTime? lockedUntilUtc;

  bool isRateLimitedAt(DateTime nowUtc) =>
      lockedUntilUtc != null && nowUtc.toUtc().isBefore(lockedUntilUtc!);
}

class PinUnlockResult {
  const PinUnlockResult({
    required this.unlocked,
    required this.message,
    this.retryAfterSeconds = 0,
  });

  final bool unlocked;
  final String message;
  final int retryAfterSeconds;
}

/// Manages local App Lock (salted PBKDF2-SHA256 PIN verifier in Android
/// Keystore via SecureKeyValueStore, optional platform biometrics, resume
/// locking, FLAG_SECURE recent-app protection, and wipe-based forgotten-PIN
/// recovery).
///
/// Important limitation (per SECURITY_PRIVACY.md): App Lock protects ordinary
/// unlocked-device UI access; it is NOT SQLite database encryption at rest.
class AppLockService {
  const AppLockService({
    required this.secureStore,
    required this.biometricGateway,
    required this.privacyWindowGateway,
    required this.clock,
  });

  static const _pinVerifierKey = 'hibi_pin_verifier_v1';
  static const _biometricEnabledKey = 'hibi_biometric_enabled_v1';
  static const _lockOnResumeKey = 'hibi_lock_on_resume_v1';
  static const _securePreviewKey = 'hibi_protect_recent_preview_v1';
  static const _failedAttemptsKey = 'hibi_pin_failed_attempts_v1';
  static const _lockedUntilKey = 'hibi_pin_locked_until_utc_us_v1';

  /// Required confirmation phrase for forgotten-PIN recovery.
  static const String forgottenPinResetPhrase = 'ERASE ALL LOCAL DATA';

  final SecureKeyValueStore secureStore;
  final BiometricGateway biometricGateway;
  final PrivacyWindowGateway privacyWindowGateway;
  final AppClock clock;

  Future<AppLockConfig> readConfig() async {
    final verifier = await secureStore.read(_pinVerifierKey);
    final bioRaw = await secureStore.read(_biometricEnabledKey);
    final resumeRaw = await secureStore.read(_lockOnResumeKey);
    final secureRaw = await secureStore.read(_securePreviewKey);
    final failsRaw = await secureStore.read(_failedAttemptsKey);
    final untilRaw = await secureStore.read(_lockedUntilKey);

    final untilUs = untilRaw == null ? null : int.tryParse(untilRaw);
    return AppLockConfig(
      isPinEnabled: verifier != null && verifier.isNotEmpty,
      isBiometricEnabled: bioRaw == 'true' && verifier != null,
      lockOnResume: resumeRaw != 'false',
      protectRecentAppPreview: secureRaw == 'true',
      failedAttempts: int.tryParse(failsRaw ?? '') ?? 0,
      lockedUntilUtc: untilUs == null
          ? null
          : DateTime.fromMicrosecondsSinceEpoch(untilUs, isUtc: true),
    );
  }

  Future<void> applyWindowProtection() async {
    final config = await readConfig();
    await privacyWindowGateway.setSecureFlag(
      config.protectRecentAppPreview || config.isPinEnabled,
    );
  }

  Future<void> configurePin(String pin) async {
    final encoded = await PinVerifier.createEncodedVerifier(pin);
    await secureStore.write(_pinVerifierKey, encoded);
    await secureStore.delete(_failedAttemptsKey);
    await secureStore.delete(_lockedUntilKey);
    await secureStore.write(_lockOnResumeKey, 'true');
    await applyWindowProtection();
  }

  Future<void> disablePin(String currentPin) async {
    final check = await verifyPin(currentPin);
    if (!check.unlocked) {
      throw StateError(check.message);
    }
    await secureStore.delete(_pinVerifierKey);
    await secureStore.delete(_biometricEnabledKey);
    await secureStore.delete(_failedAttemptsKey);
    await secureStore.delete(_lockedUntilKey);
    await applyWindowProtection();
  }

  Future<PinUnlockResult> verifyPin(String candidatePin) async {
    final config = await readConfig();
    if (!config.isPinEnabled) {
      return const PinUnlockResult(unlocked: true, message: 'App lock is off');
    }
    final nowUtc = clock.now().toUtc();
    if (config.isRateLimitedAt(nowUtc)) {
      final waitSeconds =
          config.lockedUntilUtc!.difference(nowUtc).inSeconds + 1;
      return PinUnlockResult(
        unlocked: false,
        message: 'Too many incorrect attempts. Try again in ${waitSeconds}s.',
        retryAfterSeconds: waitSeconds,
      );
    }

    final verifier = await secureStore.read(_pinVerifierKey);
    if (verifier == null) {
      return const PinUnlockResult(unlocked: true, message: 'App lock is off');
    }
    final matched = await PinVerifier.verify(candidatePin, verifier);
    if (matched) {
      await secureStore.delete(_failedAttemptsKey);
      await secureStore.delete(_lockedUntilKey);
      return const PinUnlockResult(unlocked: true, message: 'Unlocked');
    }

    final attempts = config.failedAttempts + 1;
    await secureStore.write(_failedAttemptsKey, '$attempts');
    if (attempts >= 5) {
      final backoffSeconds = 30 * (1 << ((attempts - 5).clamp(0, 4)));
      final until = nowUtc.add(Duration(seconds: backoffSeconds));
      await secureStore.write(
        _lockedUntilKey,
        '${until.microsecondsSinceEpoch}',
      );
      return PinUnlockResult(
        unlocked: false,
        message:
            'Incorrect PIN. Locked for ${backoffSeconds}s after $attempts failed attempts.',
        retryAfterSeconds: backoffSeconds,
      );
    }
    return PinUnlockResult(
      unlocked: false,
      message: 'Incorrect PIN ($attempts/5 attempts before cooldown).',
    );
  }

  Future<bool> isBiometricAvailable() =>
      biometricGateway.isBiometricAvailable();

  Future<void> setBiometricEnabled(bool enabled) async {
    final config = await readConfig();
    if (enabled && !config.isPinEnabled) {
      throw StateError('Configure a local PIN before enabling biometrics');
    }
    if (enabled && !await biometricGateway.isBiometricAvailable()) {
      throw StateError('Device biometrics are not available or not enrolled');
    }
    await secureStore.write(_biometricEnabledKey, enabled ? 'true' : 'false');
  }

  Future<bool> unlockWithBiometrics() async {
    final config = await readConfig();
    if (!config.isPinEnabled || !config.isBiometricEnabled) {
      return false;
    }
    final ok = await biometricGateway.authenticate(
      localizedReason: 'Unlock Hibi local workspace',
    );
    if (ok) {
      await secureStore.delete(_failedAttemptsKey);
      await secureStore.delete(_lockedUntilKey);
    }
    return ok;
  }

  Future<void> setLockOnResume(bool enabled) async {
    await secureStore.write(_lockOnResumeKey, enabled ? 'true' : 'false');
  }

  Future<void> setProtectRecentAppPreview(bool enabled) async {
    await secureStore.write(_securePreviewKey, enabled ? 'true' : 'false');
    await applyWindowProtection();
  }

  /// Honest forgotten-PIN recovery: without a cloud account or backdoor,
  /// resetting a forgotten PIN requires wiping all protected local data first.
  /// The user may then restore from their own encrypted backup if available.
  Future<void> resetForgottenPinWithLocalWipe({
    required AppDatabase db,
    required String confirmationPhrase,
  }) async {
    if (confirmationPhrase.trim() != forgottenPinResetPhrase) {
      throw ArgumentError(
        'Type "$forgottenPinResetPhrase" exactly to confirm local wipe',
      );
    }
    await PrivacyDeletionService(
      db,
      clock,
    ).permanentlyWipeAllLocalData(confirmationPhrase: forgottenPinResetPhrase);
    await secureStore.delete(_pinVerifierKey);
    await secureStore.delete(_biometricEnabledKey);
    await secureStore.delete(_failedAttemptsKey);
    await secureStore.delete(_lockedUntilKey);
    await applyWindowProtection();
  }
}
