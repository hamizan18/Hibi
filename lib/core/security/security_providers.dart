import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/app_database.dart';
import '../services/app_clock.dart';
import 'app_lock_service.dart';
import 'privacy_deletion_service.dart';

final secureKeyValueStoreProvider = Provider<SecureKeyValueStore>(
  (ref) => const FlutterSecureStorageAdapter(),
);

final biometricGatewayProvider = Provider<BiometricGateway>(
  (ref) => LocalAuthBiometricGateway(),
);

final privacyWindowGatewayProvider = Provider<PrivacyWindowGateway>(
  (ref) => AndroidPrivacyWindowGateway(),
);

final appLockServiceProvider = Provider<AppLockService>(
  (ref) => AppLockService(
    secureStore: ref.watch(secureKeyValueStoreProvider),
    biometricGateway: ref.watch(biometricGatewayProvider),
    privacyWindowGateway: ref.watch(privacyWindowGatewayProvider),
    clock: ref.watch(appClockProvider),
  ),
);

final privacyDeletionServiceProvider = Provider<PrivacyDeletionService>(
  (ref) => PrivacyDeletionService(
    ref.watch(databaseProvider),
    ref.watch(appClockProvider),
  ),
);
