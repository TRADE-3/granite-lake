import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../app.dart';
import '../../../core/router/app_router.dart';
import '../../../core/state/granite_lake_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';

/// EP-01 account pairing: consumes a code delivered by the granite.trade3.io
/// deep link (auto-pairing on open) or entered manually. Reached from the
/// deep-link redirect chain, the Projects tab, or the Profile screen.
class Trade3PairingScreen extends StatefulWidget {
  const Trade3PairingScreen({super.key, this.routeCode});

  final String? routeCode;

  @override
  State<Trade3PairingScreen> createState() => _Trade3PairingScreenState();
}

enum _PairingStatus { manual, working, success }

class _Trade3PairingScreenState extends State<Trade3PairingScreen> {
  final TextEditingController _codeController = TextEditingController();
  _PairingStatus _status = _PairingStatus.manual;
  String? _errorMessage;
  bool _wasPairedBeforeAttempt = false;

  @override
  void initState() {
    super.initState();
    // Inherited-widget lookups must not happen synchronously in initState.
    unawaited(Future.microtask(_takeIncomingCode));
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _takeIncomingCode() async {
    if (!mounted) {
      return;
    }
    final controller = GraniteLakeScope.of(context);
    // The pending code was stored by the deep-link listener so the router
    // could hold it through onboarding; consuming it here clears the
    // pending state so nothing routes back to this screen.
    final pendingCode = controller.consumePendingTrade3PairingCode();
    final routeCode = widget.routeCode?.trim() ?? '';
    final code = routeCode.isNotEmpty ? routeCode : (pendingCode ?? '');
    if (code.isEmpty) {
      return;
    }
    await _submit(code, controller);
  }

  Future<void> _submit(String code, GraniteLakeController controller) async {
    if (_status == _PairingStatus.working) {
      return;
    }
    setState(() {
      _status = _PairingStatus.working;
      _errorMessage = null;
      _wasPairedBeforeAttempt = controller.isTrade3Paired;
    });

    final result = await controller.pairWithTrade3(code: code);
    if (!mounted) {
      return;
    }

    if (result.isSuccess) {
      setState(() => _status = _PairingStatus.success);
      return;
    }
    setState(() {
      _status = _PairingStatus.manual;
      _errorMessage = result.message;
      _codeController.text = code;
    });
  }

  Future<void> _pasteCode() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty || !mounted) {
      return;
    }
    setState(() {
      _codeController.text = text;
      _errorMessage = null;
    });
  }

  void _continueToApp() {
    GoRouter.of(context).go(AppRoutes.dashboard);
  }

  @override
  Widget build(BuildContext context) {
    final controller = GraniteLakeScope.of(context);
    final isPaired = controller.isTrade3Paired;
    final busy =
        _status == _PairingStatus.working || controller.isTrade3Pairing;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: busy ? null : _continueToApp,
                    icon: const Icon(Icons.close_rounded),
                    color: AppColors.textSecondary,
                    tooltip: 'Close',
                  ),
                ],
              ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: switch (_status) {
                      _PairingStatus.success => _buildSuccessCard(
                        isPaired: true,
                      ),
                      _PairingStatus.working => _buildWorkingCard(),
                      _PairingStatus.manual => _buildEntryCard(
                        controller,
                        isPaired: isPaired,
                      ),
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEntryCard(
    GraniteLakeController controller, {
    required bool isPaired,
  }) {
    final busy = _status == _PairingStatus.working;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: AppColors.statusEncrypt.withAlpha(24),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(
            Icons.link_rounded,
            color: AppColors.statusEncrypt,
            size: 26,
          ),
        ),
        const SizedBox(height: 18),
        Text(
          'Link your Trade3 account',
          style: AppTextStyles.displayMedium.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          isPaired
              ? 'Your account is already linked. Enter a new pairing code to switch accounts.'
              : 'Link this device to pick a contract, transaction and payment schedule for every capture.',
          style: AppTextStyles.bodyMedium.copyWith(
            color: AppColors.textSecondary,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 18),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _HowToStep(
                number: '1',
                text: 'Open Trade3 and go to Link Mobile App.',
              ),
              const SizedBox(height: 10),
              const _HowToStep(
                number: '2',
                text: 'Scan the QR code, or paste the pairing code below.',
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _codeController,
          enabled: !busy,
          autofocus: false,
          decoration: _inputDecoration(
            label: 'Pairing code',
            hint: 'Paste your pairing code',
            suffixIcon: IconButton(
              onPressed: busy ? null : _pasteCode,
              icon: const Icon(Icons.content_paste_rounded, size: 20),
              color: AppColors.textSecondary,
              tooltip: 'Paste',
            ),
          ),
          style: AppTextStyles.bodyMedium.copyWith(
            color: AppColors.textPrimary,
          ),
          onSubmitted: (value) {
            final code = value.trim();
            if (code.isNotEmpty) {
              unawaited(_submit(code, controller));
            }
          },
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 12),
          Text(
            _errorMessage!,
            style: AppTextStyles.bodySmall.copyWith(
              color: AppColors.statusError,
              height: 1.4,
            ),
          ),
        ],
        const SizedBox(height: 22),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: busy
                ? null
                : () {
                    final code = _codeController.text.trim();
                    if (code.isNotEmpty) {
                      unawaited(_submit(code, controller));
                    }
                  },
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            icon: const Icon(Icons.link_rounded),
            label: Text(
              busy ? 'LINKING ACCOUNT' : 'LINK ACCOUNT',
              style: AppTextStyles.buttonText,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWorkingCard() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 44,
          height: 44,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
        const SizedBox(height: 20),
        Text(
          'Linking your account…',
          style: AppTextStyles.headlineMedium.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Verifying your pairing code.',
          style: AppTextStyles.bodyMedium.copyWith(
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _buildSuccessCard({required bool isPaired}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.statusActive.withAlpha(24),
            border: Border.all(color: AppColors.statusActive.withAlpha(90)),
          ),
          child: Icon(Icons.link_rounded, color: AppColors.statusActive),
        ),
        const SizedBox(height: 20),
        Text(
          'Account linked',
          style: AppTextStyles.headlineMedium.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          _wasPairedBeforeAttempt
              ? 'Your Trade3 account has been updated on this device.'
              : 'This device is now linked to your Trade3 account. Your projects will appear in the Projects tab.',
          textAlign: TextAlign.center,
          style: AppTextStyles.bodyMedium.copyWith(
            color: AppColors.textSecondary,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 26),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _continueToApp,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            icon: const Icon(Icons.arrow_forward_rounded),
            label: Text('CONTINUE', style: AppTextStyles.buttonText),
          ),
        ),
      ],
    );
  }
}

class _HowToStep extends StatelessWidget {
  const _HowToStep({required this.number, required this.text});

  final String number;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.statusEncrypt.withAlpha(24),
          ),
          child: Text(
            number,
            style: AppTextStyles.labelSmall.copyWith(
              color: AppColors.statusEncrypt,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: AppTextStyles.bodySmall.copyWith(
              color: AppColors.textSecondary,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

InputDecoration _inputDecoration({
  required String label,
  required String hint,
  Widget? suffixIcon,
}) {
  return InputDecoration(
    labelText: label,
    hintText: hint,
    suffixIcon: suffixIcon,
    hintStyle: AppTextStyles.bodyMedium.copyWith(color: AppColors.textMuted),
    labelStyle: AppTextStyles.bodyMedium.copyWith(
      color: AppColors.textSecondary,
    ),
    filled: true,
    fillColor: AppColors.surface,
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: AppColors.borderActive),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: AppColors.primary),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: AppColors.statusError),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: AppColors.statusError),
    ),
  );
}
