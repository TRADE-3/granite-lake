import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/router/app_router.dart';
import '../../../core/state/granite_lake_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';

/// The Capture tab body shown inside [MainShell].
///
/// Displays session status and lets the operator start/end a secure session.
/// When a session is active, tapping the Capture nav item (or the button here)
/// navigates to the capture method chooser at [AppRoutes.capture].
class CaptureTabScreen extends StatefulWidget {
  const CaptureTabScreen({super.key});

  @override
  State<CaptureTabScreen> createState() => _CaptureTabScreenState();
}

class _CaptureTabScreenState extends State<CaptureTabScreen>
    with TickerProviderStateMixin {
  bool _isStartingSession = false;
  bool _isEndingSession = false;
  String? _errorMessage;
  AnimationController? _pulseController;
  // Plays once on mount - fades/slides the whole content column in, rather
  // than having it snap into place, per the request for this screen to feel
  // animated rather than static.
  AnimationController? _introController;

  @override
  void initState() {
    super.initState();
    _ensurePulseController();
    _introController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    )..forward();
  }

  @override
  void dispose() {
    _pulseController?.dispose();
    _introController?.dispose();
    super.dispose();
  }

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

  Future<void> _showMissingProjectsDialog() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: AppColors.surfaceElevated,
          title: Text(
            'No Projects Created',
            style: AppTextStyles.headlineMedium,
          ),
          content: Text(
            'Create a project before starting or continuing a verified capture session.',
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textSecondary,
              height: 1.5,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(
                'CLOSE',
                style: AppTextStyles.buttonText.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _handlePrimaryAction(bool activeSession) async {
    if (_isStartingSession || _isEndingSession) {
      return;
    }

    final controller = GraniteLakeScope.of(context);
    if (!controller.hasProjects) {
      await _showMissingProjectsDialog();
      return;
    }

    if (activeSession) {
      context.push(AppRoutes.capture);
      return;
    }

    setState(() {
      _isStartingSession = true;
      _errorMessage = null;
    });

    final result = await controller.startSession();
    if (!mounted) {
      return;
    }

    if (result.code == 'biometric_reset_required') {
      setState(() => _isStartingSession = false);
      final shouldReset = await _showBiometricResetDialog(
        result.message ??
            'Biometrics changed on this device. Re-bind required.',
      );
      if (!mounted) {
        return;
      }
      if (shouldReset == true) {
        await controller.resetForBiometricInvalidation();
        if (!mounted) {
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
    context.push(AppRoutes.capture);
  }

  Future<void> _handleEndSession() async {
    if (_isStartingSession || _isEndingSession) {
      return;
    }

    setState(() {
      _isEndingSession = true;
      _errorMessage = null;
    });

    await GraniteLakeScope.of(context).endSession();
    if (!mounted) {
      return;
    }

    setState(() => _isEndingSession = false);
  }

  @override
  Widget build(BuildContext context) {
    final controller = GraniteLakeScope.of(context);
    final activeSession = controller.hasActiveSession;
    final session = controller.session;
    final identity = controller.identity;
    final biometricIcon = _resolveBiometricIcon(controller.biometricBinding);
    final pulseController = _ensurePulseController();
    final introController = _introController!;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -0.2),
          radius: 1.0,
          colors: [
            controller.isDarkMode
                ? const Color(0xFF1A2E1E)
                : const Color(0xFFE8F2FF),
            AppColors.background,
            AppColors.background,
          ],
          stops: const [0.0, 0.55, 1.0],
        ),
      ),
      child: Stack(
        children: [
          const Positioned.fill(child: _ScanlineOverlay()),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Column(
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        const Positioned(
                          top: 0,
                          left: 0,
                          child: _CornerReticle(top: true, left: true),
                        ),
                        const Positioned(
                          top: 0,
                          right: 0,
                          child: _CornerReticle(top: true, left: false),
                        ),
                        const Positioned(
                          bottom: 0,
                          left: 0,
                          child: _CornerReticle(top: false, left: true),
                        ),
                        const Positioned(
                          bottom: 0,
                          right: 0,
                          child: _CornerReticle(top: false, left: false),
                        ),
                        Center(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 400),
                              child: AnimatedBuilder(
                                animation: introController,
                                builder: (context, child) {
                                  final t = Curves.easeOutCubic.transform(
                                    introController.value,
                                  );
                                  return Opacity(
                                    opacity: t,
                                    child: Transform.translate(
                                      offset: Offset(0, (1 - t) * 20),
                                      child: child,
                                    ),
                                  );
                                },
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      'AUTHENTICATED USER',
                                      style: AppTextStyles.labelMedium.copyWith(
                                        color: AppColors.textSecondary,
                                        letterSpacing: 2,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    SizedBox(
                                      width: double.infinity,
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Text(
                                          identity?.walletTag ??
                                              AppConstants.appTitle,
                                          maxLines: 1,
                                          textAlign: TextAlign.center,
                                          style: AppTextStyles.displayMedium
                                              .copyWith(
                                                fontWeight: FontWeight.w600,
                                              ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 28),
                                    GestureDetector(
                                      onTap: () =>
                                          _handlePrimaryAction(activeSession),
                                      child: _BiometricUnlockButton(
                                        pulse: pulseController,
                                        isBusy: _isStartingSession,
                                        isActive: activeSession,
                                        iconData: biometricIcon,
                                      ),
                                    ),
                                    const SizedBox(height: 28),
                                    AnimatedSwitcher(
                                      duration: const Duration(
                                        milliseconds: 300,
                                      ),
                                      child: Text(
                                        activeSession
                                            ? 'Session active. Tap to continue your verified capture workflow.'
                                            : 'Unlock to start a 30-minute verified capture session.',
                                        key: ValueKey(activeSession),
                                        textAlign: TextAlign.center,
                                        style: AppTextStyles.bodyMedium
                                            .copyWith(
                                              color: AppColors.textSecondary,
                                              height: 1.6,
                                            ),
                                      ),
                                    ),
                                    const SizedBox(height: 18),
                                    _SessionStatusCard(
                                      isActive: activeSession,
                                      hashValue:
                                          identity?.fingerprint ??
                                          'Not yet bound',
                                      ttlValue: activeSession
                                          ? _formatSeconds(
                                              controller
                                                  .remainingSessionDuration,
                                            )
                                          : null,
                                      pulse: pulseController,
                                    ),
                                    if (session != null) ...[
                                      const SizedBox(height: 14),
                                      Text(
                                        'Expires ${session.expiresAt.toLocal().toString().substring(11, 19)}',
                                        style: AppTextStyles.labelMedium
                                            .copyWith(
                                              color: AppColors.textSecondary,
                                            ),
                                      ),
                                    ],
                                    if (_errorMessage != null) ...[
                                      const SizedBox(height: 12),
                                      Text(
                                        _errorMessage!,
                                        textAlign: TextAlign.center,
                                        style: AppTextStyles.bodySmall.copyWith(
                                          color: AppColors.statusError,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (activeSession) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: _isStartingSession || _isEndingSession
                            ? null
                            : _handleEndSession,
                        // Solid fill rather than the default transparent
                        // outline - otherwise the corner-reticle brackets
                        // positioned just above this button show through and
                        // visually clash with its top edge.
                        style: OutlinedButton.styleFrom(
                          backgroundColor: AppColors.surfaceElevated,
                          side: BorderSide(color: AppColors.borderActive),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: Text(
                          _isEndingSession ? 'ENDING SESSION' : 'END SESSION',
                          style: AppTextStyles.buttonText.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  const _SecurityBadge(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatSeconds(Duration duration) {
    final seconds = duration.inMilliseconds / 1000;
    return '${seconds.toStringAsFixed(2)}s';
  }

  IconData _resolveBiometricIcon(BiometricBindingRecord? binding) {
    final modalities =
        binding?.modalities.map((item) => item.toUpperCase()).toList() ??
        const <String>[];
    if (modalities.any((item) => item.contains('FACE'))) {
      return Icons.face_retouching_natural_rounded;
    }
    if (modalities.any((item) => item.contains('IRIS'))) {
      return Icons.visibility_rounded;
    }
    return Icons.fingerprint_rounded;
  }

  AnimationController _ensurePulseController() {
    return _pulseController ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);
  }
}

class _SessionStatusCard extends StatelessWidget {
  const _SessionStatusCard({
    required this.isActive,
    required this.hashValue,
    required this.ttlValue,
    required this.pulse,
  });

  final bool isActive;
  final String hashValue;
  // Null when locked - there's no meaningful countdown to show yet, so the
  // field is omitted entirely rather than padded out with a "--.--s"
  // placeholder that doesn't tell the crew anything.
  final String? ttlValue;
  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) {
    final accent = isActive ? AppColors.statusActive : AppColors.textMuted;
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, child) {
        final glowAlpha = isActive ? 0.10 + (pulse.value * 0.16) : 0.0;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface.withAlpha(230),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isActive
                  ? AppColors.statusActive.withAlpha(140)
                  : AppColors.borderActive,
            ),
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: AppColors.statusActive.withValues(
                        alpha: glowAlpha,
                      ),
                      blurRadius: 22,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: child,
        );
      },
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _ProtocolValue(
                  label: 'Identity Fingerprint',
                  value: hashValue,
                  alignment: CrossAxisAlignment.start,
                ),
              ),
              if (ttlValue != null) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: _ProtocolValue(
                    label: 'Time Remaining',
                    value: ttlValue!,
                    alignment: CrossAxisAlignment.end,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(
                isActive ? Icons.lock_open_rounded : Icons.lock_outline_rounded,
                size: 16,
                color: accent,
              ),
              const SizedBox(width: 8),
              Text(
                isActive ? 'SESSION ACTIVE' : 'LOCKED',
                style: AppTextStyles.labelMedium.copyWith(
                  color: accent,
                  letterSpacing: 1.1,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProtocolValue extends StatelessWidget {
  const _ProtocolValue({
    required this.label,
    required this.value,
    required this.alignment,
  });

  final String label;
  final String value;
  final CrossAxisAlignment alignment;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: alignment,
      children: [
        Text(
          label.toUpperCase(),
          style: AppTextStyles.hudLabel.copyWith(color: AppColors.textMuted),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.labelMedium.copyWith(
            color: AppColors.textPrimary,
            letterSpacing: 0.4,
          ),
        ),
      ],
    );
  }
}

class _SecurityBadge extends StatelessWidget {
  const _SecurityBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.surface.withAlpha(180),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_rounded, size: 12, color: AppColors.textMuted),
          const SizedBox(width: 6),
          Text(
            'CAPTURES ARE HASHED AND SIGNED ON DEVICE',
            style: AppTextStyles.labelSmall.copyWith(
              color: AppColors.textMuted,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

class _BiometricUnlockButton extends StatelessWidget {
  const _BiometricUnlockButton({
    required this.pulse,
    required this.isBusy,
    required this.isActive,
    required this.iconData,
  });

  final Animation<double> pulse;
  final bool isBusy;
  final bool isActive;
  final IconData iconData;

  @override
  Widget build(BuildContext context) {
    final ringColor = isActive
        ? AppColors.statusActive
        : const Color(0xFF40E56C);

    return SizedBox(
      width: 180,
      height: 180,
      child: AnimatedBuilder(
        animation: pulse,
        builder: (context, child) {
          final scale = 0.94 + (pulse.value * 0.14);
          final opacity = 0.14 + (pulse.value * 0.18);

          return Stack(
            alignment: Alignment.center,
            children: [
              Transform.scale(
                scale: scale,
                child: Container(
                  width: 176,
                  height: 176,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: ringColor.withValues(alpha: opacity),
                      width: 2,
                    ),
                  ),
                ),
              ),
              Container(
                width: 144,
                height: 144,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: ringColor.withAlpha(90)),
                ),
              ),
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.surfaceElevated,
                  border: Border.all(color: AppColors.borderActive),
                  boxShadow: [
                    BoxShadow(
                      color: ringColor.withAlpha(30),
                      blurRadius: 24,
                      spreadRadius: 6,
                    ),
                  ],
                ),
                child: Center(
                  child: isBusy
                      ? const SizedBox(
                          width: 30,
                          height: 30,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          isActive
                              ? Icons.collections_bookmark_rounded
                              : iconData,
                          size: 44,
                          color: ringColor,
                        ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _CornerReticle extends StatelessWidget {
  const _CornerReticle({required this.top, required this.left});

  final bool top;
  final bool left;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: CustomPaint(
        painter: _CornerReticlePainter(
          top: top,
          left: left,
          color: AppColors.borderActive.withAlpha(180),
        ),
      ),
    );
  }
}

class _CornerReticlePainter extends CustomPainter {
  const _CornerReticlePainter({
    required this.top,
    required this.left,
    required this.color,
  });

  final bool top;
  final bool left;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final path = Path();
    final x = left ? 0.0 : size.width;
    final y = top ? 0.0 : size.height;
    path.moveTo(x, y + (top ? 24 : -24));
    path.lineTo(x, y);
    path.lineTo(x + (left ? 24 : -24), y);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CornerReticlePainter oldDelegate) {
    return oldDelegate.top != top ||
        oldDelegate.left != left ||
        oldDelegate.color != color;
  }
}

/// A slow, continuously drifting scanline sweep behind the content - purely
/// decorative texture, but animated rather than a static striped overlay so
/// the whole screen reads as "alive."
class _ScanlineOverlay extends StatefulWidget {
  const _ScanlineOverlay();

  @override
  State<_ScanlineOverlay> createState() => _ScanlineOverlayState();
}

class _ScanlineOverlayState extends State<_ScanlineOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return ShaderMask(
            shaderCallback: (bounds) {
              return LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                tileMode: TileMode.repeated,
                transform: _SlidingGradientTransform(_controller.value),
                colors: List.generate(
                  16,
                  (index) => index.isEven
                      ? Colors.transparent
                      : const Color(0xFF40E56C).withAlpha(14),
                ),
              ).createShader(bounds);
            },
            blendMode: BlendMode.srcATop,
            child: child,
          );
        },
        child: Container(color: Colors.white.withAlpha(12)),
      ),
    );
  }
}

class _SlidingGradientTransform extends GradientTransform {
  const _SlidingGradientTransform(this.slidePercent);

  final double slidePercent;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(0, bounds.height * slidePercent, 0);
  }
}
