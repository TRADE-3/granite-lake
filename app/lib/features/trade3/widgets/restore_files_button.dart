import 'package:flutter/material.dart';

import '../../../app.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';

/// Rebuilds history after a wallet import. Offered until it succeeds once,
/// whether or not there was anything to restore.
class RestoreFilesButton extends StatefulWidget {
  const RestoreFilesButton({super.key});

  @override
  State<RestoreFilesButton> createState() => _RestoreFilesButtonState();
}

class _RestoreFilesButtonState extends State<RestoreFilesButton> {
  bool _isRestoring = false;

  Future<void> _restore() async {
    // Taken first: success removes this button before the call returns.
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _isRestoring = true);
    final result = await GraniteLakeScope.of(context).restoreFiles();
    if (mounted) {
      setState(() => _isRestoring = false);
    }
    final message = result.message;
    if (message != null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _isRestoring ? null : _restore,
        icon: const Icon(Icons.settings_backup_restore_rounded, size: 20),
        label: Text(
          _isRestoring ? 'RESTORING' : 'RESTORE FILES',
          style: AppTextStyles.buttonText.copyWith(
            color: AppColors.textPrimary,
          ),
        ),
      ),
    );
  }
}
