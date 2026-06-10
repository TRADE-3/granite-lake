import 'package:flutter/material.dart';

abstract final class AppColors {
  // Brand palette
  static const Color primary = Color(0xFF2E5BFF);
  static const Color primaryDim = Color(0xFF1A3BCC);
  static const Color secondary = Color(0xFF00C853);
  static const Color tertiary = Color(0xFFC34100);
  static const Color actionFill = Color(0xFFC2C8FF);
  static const Color actionText = Color(0xFF1F3E99);

  // Backgrounds
  static const Color background = Color(0xFF0A0A0A);
  static const Color surface = Color(0xFF141414);
  static const Color surfaceElevated = Color(0xFF1E1E1E);
  static const Color surfaceOverlay = Color(0xFF252525);

  // Borders
  static const Color border = Color(0xFF2A2A2A);
  static const Color borderActive = Color(0xFF3A3A3A);

  // Text
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFF8A8A8A);
  static const Color textMuted = Color(0xFF4A4A4A);
  static const Color textSuccess = Color(0xFF00C853);
  static const Color textWarning = Color(0xFFC34100);

  // Status / Semantic
  static const Color statusActive = Color(0xFF00C853);
  static const Color statusEncrypt = Color(0xFF2E5BFF);
  static const Color statusError = Color(0xFFFF3B3B);

  // Transparent overlays
  static const Color scrim = Color(0xCC0A0A0A);
}
