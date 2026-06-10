import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../app.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _isStartingSession = false;
  bool _isEndingSession = false;
  String? _errorMessage;

  Future<bool?> _showBiometricResetDialog(String message) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surfaceElevated,
          title: Text(
            'Biometrics Changed',
            style: AppTextStyles.labelLarge.copyWith(
              color: AppColors.textPrimary,
            ),
          ),
          content: Text(
            '$message\n\nReset ${AppConstants.appTitle} and restart onboarding on this device?',
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textSecondary,
              height: 1.5,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(
                'NO',
                style: AppTextStyles.buttonText.copyWith(
                  color: AppColors.textMuted,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(
                'YES',
                style: AppTextStyles.buttonText.copyWith(
                  color: AppColors.statusError,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = GraniteLakeScope.of(context);
    final identity = controller.identity;
    final binding = controller.biometricBinding;
    final activeSession = controller.hasActiveSession;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'SECURE CAPTURE CONSOLE',
                style: AppTextStyles.labelMedium.copyWith(
                  color: AppColors.textMuted,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                AppConstants.appTitle,
                style: AppTextStyles.displayMedium.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 24),
              _MetricCard(
                title: 'IDENTITY',
                primaryValue: identity?.walletTag ?? 'NOT_PROVISIONED',
                secondaryValue: identity == null
                    ? 'Sui wallet not provisioned'
                    : binding == null
                    ? 'Sui wallet ready • biometric binding pending'
                    : 'Sui wallet bound • ${binding.modalitiesLabel}',
                isActive: identity != null && binding != null,
                trailing: identity == null
                    ? null
                    : IconButton(
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(text: identity.walletAddress),
                          );
                          ScaffoldMessenger.of(context)
                            ..hideCurrentSnackBar()
                            ..showSnackBar(
                              const SnackBar(
                                content: Text('Sui wallet address copied'),
                              ),
                            );
                        },
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        color: AppColors.textPrimary,
                        tooltip: 'Copy Sui wallet address',
                        visualDensity: VisualDensity.compact,
                      ),
              ),
              const SizedBox(height: 16),
              _MetricCard(
                title: 'SESSION',
                primaryValue: activeSession
                    ? 'ACTIVE ${_formatDuration(controller.remainingSessionDuration)}'
                    : 'LOCKED',
                secondaryValue: activeSession
                    ? 'Expires ${controller.session!.expiresAt.toLocal().toString().substring(11, 19)}'
                    : 'Biometric unlock required',
                isActive: activeSession,
              ),
              const SizedBox(height: 16),
              if (controller.lastCapture != null)
                _MetricCard(
                  title: 'LAST CAPTURE',
                  primaryValue: controller.lastCapture!.shortHash,
                  secondaryValue: controller.lastCapture!.capturedAt
                      .toLocal()
                      .toString(),
                  isActive: true,
                ),
              if (controller.lastCapture != null) const SizedBox(height: 16),
              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _errorMessage!,
                    style: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.statusError,
                    ),
                  ),
                ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isStartingSession || _isEndingSession
                      ? null
                      : () async {
                          if (activeSession) {
                            context.go(AppRoutes.capture);
                            return;
                          }

                          setState(() {
                            _isStartingSession = true;
                            _errorMessage = null;
                          });

                          final result = await controller.startSession();
                          if (!context.mounted) {
                            return;
                          }

                          if (result.code == 'biometric_reset_required') {
                            setState(() => _isStartingSession = false);
                            final shouldReset = await _showBiometricResetDialog(
                              result.message ??
                                  'Biometrics changed on this device. Re-bind required.',
                            );
                            if (!context.mounted) {
                              return;
                            }
                            if (shouldReset == true) {
                              await controller.resetForBiometricInvalidation();
                              if (!context.mounted) {
                                return;
                              }
                              context.go(AppRoutes.welcome);
                            }
                            return;
                          }

                          if (!result.isSuccess) {
                            setState(() {
                              _isStartingSession = false;
                              _errorMessage = result.message;
                            });
                            return;
                          }

                          setState(() => _isStartingSession = false);
                          context.go(AppRoutes.capture);
                        },
                  icon: Icon(
                    activeSession
                        ? Icons.camera_alt_rounded
                        : Icons.lock_open_rounded,
                  ),
                  label: Text(
                    _isStartingSession
                        ? 'STARTING SESSION'
                        : activeSession
                        ? 'OPEN CAMERA'
                        : 'START SECURE SESSION',
                    style: AppTextStyles.buttonText,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed:
                      !activeSession || _isStartingSession || _isEndingSession
                      ? null
                      : () async {
                          setState(() {
                            _isEndingSession = true;
                            _errorMessage = null;
                          });
                          await controller.endSession();
                          if (!context.mounted) {
                            return;
                          }
                          setState(() => _isEndingSession = false);
                        },
                  child: Text(
                    _isEndingSession ? 'ENDING SESSION' : 'END SESSION',
                    style: AppTextStyles.buttonText.copyWith(
                      color: activeSession
                          ? AppColors.textPrimary
                          : AppColors.textMuted,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = duration.inHours.toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.title,
    required this.primaryValue,
    required this.secondaryValue,
    required this.isActive,
    this.trailing,
  });

  final String title;
  final String primaryValue;
  final String secondaryValue;
  final bool isActive;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface.withAlpha(90),
        border: Border.all(
          color: isActive ? AppColors.primary.withAlpha(180) : AppColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: AppTextStyles.labelSmall.copyWith(
                    color: AppColors.textMuted,
                    letterSpacing: 0.9,
                  ),
                ),
              ),
              trailing ?? const SizedBox.shrink(),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            primaryValue,
            style: AppTextStyles.labelLarge.copyWith(
              color: AppColors.textPrimary,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            secondaryValue,
            style: AppTextStyles.bodySmall.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
