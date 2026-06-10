import 'package:flutter/material.dart';

import '../../../app.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';

class LocalDataInitScreen extends StatefulWidget {
  const LocalDataInitScreen({super.key});

  @override
  State<LocalDataInitScreen> createState() => _LocalDataInitScreenState();
}

class _LocalDataInitScreenState extends State<LocalDataInitScreen> {
  bool _isRunning = false;
  bool _hasTriggered = false;
  String? _errorMessage;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_hasTriggered) {
      return;
    }

    _hasTriggered = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _runInitialization();
      }
    });
  }

  Future<void> _runInitialization() async {
    if (_isRunning) {
      return;
    }

    setState(() {
      _isRunning = true;
      _errorMessage = null;
    });

    final controller = GraniteLakeScope.of(context);
    final result = await controller.initializeLocalData();

    if (!mounted) {
      return;
    }

    setState(() {
      _isRunning = false;
      _errorMessage = result.isSuccess ? null : result.message;
    });
  }

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
                  width: 44,
                  height: 44,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Preparing Your App',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.displayMedium.copyWith(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _errorMessage ??
                      'We are getting this device ready for secure capture and account setup.',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: AppColors.textSecondary,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 24),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: _isRunning ? null : _runInitialization,
                    child: Text(
                      _isRunning ? 'TRYING AGAIN' : 'TRY AGAIN',
                      style: AppTextStyles.buttonText,
                    ),
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
