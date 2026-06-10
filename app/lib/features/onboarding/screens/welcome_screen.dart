import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../widgets/hud_overlay.dart';
import '../widgets/scan_line_overlay.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final controller = GraniteLakeScope.of(context);
    final resetNotice = controller.resetNotice;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          const Positioned.fill(child: ScanLineOverlay()),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: EdgeInsets.fromLTRB(24, 20, 24, 20 + viewInsets.bottom),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: constraints.maxHeight),
                    child: IntrinsicHeight(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // ── Top HUD ──────────────────────────────────────────────────
                          TopHudOverlay(
                            flowId: AppConstants.welcomeFlowId,
                            status: AppConstants.welcomeStatus,
                            encryptAlgo: AppConstants.welcomeEncryptMode,
                            trailing: const ShieldBadge(size: 64),
                          ),

                          const SizedBox(height: 28),

                          // ── Text block — centered ────────────────────────────────────
                          Center(
                            child: Column(
                              children: [
                                Text(
                                  AppConstants.welcomeDisplayId,
                                  style: AppTextStyles.labelMedium.copyWith(
                                    color: AppColors.textMuted,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    AppConstants.appName,
                                    maxLines: 1,
                                    style: AppTextStyles.displayLarge.copyWith(
                                      fontSize: 48,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 1.5,
                                      height: 1.1,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  'Forensic-grade photo authenticity\nfor field operations.',
                                  textAlign: TextAlign.center,
                                  style: AppTextStyles.bodyMedium.copyWith(
                                    color: AppColors.textSecondary,
                                    height: 1.6,
                                  ),
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 36),

                          if (resetNotice != null) ...[
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: AppColors.surface.withAlpha(90),
                                border: Border.all(color: AppColors.statusError.withAlpha(180)),
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
                              'CREATE SUI IDENTITY',
                              style: AppTextStyles.buttonText,
                            ),
                          ),
                        ],
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
