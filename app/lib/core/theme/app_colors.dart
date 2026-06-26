import 'package:flutter/material.dart';

import '../state/granite_lake_controller.dart';

abstract final class AppColorsDark {
  static const Color actionFill = Color(0xFFC2C8FF);
  static const Color actionText = Color(0xFF1F3E99);
  static const Color background = Color(0xFF0A0A0A);
  static const Color surface = Color(0xFF141414);
  static const Color surfaceElevated = Color(0xFF1E1E1E);
  static const Color surfaceOverlay = Color(0xFF252525);
  static const Color border = Color(0xFF2A2A2A);
  static const Color borderActive = Color(0xFF3A3A3A);
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFF8A8A8A);
  static const Color textMuted = Color(0xFF4A4A4A);
  static const Color textSuccess = Color(0xFF00C853);
  static const Color textWarning = Color(0xFFC34100);
  static const Color statusActive = Color(0xFF00C853);
  static const Color statusEncrypt = Color(0xFF2E5BFF);
  static const Color statusError = Color(0xFFFF3B3B);
  static const Color scrim = Color(0xCC0A0A0A);
}

abstract final class AppColorsLight {
  static const Color actionFill = Color(0xFF2E5BFF);
  static const Color actionText = Color(0xFFFFFFFF);
  static const Color background = Color(0xFFFAFAFA);
  static const Color surface = Color(0xFFF5F5F5);
  static const Color surfaceElevated = Color(0xFFFFFFFF);
  static const Color surfaceOverlay = Color(0xFFF0F0F0);
  static const Color border = Color(0xFFE0E0E0);
  static const Color borderActive = Color(0xFFCCCCCC);
  static const Color textPrimary = Color(0xFF1F1F1F);
  static const Color textSecondary = Color(0xFF616161);
  static const Color textMuted = Color(0xFF9E9E9E);
  static const Color textSuccess = Color(0xFF00C853);
  static const Color textWarning = Color(0xFFC34100);
  static const Color statusActive = Color(0xFF00C853);
  static const Color statusEncrypt = Color(0xFF2E5BFF);
  static const Color statusError = Color(0xFFFF3B3B);
  static const Color scrim = Color(0xCC1F1F1F);
}

abstract final class AppColors {
  // Brand palette
  static const Color primary = Color(0xFF2E5BFF);
  static const Color primaryDim = Color(0xFF1A3BCC);
  static const Color secondary = Color(0xFF00C853);
  static const Color tertiary = Color(0xFFC34100);

  static bool get _isDarkMode =>
      GraniteLakeController.current?.isDarkMode ?? false;

  static Color get actionFill =>
      _isDarkMode ? AppColorsDark.actionFill : AppColorsLight.actionFill;
  static Color get actionText =>
      _isDarkMode ? AppColorsDark.actionText : AppColorsLight.actionText;
  static Color get background =>
      _isDarkMode ? AppColorsDark.background : AppColorsLight.background;
  static Color get surface =>
      _isDarkMode ? AppColorsDark.surface : AppColorsLight.surface;
  static Color get surfaceElevated => _isDarkMode
      ? AppColorsDark.surfaceElevated
      : AppColorsLight.surfaceElevated;
  static Color get surfaceOverlay => _isDarkMode
      ? AppColorsDark.surfaceOverlay
      : AppColorsLight.surfaceOverlay;
  static Color get border =>
      _isDarkMode ? AppColorsDark.border : AppColorsLight.border;
  static Color get borderActive =>
      _isDarkMode ? AppColorsDark.borderActive : AppColorsLight.borderActive;
  static Color get textPrimary =>
      _isDarkMode ? AppColorsDark.textPrimary : AppColorsLight.textPrimary;
  static Color get textSecondary =>
      _isDarkMode ? AppColorsDark.textSecondary : AppColorsLight.textSecondary;
  static Color get textMuted =>
      _isDarkMode ? AppColorsDark.textMuted : AppColorsLight.textMuted;
  static Color get textSuccess =>
      _isDarkMode ? AppColorsDark.textSuccess : AppColorsLight.textSuccess;
  static Color get textWarning =>
      _isDarkMode ? AppColorsDark.textWarning : AppColorsLight.textWarning;
  static Color get statusActive =>
      _isDarkMode ? AppColorsDark.statusActive : AppColorsLight.statusActive;
  static Color get statusEncrypt =>
      _isDarkMode ? AppColorsDark.statusEncrypt : AppColorsLight.statusEncrypt;
  static Color get statusError =>
      _isDarkMode ? AppColorsDark.statusError : AppColorsLight.statusError;
  static Color get scrim =>
      _isDarkMode ? AppColorsDark.scrim : AppColorsLight.scrim;
}
