import 'package:flutter/material.dart';

import '../state/granite_lake_controller.dart';

class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({
    super.key,
    required this.controller,
    this.darkModeIcon,
    this.lightModeIcon,
    this.size,
  });

  final GraniteLakeController controller;
  final IconData? darkModeIcon;
  final IconData? lightModeIcon;
  final double? size;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return IconButton(
          icon: Icon(
            controller.isDarkMode
                ? (lightModeIcon ?? Icons.light_mode)
                : (darkModeIcon ?? Icons.dark_mode),
            size: size,
          ),
          onPressed: controller.toggleTheme,
          tooltip: controller.isDarkMode
              ? 'Switch to Light Mode'
              : 'Switch to Dark Mode',
        );
      },
    );
  }
}
