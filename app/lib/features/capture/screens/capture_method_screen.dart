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

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border.all(color: AppColors.border),
                ),
                child: Row(
                  children: [
                    Icon(Icons.terminal_rounded, color: AppColors.primary),
                    const SizedBox(width: 10),
                    Text(
                      'VERIFY_OPS_v1.0',
                      style: AppTextStyles.labelLarge.copyWith(
                        color: AppColors.primary,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: AppColors.statusActive,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'NODE_ACTIVE',
                      style: AppTextStyles.labelMedium.copyWith(
                        color: AppColors.statusActive,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Icon(
                    Icons.check_circle_rounded,
                    size: 18,
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
              const SizedBox(height: 10),
              Text(
                'Select Input Method',
                style: AppTextStyles.displayMedium.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              RichText(
                text: TextSpan(
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: AppColors.textSecondary,
                  ),
                  children: [
                    const TextSpan(
                      text: 'Establish the source of truth for Project_ID: ',
                    ),
                    TextSpan(
                      text: projectLabel,
                      style: AppTextStyles.labelLarge.copyWith(
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: _ActionCard(
                        icon: Icons.photo_camera_rounded,
                        title: 'TAKE_PHOTO',
                        badge: 'Instant Forensic Attestation',
                        badgeForeground: AppColors.primary,
                        badgeBackground: AppColors.primary.withAlpha(18),
                        description:
                            'Secure capture with embedded hash provenance and signed field metadata.',
                        onTap: () => context.push(AppRoutes.capturePhoto),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: _ActionCard(
                        icon: Icons.cloud_upload_rounded,
                        title: 'UPLOAD_FILE',
                        badge: 'PDF, JPG, DOCX (Max 50MB)',
                        badgeForeground: AppColors.textSecondary,
                        badgeBackground: AppColors.surfaceOverlay,
                        description:
                            'Ingest an existing document or image, hash it locally, and anchor the file attestation on Sui.',
                        onTap: () => context.push(AppRoutes.captureFile),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Center(
                child: TextButton.icon(
                  onPressed: () {
                    context.go('${AppRoutes.dashboard}?tab=1');
                  },
                  icon: Icon(
                    Icons.arrow_back_rounded,
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
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.title,
    required this.badge,
    required this.badgeForeground,
    required this.badgeBackground,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String badge;
  final Color badgeForeground;
  final Color badgeBackground;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.borderActive),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  border: Border.all(color: AppColors.borderActive),
                ),
                child: Icon(icon, size: 34, color: AppColors.primary),
              ),
              const SizedBox(height: 18),
              Text(
                title,
                style: AppTextStyles.headlineMedium.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: badgeBackground,
                  border: Border.all(color: AppColors.border),
                ),
                child: Text(
                  badge.toUpperCase(),
                  style: AppTextStyles.labelSmall.copyWith(
                    color: badgeForeground,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                description,
                textAlign: TextAlign.center,
                style: AppTextStyles.bodyMedium.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
