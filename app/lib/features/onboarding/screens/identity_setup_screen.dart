import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../widgets/hud_overlay.dart';
import '../widgets/scan_line_overlay.dart';

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
          const Positioned.fill(child: ScanLineOverlay()),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: constraints.maxHeight),
                    child: IntrinsicHeight(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TopHudOverlay(
                            flowId: AppConstants.identityFlowId,
                            status: AppConstants.identityStatus,
                            encryptAlgo: AppConstants.identityEncryptMode,
                            trailing: const ShieldBadge(size: 48),
                          ),

                          const SizedBox(height: 18),

                          _FramePanel(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'READY TO START',
                                  style: AppTextStyles.labelSmall.copyWith(
                                    color: AppColors.textMuted,
                                    letterSpacing: 0.9,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                ClipRect(
                                  child: AspectRatio(
                                    aspectRatio: 1,
                                    child: Image.asset(
                                      AppConstants.walletCreateAsset,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: const BoxDecoration(
                                        color: AppColors.secondary,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'DEVICE READY',
                                      style: AppTextStyles.labelMedium.copyWith(
                                        color: AppColors.textPrimary,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 22),

                          Text(
                            'Set Up Your Wallet',
                            style: AppTextStyles.displayMedium.copyWith(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              height: 1.15,
                            ),
                          ),

                          const SizedBox(height: 10),

                          Text(
                            identity == null
                                ? 'Create your wallet on this device to continue. In the next step, you will protect it with your phone biometrics.'
                                : 'Your wallet is ready on this device. Continue to the next step to protect it with biometrics.',
                            style: AppTextStyles.bodyMedium.copyWith(
                              color: AppColors.textSecondary,
                              height: 1.6,
                            ),
                          ),

                          const SizedBox(height: 22),

                          if (identity != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 22),
                              child: Column(
                                children: [
                                  _InfoTile(
                                    label: 'WALLET ADDRESS',
                                    value: identity.walletAddress,
                                  ),
                                  const SizedBox(height: 10),
                                  _InfoTile(
                                    label: 'WALLET ID',
                                    value: identity.fingerprint,
                                  ),
                                ],
                              ),
                            ),

                          const Row(
                            children: [
                              Expanded(
                                child: _InfoTile(
                                  label: 'STORAGE',
                                  value: 'ON THIS DEVICE',
                                ),
                              ),
                              SizedBox(width: 10),
                              Expanded(
                                child: _InfoTile(
                                  label: 'PROTECTION',
                                  value: 'BIOMETRIC LOCK',
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
                                      context.go(AppRoutes.registration);
                                      return;
                                    }

                                    setState(() {
                                      _isGenerating = true;
                                      _errorMessage = null;
                                    });

                                    final result = await controller.createIdentity();
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
                                    context.go(AppRoutes.registration);
                                  },
                            icon: const Icon(Icons.link_rounded, size: 18),
                            label: Text(
                              _isGenerating
                                  ? 'SETTING UP WALLET'
                                  : identity == null
                                      ? 'CREATE WALLET'
                                      : 'CONTINUE',
                              style: AppTextStyles.buttonText,
                            ),
                            style: ElevatedButton.styleFrom(
                              iconColor: AppColors.textPrimary,
                              foregroundColor: AppColors.textPrimary,
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
                                  ? 'Your wallet is created on this device.'
                                  : 'Your wallet is ready to protect.',
                              style: AppTextStyles.labelSmall.copyWith(
                                color: AppColors.textMuted,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ),

                          const Spacer(),
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


class _FramePanel extends StatelessWidget {
  const _FramePanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface.withAlpha(90),
        border: Border.all(color: AppColors.primary.withAlpha(140)),
      ),
      child: child,
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface.withAlpha(70),
        border: Border.all(color: AppColors.border),
      ),
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
          const SizedBox(height: 8),
          Text(
            value,
            style: AppTextStyles.labelMedium.copyWith(
              color: AppColors.textPrimary,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}
