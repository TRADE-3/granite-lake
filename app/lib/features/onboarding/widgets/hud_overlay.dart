import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';

/// Top HUD overlay row: enrollment flow ID + status + encrypt on left,
/// optional trailing widget (e.g. icon badge) on right.
class TopHudOverlay extends StatelessWidget {
  const TopHudOverlay({
    super.key,
    required this.flowId,
    this.status = 'ACTIVE',
    this.encryptAlgo = 'AES-256',
    this.trailing,
  });

  final String flowId;
  final String status;
  final String encryptAlgo;
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  flowId,
                  style: AppTextStyles.hudLabel.copyWith(
                    color: AppColors.textMuted,
                  ),
                ),
                const SizedBox(height: 3),
                _HudTagRow(
                  label: 'STATUS',
                  value: status,
                  valueColor: AppColors.statusActive,
                ),
                const SizedBox(height: 2),
                _HudTagRow(
                  label: 'ENCRYPT',
                  value: encryptAlgo,
                  valueColor: AppColors.textSecondary,
                ),
              ],
            ),
          ),
          if (trailing != null)
            Align(alignment: Alignment.topCenter, child: trailing!),
        ],
      ),
    );
  }
}

class _HudTagRow extends StatelessWidget {
  const _HudTagRow({
    required this.label,
    required this.value,
    required this.valueColor,
  });

  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label: ', style: AppTextStyles.hudLabel),
        Text(value, style: AppTextStyles.hudLabel.copyWith(color: valueColor)),
      ],
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
