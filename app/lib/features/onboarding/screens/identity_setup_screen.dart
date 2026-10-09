import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/brand_logo.dart';
import '../widgets/hud_overlay.dart';
import '../widgets/photo_proof_mark.dart';

class IdentitySetupScreen extends StatefulWidget {
  const IdentitySetupScreen({super.key});

  @override
  State<IdentitySetupScreen> createState() => _IdentitySetupScreenState();
}

class _IdentitySetupScreenState extends State<IdentitySetupScreen> {
  bool _isGenerating = false;
  String? _errorMessage;

  @override
  Widget build(BuildContext context) {
    final controller = GraniteLakeScope.of(context);
    final identity = controller.identity;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: IntrinsicHeight(
                      child: ClipRect(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TopHudOverlay(
                              title: AppConstants.onboardingStepIdentity,
                            ),

                            const SizedBox(height: 18),

                            const SizedBox(height: 16),
                            Expanded(
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  // Soft brand glow behind the photos.
                                  Positioned.fill(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        gradient: RadialGradient(
                                          center: const Alignment(0, 0.35),
                                          radius: 0.85,
                                          colors: [
                                            AppColors.primary.withAlpha(46),
                                            AppColors.secondary.withAlpha(14),
                                            AppColors.background.withAlpha(0),
                                          ],
                                          stops: const [0, 0.55, 1],
                                        ),
                                      ),
                                    ),
                                  ),
                                  Column(
                                    children: [
                                      const Spacer(flex: 1),
                                      const BrandLogo(height: 68),
                                      const SizedBox(height: 14),
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Container(
                                            width: 28,
                                            height: 2,
                                            color: AppColors.secondary,
                                          ),
                                          const SizedBox(width: 12),
                                          Text(
                                            'VERIFIED PHOTO RECORDS',
                                            style: AppTextStyles.labelSmall
                                                .copyWith(
                                                  color:
                                                      AppColors.textSecondary,
                                                  letterSpacing: 2.2,
                                                ),
                                          ),
                                          const SizedBox(width: 12),
                                          Container(
                                            width: 28,
                                            height: 2,
                                            color: AppColors.secondary,
                                          ),
                                        ],
                                      ),
                                      const Spacer(flex: 1),
                                      Expanded(
                                        flex: 6,
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: PhotoProofMark(
                                            size: constraints.maxWidth * 0.66,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 24),

                            Text(
                              'Create Your Secure ID',
                              style: AppTextStyles.displayMedium.copyWith(
                                fontSize: 24,
                                fontWeight: FontWeight.w800,
                                height: 1.15,
                              ),
                            ),

                            const SizedBox(height: 10),

                            Text(
                              identity == null
                                  ? 'A secure ID is created on this device to verify your work. Next, you\'ll protect it with your phone biometrics.'
                                  : 'Your secure ID is ready on this device. Continue to the next step to protect it with biometrics.',
                              style: AppTextStyles.bodyMedium.copyWith(
                                color: AppColors.textSecondary,
                                height: 1.6,
                              ),
                            ),

                            const SizedBox(height: 22),

                            const Row(
                              children: [
                                Expanded(
                                  child: _InfoTile(
                                    icon: Icons.smartphone_rounded,
                                    label: 'STORED ON',
                                    value: 'THIS DEVICE',
                                  ),
                                ),
                                SizedBox(width: 10),
                                Expanded(
                                  child: _InfoTile(
                                    icon: Icons.fingerprint_rounded,
                                    label: 'LOCKED WITH',
                                    value: 'BIOMETRICS',
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 24),

                            ElevatedButton.icon(
                              onPressed: _isGenerating
                                  ? null
                                  : () async {
                                      if (identity != null) {
                                        context.go(AppRoutes.biometricSetup);
                                        return;
                                      }

                                      setState(() {
                                        _isGenerating = true;
                                        _errorMessage = null;
                                      });

                                      final result = await controller
                                          .createIdentity();
                                      if (!context.mounted) {
                                        return;
                                      }

                                      if (!result.isSuccess) {
                                        setState(() {
                                          _isGenerating = false;
                                          _errorMessage = result.message;
                                        });
                                        return;
                                      }

                                      setState(() => _isGenerating = false);
                                      context.go(AppRoutes.biometricSetup);
                                    },
                              icon: const Icon(Icons.link_rounded, size: 18),
                              label: Text(
                                _isGenerating
                                    ? 'SETTING UP SECURE ID'
                                    : identity == null
                                    ? 'CREATE SECURE ID'
                                    : 'CONTINUE',
                                style: AppTextStyles.buttonText,
                              ),
                              style: ElevatedButton.styleFrom(
                                iconColor: Colors.white,
                                foregroundColor: Colors.white,
                              ),
                            ),

                            if (_errorMessage != null) ...[
                              const SizedBox(height: 12),
                              Text(
                                _errorMessage!,
                                style: AppTextStyles.bodySmall.copyWith(
                                  color: AppColors.statusError,
                                ),
                              ),
                            ],

                            const SizedBox(height: 12),

                            Center(
                              child: Text(
                                identity == null
                                    ? 'Your secure ID stays on this device.'
                                    : 'Your secure ID is ready to protect.',
                                style: AppTextStyles.labelSmall.copyWith(
                                  color: AppColors.textMuted,
                                  letterSpacing: 0.8,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(24),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: AppColors.primary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: AppTextStyles.labelSmall.copyWith(
                    color: AppColors.textMuted,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: AppTextStyles.labelMedium.copyWith(
                    color: AppColors.textPrimary,
                    letterSpacing: 0.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
