import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../app.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/granite_lake_secure_state_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';

/// Shows the recovery key behind a fresh biometric check, once per visit.
/// Used at the end of ID creation and from Profile. Screenshots are blocked
/// app-wide (MainActivity sets FLAG_SECURE); the key reaches the clipboard
/// only when the user taps copy.
class RecoveryKeyScreen extends StatefulWidget {
  const RecoveryKeyScreen({super.key});

  /// Groups of four so it can be copied by hand; import ignores the spaces.
  static String grouped(String key) =>
      RegExp('.{1,4}').allMatches(key).map((match) => match.group(0)).join(' ');

  @override
  State<RecoveryKeyScreen> createState() => _RecoveryKeyScreenState();
}

class _RecoveryKeyScreenState extends State<RecoveryKeyScreen>
    with WidgetsBindingObserver {
  String? _recoveryKey;
  String? _errorMessage;
  bool _isRevealing = false;
  bool _hasSaved = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recoveryKey = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Not left on screen for whoever picks the phone up next.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      setState(() => _recoveryKey = null);
    }
  }

  Future<void> _reveal() async {
    setState(() {
      _isRevealing = true;
      _errorMessage = null;
    });
    final result = await GraniteLakeScope.of(context).revealRecoveryKey();
    if (!mounted) {
      return;
    }
    setState(() {
      _isRevealing = false;
      _recoveryKey = result.data;
      _errorMessage = result.isSuccess ? null : result.message;
    });
  }

  Future<void> _copy(String recoveryKey) async {
    await Clipboard.setData(ClipboardData(text: recoveryKey));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text(
            'Copied. Paste it somewhere safe, then clear your clipboard.',
          ),
        ),
      );
  }

  Future<void> _done() async {
    final controller = GraniteLakeScope.of(context);
    final router = GoRouter.of(context);
    final isOnboarding = !controller.hasCompletedRegistration;
    await controller.confirmRecoveryKeySaved();
    if (isOnboarding) {
      router.go(AppRoutes.pair);
    } else {
      _close(router);
    }
  }

  void _close(GoRouter router) {
    if (router.canPop()) {
      router.pop();
    } else {
      router.go(AppRoutes.dashboard);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOnboarding = !GraniteLakeScope.of(context).hasCompletedRegistration;
    final recoveryKey = _recoveryKey;
    final bodyStyle = AppTextStyles.bodyMedium.copyWith(
      color: AppColors.textSecondary,
      height: 1.6,
    );

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
          children: [
            if (!isOnboarding)
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  onPressed: () => _close(GoRouter.of(context)),
                  icon: const Icon(Icons.close_rounded),
                  color: AppColors.textSecondary,
                  tooltip: 'Close',
                ),
              ),
            Text('Your recovery key', style: AppTextStyles.displayMedium),
            const SizedBox(height: 12),
            Text(
              'This key restores your secure ID on a new or reinstalled app. '
              'Write it down and keep it somewhere safe. Anyone who has it can '
              'act as you, so never share or send it. Your history and files '
              'are not restored with it.',
              style: bodyStyle,
            ),
            const SizedBox(height: 22),
            if (recoveryKey == null)
              ElevatedButton(
                onPressed: _isRevealing ? null : _reveal,
                child: Text(
                  _isRevealing ? 'CONFIRMING' : 'SHOW RECOVERY KEY',
                  style: AppTextStyles.buttonText,
                ),
              )
            else ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.borderActive),
                ),
                child: Text(
                  RecoveryKeyScreen.grouped(recoveryKey),
                  style: AppTextStyles.headlineMedium.copyWith(height: 1.8),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _copy(recoveryKey),
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: Text(
                  'COPY',
                  style: AppTextStyles.buttonText.copyWith(
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                value: _hasSaved,
                onChanged: (value) =>
                    setState(() => _hasSaved = value ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: Text('I have saved my recovery key', style: bodyStyle),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: _hasSaved ? _done : null,
                child: Text(
                  isOnboarding ? 'CONTINUE' : 'DONE',
                  style: AppTextStyles.buttonText,
                ),
              ),
            ],
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                style: AppTextStyles.bodySmall.copyWith(
                  color: AppColors.statusError,
                ),
              ),
            ],
            // The key can no longer be unlocked, so this unregistered ID is
            // unusable. Without a way out, setup would be stuck here.
            if (isOnboarding &&
                _errorMessage ==
                    GraniteLakeSecureStateService.biometricChangedMessage) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () =>
                    GraniteLakeScope.of(context).discardUnregisteredIdentity(),
                child: Text(
                  'START AGAIN',
                  style: AppTextStyles.buttonText.copyWith(
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
