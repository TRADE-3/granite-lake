import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';

/// Top HUD overlay row: plain-language onboarding step label on the left,
/// optional trailing widget (e.g. icon badge) on the right.
class TopHudOverlay extends StatelessWidget {
  const TopHudOverlay({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          Align(
            alignment: Alignment.topLeft,
            child: Text(
              title,
              style: AppTextStyles.hudLabel.copyWith(
                color: AppColors.textMuted,
              ),
            ),
          ),
          if (trailing != null)
            Align(alignment: Alignment.topCenter, child: trailing!),
        ],
      ),
    );
  }
}

/// Tactical shield badge used in the HUD header.
class ShieldBadge extends StatelessWidget {
  const ShieldBadge({super.key, this.size = 44});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(30),
        border: Border.all(color: AppColors.primary.withAlpha(80), width: 1),
      ),
      child: Icon(
        Icons.verified_user_rounded,
        color: AppColors.primary,
        size: size * 0.52,
      ),
    );
  }
}
