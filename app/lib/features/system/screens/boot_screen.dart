import 'package:flutter/material.dart';

import '../../../core/state/granite_lake_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';

class BootScreen extends StatelessWidget {
  const BootScreen({super.key, required this.controller});

  final GraniteLakeController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 42,
                  height: 42,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'SECURE SYSTEM BOOT',
                  style: AppTextStyles.displayMedium.copyWith(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  controller.initializationError ??
                      'Loading secure identity, session state, and capture services.',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: AppColors.textSecondary,
                    height: 1.6,
                  ),
                ),
                if (controller.initializationError != null) ...[
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: controller.initialize,
                    child: Text('RETRY BOOT', style: AppTextStyles.buttonText),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
