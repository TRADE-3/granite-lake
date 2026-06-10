import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';

class ScanLineOverlay extends StatefulWidget {
  const ScanLineOverlay({super.key});

  @override
  State<ScanLineOverlay> createState() => _ScanLineOverlayState();
}

class _ScanLineOverlayState extends State<ScanLineOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 5600),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final screenHeight = MediaQuery.sizeOf(context).height;
        final top = _controller.value * screenHeight;

        return IgnorePointer(
          child: Stack(
            children: [
              Positioned(
                top: top,
                left: 0,
                right: 0,
                child: Opacity(
                  opacity: 0.2,
                  child: Container(height: 1, color: AppColors.primary),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
