import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/app_database.dart';
import 'app_lock_service.dart';
import 'security_providers.dart';

/// Enforces optional local App Lock on launch and app resume when a PIN is
/// configured. When no PIN is configured, renders [child] immediately.
class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate>
    with WidgetsBindingObserver {
  bool _checkedInitial = false;
  bool _isLocked = false;
  AppLockConfig? _config;
  final _pinController = TextEditingController();
  String? _errorText;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkLockState(isResume: false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pinController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkLockState(isResume: true);
    }
  }

  Future<void> _checkLockState({required bool isResume}) async {
    final service = ref.read(appLockServiceProvider);
    final config = await service.readConfig();
    await service.applyWindowProtection();
    if (!mounted) return;
    setState(() {
      _config = config;
      _checkedInitial = true;
      if (config.isPinEnabled && (!isResume || config.lockOnResume)) {
        _isLocked = true;
        _pinController.clear();
        _errorText = null;
      } else if (!config.isPinEnabled) {
        _isLocked = false;
      }
    });
  }

  Future<void> _submitPin() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _errorText = null;
    });
    final result = await ref
        .read(appLockServiceProvider)
        .verifyPin(_pinController.text.trim());
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.unlocked) {
        _isLocked = false;
        _pinController.clear();
      } else {
        _errorText = result.message;
      }
    });
  }

  Future<void> _tryBiometrics() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _errorText = null;
    });
    final ok = await ref.read(appLockServiceProvider).unlockWithBiometrics();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _isLocked = false;
        _pinController.clear();
      } else {
        _errorText = 'Biometric authentication did not succeed. Use your PIN.';
      }
    });
  }

  Future<void> _openForgottenPinDialog() async {
    final phrase = await showDialog<String>(
      context: context,
      builder: (_) => const _ForgottenPinResetDialog(),
    );
    if (phrase == null || !mounted) return;
    setState(() {
      _busy = true;
      _errorText = null;
    });
    try {
      await ref
          .read(appLockServiceProvider)
          .resetForgottenPinWithLocalWipe(
            db: ref.read(databaseProvider),
            confirmationPhrase: phrase,
          );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _isLocked = false;
        _pinController.clear();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errorText = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_checkedInitial) {
      return widget.child;
    }
    if (!_isLocked) {
      return widget.child;
    }
    final config = _config;
    return Stack(
      children: [
        // Keep child mounted but visually replaced and non-interactive while locked.
        Offstage(offstage: true, child: widget.child),
        Scaffold(
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Icon(Icons.lock_outline, size: 40),
                          const SizedBox(height: 12),
                          Text(
                            'Hibi is locked',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Enter your local PIN to unlock.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            key: const Key('app-lock-pin-field'),
                            controller: _pinController,
                            obscureText: true,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'PIN',
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (_) => _submitPin(),
                          ),
                          if (_errorText != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              _errorText!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ],
                          const SizedBox(height: 16),
                          FilledButton(
                            key: const Key('app-lock-unlock-button'),
                            onPressed: _busy ? null : _submitPin,
                            child: const Text('Unlock'),
                          ),
                          if (config?.isBiometricEnabled == true) ...[
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                              onPressed: _busy ? null : _tryBiometrics,
                              icon: const Icon(Icons.fingerprint),
                              label: const Text('Unlock with biometrics'),
                            ),
                          ],
                          const SizedBox(height: 12),
                          TextButton(
                            onPressed: _busy ? null : _openForgottenPinDialog,
                            child: const Text('Forgot PIN?'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ForgottenPinResetDialog extends StatefulWidget {
  const _ForgottenPinResetDialog();

  @override
  State<_ForgottenPinResetDialog> createState() =>
      _ForgottenPinResetDialogState();
}

class _ForgottenPinResetDialogState extends State<_ForgottenPinResetDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Forgotten PIN recovery'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Hibi has no cloud account or backdoor. To reset a forgotten PIN '
              'without bypassing local privacy, all local data must be erased '
              'first. You can restore from an encrypted backup afterward.',
            ),
            const SizedBox(height: 12),
            const Text(
              'Type "${AppLockService.forgottenPinResetPhrase}" to confirm:',
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Confirmation phrase',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Erase & reset PIN'),
        ),
      ],
    );
  }
}
