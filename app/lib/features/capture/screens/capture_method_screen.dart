import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';

class CaptureMethodScreen extends StatelessWidget {
  const CaptureMethodScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = GraniteLakeScope.of(context);
    final selectedProject = controller.selectedProject;
    final projectLabel = selectedProject == null
        ? 'UNASSIGNED'
        : selectedProject.projectId;
    // Compact phones (e.g. iPhone SE) get tighter spacing so the two method
    // cards and the back link stay comfortably reachable without relying on
    // the scroll fallback below.
    final isCompact = MediaQuery.sizeOf(context).height < 760;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        // Ambient brand-colored glows behind the content - Stack's default
        // hardEdge clip keeps them from bleeding past the screen bounds even
        // though they're positioned partly off-canvas.
        children: [
          Positioned(
            top: -90,
            right: -70,
            child: _AmbientGlow(color: AppColors.primary, size: 240),
          ),
          Positioned(
            bottom: -110,
            left: -90,
            child: _AmbientGlow(color: AppColors.secondary, size: 260),
          ),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                // Caps content width on tablets/wide screens instead of
                // letting the cards stretch edge-to-edge.
                constraints: const BoxConstraints(maxWidth: 480),
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(20, isCompact ? 16 : 28, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _SuccessPill(),
                      SizedBox(height: isCompact ? 14 : 20),
                      Text(
                        'Select Input Method',
                        style: AppTextStyles.displayMedium.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Establish the source of truth for this capture.',
                        style: AppTextStyles.bodyMedium.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                      SizedBox(height: isCompact ? 14 : 18),
                      _ProjectChip(projectLabel: projectLabel),
                      SizedBox(height: isCompact ? 22 : 32),
                      _MethodCard(
                        icon: Icons.photo_camera_rounded,
                        accent: AppColors.primary,
                        accentSecondary: AppColors.statusEncrypt,
                        title: 'TAKE_PHOTO',
                        badge: 'Instant Signed Attestation',
                        description:
                            'Secure capture with embedded hash provenance and signed field metadata.',
                        onTap: () => context.push(AppRoutes.capturePhoto),
                      ),
                      const SizedBox(height: 16),
                      _MethodCard(
                        icon: Icons.cloud_upload_rounded,
                        accent: AppColors.secondary,
                        accentSecondary: AppColors.tertiary,
                        title: 'UPLOAD_FILE',
                        badge: 'PDF, JPG, DOCX (Max 50MB)',
                        description:
                            'Ingest an existing document or image, hash it locally, and anchor the file attestation on Sui.',
                        onTap: () => context.push(AppRoutes.captureFile),
                      ),
                      SizedBox(height: isCompact ? 14 : 22),
                      Center(
                        child: TextButton.icon(
                          onPressed: () {
                            context.go('${AppRoutes.dashboard}?tab=1');
                          },
                          icon: Icon(
                            Icons.arrow_back_rounded,
                            size: 18,
                            color: AppColors.textSecondary,
                          ),
                          label: Text(
                            'BACK_TO_AUTH',
                            style: AppTextStyles.labelLarge.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A soft, large-radius radial glow used purely for background depth - never
/// intercepts touches, so it's safe to layer behind interactive content.
class _AmbientGlow extends StatelessWidget {
  const _AmbientGlow({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color.withAlpha(70), color.withAlpha(0)],
          ),
        ),
      ),
    );
  }
}

class _SuccessPill extends StatelessWidget {
  const _SuccessPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.statusActive.withAlpha(24),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.statusActive.withAlpha(100)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.check_circle_rounded,
            size: 16,
            color: AppColors.statusActive,
          ),
          const SizedBox(width: 8),
          Text(
            'AUTHENTICATION SUCCESSFUL',
            style: AppTextStyles.labelMedium.copyWith(
              color: AppColors.statusActive,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProjectChip extends StatelessWidget {
  const _ProjectChip({required this.projectLabel});

  final String projectLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(Icons.fingerprint_rounded, size: 18, color: AppColors.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('PROJECT_ID', style: AppTextStyles.hudLabel),
                const SizedBox(height: 2),
                Text(
                  projectLabel,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.hudValue.copyWith(
                    color: AppColors.primary,
                    fontSize: 12,
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

class _MethodCard extends StatelessWidget {
  const _MethodCard({
    required this.icon,
    required this.accent,
    required this.accentSecondary,
    required this.title,
    required this.badge,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final Color accent;
  final Color accentSecondary;
  final String title;
  final String badge;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(22);
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: borderRadius,
        border: Border.all(color: AppColors.borderActive),
        boxShadow: [
          BoxShadow(
            color: accent.withAlpha(46),
            blurRadius: 26,
            spreadRadius: -6,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: borderRadius,
        child: InkWell(
          borderRadius: borderRadius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _GlowIconBadge(
                  icon: icon,
                  accent: accent,
                  accentSecondary: accentSecondary,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: AppTextStyles.headlineMedium.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.arrow_forward_ios_rounded,
                            size: 14,
                            color: AppColors.textMuted,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: accent.withAlpha(24),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          badge.toUpperCase(),
                          style: AppTextStyles.labelSmall.copyWith(
                            color: accent,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        description,
                        style: AppTextStyles.bodyMedium.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GlowIconBadge extends StatelessWidget {
  const _GlowIconBadge({
    required this.icon,
    required this.accent,
    required this.accentSecondary,
  });

  final IconData icon;
  final Color accent;
  final Color accentSecondary;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent, accentSecondary],
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withAlpha(110),
            blurRadius: 18,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Icon(icon, size: 26, color: AppColors.actionText),
    );
  }
}
