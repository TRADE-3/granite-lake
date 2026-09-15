import 'package:flutter/material.dart';

import '../state/granite_lake_controller.dart';

/// Trade3 brand palette. See Work/T3/design.md for the source design system.
abstract final class AppColorsDark {
  static const Color actionFill = Color(0xFF3B128D); // violet-500
  static const Color actionText = Color(0xFFFFFFFF);
  static const Color background = Color(0xFF060430); // navy-500
  static const Color surface = Color(0xFF10093A); // bg-tertiary (dark)
  static const Color surfaceElevated = Color(0xFF0B0840); // bg-secondary (dark)
  static const Color surfaceOverlay = Color(0xFF0F0430); // violet-900
  static const Color border = Color(0xFF1A1660); // border-default (dark)
  static const Color borderActive = Color(0xFF260A62); // violet-700
  static const Color textPrimary = Color(0xFFEEEDF8);
  static const Color textSecondary = Color(0xFF9997C5);
  static const Color textMuted = Color(0xFF5D5A8A);
  static const Color textSuccess = Color(0xFF34D399);
  static const Color textWarning = Color(0xFFFB6E4C); // orange-400
  static const Color statusActive = Color(0xFF34D399);
  static const Color statusEncrypt = Color(0xFF8F61D9); // violet-300
  static const Color statusError = Color(0xFFF87171);
  static const Color scrim = Color(0xCC060430);
}

abstract final class AppColorsLight {
  static const Color actionFill = Color(0xFF3B128D); // violet-500
  static const Color actionText = Color(0xFFFFFFFF);
  static const Color background = Color(0xFFFDF5EF); // cream-100
  static const Color surface = Color(0xFFFAE9DA); // cream-200 (bg-tertiary)
  static const Color surfaceElevated = Color(0xFFFFFFFF); // bg-secondary
  static const Color surfaceOverlay = Color(0xFFF0EAFA); // violet-50
  static const Color border = Color(0xFFF5D7BF); // cream-300 (border-default)
  static const Color borderActive = Color(0xFFB898E9); // violet-200
  static const Color textPrimary = Color(0xFF060430); // navy-500
  static const Color textSecondary = Color(0xFF4A4870);
  static const Color textMuted = Color(0xFF8885AA);
  static const Color textSuccess = Color(0xFF059669);
  static const Color textWarning = Color(0xFFAE2D10); // orange-700
  static const Color statusActive = Color(0xFF059669);
  static const Color statusEncrypt = Color(0xFF3B128D); // violet-500
  static const Color statusError = Color(0xFF991B1B);
  static const Color scrim = Color(0xCC060430);
}

abstract final class AppColors {
  // Brand palette
  static const Color primary = Color(0xFF3B128D); // violet-500
  static const Color primaryDim = Color(0xFF310E7A); // violet-600
  static const Color secondary = Color(0xFFF75835); // orange-500 (accent)
  static const Color tertiary = Color(0xFFD43E1D); // orange-600

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
