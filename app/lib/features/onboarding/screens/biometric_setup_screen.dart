import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app.dart';
import '../../../core/state/granite_lake_controller.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../widgets/hud_overlay.dart';
import '../widgets/scan_line_overlay.dart';

class BiometricSetupScreen extends StatefulWidget {
  const BiometricSetupScreen({super.key});

  @override
  State<BiometricSetupScreen> createState() => _BiometricSetupScreenState();
}

class _BiometricSetupScreenState extends State<BiometricSetupScreen> {
  bool _isBinding = false;
  String? _errorMessage;

  @override
  Widget build(BuildContext context) {
    final controller = GraniteLakeScope.of(context);
    final binding = controller.biometricBinding;

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
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: IntrinsicHeight(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TopHudOverlay(
                            flowId: AppConstants.biometricFlowId,
                            status: AppConstants.biometricStatus,
                            encryptAlgo: AppConstants.biometricEncryptMode,
                            trailing: const ShieldBadge(size: 48),
                          ),

                          const SizedBox(height: 18),

                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'SECURITY',
                                  style: AppTextStyles.labelSmall.copyWith(
                                    color: AppColors.textMuted,
                                    letterSpacing: 0.9,
                                  ),
                                ),
                              ),
                              Text(
                                binding?.modalitiesLabel ?? 'DEVICE BIOMETRICS',
                                style: AppTextStyles.labelSmall.copyWith(
                                  color: AppColors.textSecondary,
                                  letterSpacing: 0.9,
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 8),

                          Text(
                            'Protect Your Wallet',
                            style: AppTextStyles.displayMedium.copyWith(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              height: 1.15,
                            ),
                          ),

                          const SizedBox(height: 10),

                          Text(
                            binding == null
                                ? 'Use your fingerprint or face unlock to protect your wallet on this device.'
                                : 'Biometric protection is turned on. You will use it whenever the app needs to unlock your wallet.',
                            style: AppTextStyles.bodyMedium.copyWith(
                              color: AppColors.textSecondary,
                              height: 1.6,
                            ),
                          ),

                          const SizedBox(height: 18),

                          _BiometricPanel(
                            isBinding: _isBinding,
                            isBound: binding != null,
                            binding: binding,
                          ),

                          const SizedBox(height: 18),

                          ElevatedButton(
                            onPressed: _isBinding
                                ? null
                                : () async {
                                    if (binding != null) {
                                      context.go(AppRoutes.dashboard);
                                      return;
                                    }

                                    setState(() {
                                      _isBinding = true;
                                      _errorMessage = null;
                                    });

                                    final result = await controller
                                        .bindBiometrics();
                                    if (!context.mounted) {
                                      return;
                                    }

                                    if (!result.isSuccess) {
                                      setState(() {
                                        _isBinding = false;
                                        _errorMessage = result.message;
                                      });
                                      return;
                                    }

                                    setState(() => _isBinding = false);
                                    context.go(AppRoutes.dashboard);
                                  },
                            style: ElevatedButton.styleFrom(
                              iconColor: AppColors.textPrimary,
                              foregroundColor: AppColors.textPrimary,
                            ),
                            child: Text(
                              _isBinding
                                  ? 'SETTING UP PROTECTION'
                                  : binding == null
                                  ? 'TURN ON BIOMETRICS'
                                  : 'CONTINUE',
                              style: AppTextStyles.buttonText,
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

                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.surface.withAlpha(70),
                              border: Border.all(color: AppColors.border),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Icon(
                                    Icons.info_outline_rounded,
                                    size: 16,
                                    color: AppColors.textMuted,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'Your fingerprint or face data stays on your device. This app only uses it to help protect your wallet.',
                                    style: AppTextStyles.bodySmall.copyWith(
                                      color: AppColors.textSecondary,
                                      height: 1.5,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          const Spacer(),

                          Row(
                            children: [
                              Expanded(
                                child: _FooterMetric(
                                  label: 'AUTH LEVEL',
                                  value: binding == null
                                      ? 'NOT READY'
                                      : 'READY',
                                  valueColor: AppColors.textPrimary,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _FooterMetric(
                                  label: 'COMPLIANCE',
                                  value: binding == null
                                      ? 'DEVICE ONLY'
                                      : 'BIOMETRIC LOCK',
                                  valueColor: AppColors.secondary,
                                  alignEnd: true,
                                ),
                              ),
                            ],
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

class _BiometricPanel extends StatelessWidget {
  const _BiometricPanel({
    required this.isBinding,
    required this.isBound,
    required this.binding,
  });

  final bool isBinding;
  final bool isBound;
  final BiometricBindingRecord? binding;

  @override
  Widget build(BuildContext context) {
    final statusLabel = isBound
        ? 'HARDWARE GATE ACTIVE'
        : isBinding
        ? 'VERIFYING ENROLLMENT'
        : 'READY FOR ENROLLMENT';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface.withAlpha(90),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 16, height: 1, color: AppColors.borderActive),
              const Spacer(),
              Text(
                'ENCRYPTED_PATH: ACTIVE',
                style: AppTextStyles.labelSmall.copyWith(
                  color: AppColors.secondary,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Center(
            child: _FingerprintScannerBox(
              isBinding: isBinding,
              isBound: isBound,
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              statusLabel,
              style: AppTextStyles.labelSmall.copyWith(
                color: isBound ? AppColors.secondary : AppColors.textSecondary,
                letterSpacing: 0.9,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(
                4,
                (index) => Container(
                  width: 4,
                  height: 4,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    color: switch ((isBound, isBinding, index)) {
                      (true, _, 0) ||
                      (true, _, 1) ||
                      (true, _, 2) ||
                      (true, _, 3) => AppColors.secondary,
                      (false, true, 0) || (false, true, 1) => AppColors.primary,
                      (false, true, _) => AppColors.textMuted,
                      (false, false, 0) => AppColors.textPrimary,
                      _ => AppColors.textMuted,
                    },
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text(
                'HW_ID: 0x8F92',
                style: AppTextStyles.labelSmall.copyWith(
                  color: AppColors.textMuted,
                ),
              ),
              const Spacer(),
              Container(width: 16, height: 1, color: AppColors.primary),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            isBound
                ? 'KEYSTORE_ALIAS: ${binding?.gateAlias.isNotEmpty == true ? binding!.gateAlias : 'REGISTERED'}'
                : isBinding
                ? 'LATENCY: 08ms'
                : 'LATENCY: 12ms',
            style: AppTextStyles.labelSmall.copyWith(
              color: isBound ? AppColors.textSecondary : AppColors.textMuted,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _FingerprintScannerBox extends StatefulWidget {
  const _FingerprintScannerBox({this.isBinding, this.isBound});

  final bool? isBinding;
  final bool? isBound;

  bool get resolvedIsBinding => isBinding ?? false;

  bool get resolvedIsBound => isBound ?? false;

  @override
  State<_FingerprintScannerBox> createState() => _FingerprintScannerBoxState();
}

class _FingerprintScannerBoxState extends State<_FingerprintScannerBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _FingerprintScannerBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resolvedIsBinding == widget.resolvedIsBinding) {
      return;
    }

    _controller.duration = Duration(
      milliseconds: widget.resolvedIsBinding ? 900 : 2400,
    );
    _controller
      ..reset()
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      height: 220,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final pulse = 1 + (_controller.value * 0.05);
          final scanTop = 28 + (_controller.value * 150);
          final glowColor = widget.resolvedIsBound
              ? AppColors.secondary
              : AppColors.primary;

          return Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.surfaceElevated,
                    border: Border.all(color: AppColors.borderActive),
                  ),
                  child: CustomPaint(painter: _ScannerGridPainter()),
                ),
              ),
              Center(
                child: Transform.scale(
                  scale: pulse,
                  child: Container(
                    width: 156,
                    height: 156,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: glowColor.withAlpha(32)),
                    ),
                  ),
                ),
              ),
              Center(
                child: Container(
                  width: 126,
                  height: 126,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.surface.withAlpha(132),
                    border: Border.all(color: AppColors.border.withAlpha(120)),
                    boxShadow: [
                      BoxShadow(
                        color: glowColor.withAlpha(
                          widget.resolvedIsBound ? 36 : 28,
                        ),
                        blurRadius: 22,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                top: scanTop,
                left: 52,
                right: 52,
                child: Container(
                  height: 2,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        glowColor.withAlpha(0),
                        glowColor.withAlpha(220),
                        glowColor.withAlpha(0),
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: glowColor.withAlpha(70),
                        blurRadius: 10,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
              ),
              Center(
                child: Icon(
                  widget.resolvedIsBound
                      ? Icons.verified_user_rounded
                      : Icons.fingerprint_rounded,
                  color: widget.resolvedIsBound
                      ? AppColors.secondary
                      : const Color(0xFFAEB8FF),
                  size: widget.resolvedIsBound ? 58 : 68,
                ),
              ),
              Positioned(
                left: 10,
                bottom: 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'HW_ID: 0x8F92',
                      style: AppTextStyles.labelSmall.copyWith(
                        color: AppColors.textMuted.withAlpha(150),
                      ),
                    ),
                    Text(
                      widget.resolvedIsBinding
                          ? 'SCAN: ACTIVE'
                          : 'SCAN: STANDBY',
                      style: AppTextStyles.labelSmall.copyWith(
                        color: AppColors.textMuted.withAlpha(150),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                top: 10,
                right: 10,
                child: Text(
                  widget.resolvedIsBound
                      ? 'ENCRYPTED_PATH: BOUND'
                      : 'ENCRYPTED_PATH: ACTIVE',
                  style: AppTextStyles.labelSmall.copyWith(color: glowColor),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ScannerGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = AppColors.textMuted.withAlpha(20);
    const spacing = 22.0;

    for (double dx = 12; dx < size.width; dx += spacing) {
      for (double dy = 12; dy < size.height; dy += spacing) {
        canvas.drawCircle(Offset(dx, dy), 1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _FooterMetric extends StatelessWidget {
  const _FooterMetric({
    required this.label,
    required this.value,
    required this.valueColor,
    this.alignEnd = false,
  });

  final String label;
  final String value;
  final Color valueColor;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTextStyles.labelSmall.copyWith(
            color: AppColors.textMuted,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          value,
          style: AppTextStyles.labelLarge.copyWith(
            color: valueColor,
            letterSpacing: 0.8,
          ),
        ),
      ],
    );
  }
}
