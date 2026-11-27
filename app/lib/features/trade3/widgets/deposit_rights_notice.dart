import 'package:flutter/material.dart';

import '../../../core/state/granite_lake_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';

/// Shown on the capture and file screens when Trade3 says the user may not
/// deposit documents, so they learn before doing the work.
class DepositRightsNotice extends StatelessWidget {
  const DepositRightsNotice({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        border: Border.all(color: AppColors.statusError),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline_rounded, color: AppColors.statusError),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              GraniteLakeController.depositRightsMessage,
              style: AppTextStyles.bodyMedium.copyWith(
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
