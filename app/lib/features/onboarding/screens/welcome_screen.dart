import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/brand_logo.dart';
import '../../../core/widgets/theme_toggle_button.dart';
import '../widgets/hud_overlay.dart';
import '../widgets/photo_proof_mark.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final controller = GraniteLakeScope.of(context);
    final resetNotice = controller.resetNotice;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        actions: [
          ThemeToggleButton(controller: controller),
          const SizedBox(width: 8),
        ],
      ),
      body: Stack(
        children: [
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: EdgeInsets.fromLTRB(
                    24,
                    20,
                    24,
                    20 + viewInsets.bottom,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: IntrinsicHeight(
                      child: ClipRect(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // ── Top HUD ──────────────────────────────────────────────────
                            TopHudOverlay(
                              title: AppConstants.onboardingHeaderLabel,
                            ),

                            const SizedBox(height: 20),

                            // ── Hero: light logo + shield on brand gradient ──────────────
                            const Spacer(),
                            const Center(child: PhotoProofMark(size: 200)),
                            const SizedBox(height: 28),
                            const Center(child: BrandLogo(height: 76)),
                            const SizedBox(height: 14),
                            Center(
                              child: Text(
                                'Verified photo records\nfor field operations.',
                                textAlign: TextAlign.center,
                                style: AppTextStyles.bodyLarge.copyWith(
                                  color: AppColors.textSecondary,
                                  height: 1.6,
                                ),
                              ),
                            ),
                            const SizedBox(height: 32),
                            const FeatureRow(
                              icon: Icons.photo_camera_outlined,
                              text: 'Capture photos on site',
                            ),
                            const SizedBox(height: 14),
                            const FeatureRow(
                              icon: Icons.verified_outlined,
                              text: 'Each photo is verified on your device',
                            ),
                            const SizedBox(height: 14),
                            const FeatureRow(
                              icon: Icons.history_rounded,
                              text: 'Keep a trusted record of your work',
                            ),
                            const Spacer(),
                            const SizedBox(height: 28),

                            if (resetNotice != null) ...[
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: AppColors.surface.withAlpha(90),
                                  border: Border.all(
                                    color: AppColors.statusError.withAlpha(180),
                                  ),
                                ),
                                child: Text(
                                  resetNotice,
                                  style: AppTextStyles.bodySmall.copyWith(
                                    color: AppColors.statusError,
                                    height: 1.5,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 20),
                            ],

                            // ── CTA button ───────────────────────────────────────────────
                            ElevatedButton(
                              onPressed: () async {
                                await controller.dismissResetNotice();
                                if (!context.mounted) {
                                  return;
                                }
                                context.go(AppRoutes.identitySetup);
                              },
                              child: Text(
                                'GET STARTED',
                                style: AppTextStyles.buttonText,
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
