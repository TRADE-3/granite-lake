import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';

final class AppTheme {
  const AppTheme._();

  static ThemeData get dark {
    return _buildTheme(
      brightness: Brightness.dark,
      backgroundColor: AppColorsDark.background,
      actionFill: AppColorsDark.actionFill,
      actionText: AppColorsDark.actionText,
      surfaceElevated: AppColorsDark.surfaceElevated,
      surface: AppColorsDark.surface,
      border: AppColorsDark.border,
      textPrimary: AppColorsDark.textPrimary,
      textMuted: AppColorsDark.textMuted,
      statusBarBrightness: Brightness.light,
    );
  }

  static ThemeData get light {
    return _buildTheme(
      brightness: Brightness.light,
      backgroundColor: AppColorsLight.background,
      actionFill: AppColorsLight.actionFill,
      actionText: AppColorsLight.actionText,
      surfaceElevated: AppColorsLight.surfaceElevated,
      surface: AppColorsLight.surface,
      border: AppColorsLight.border,
      textPrimary: AppColorsLight.textPrimary,
      textMuted: AppColorsLight.textMuted,
      statusBarBrightness: Brightness.dark,
    );
  }

  static ThemeData _buildTheme({
    required Brightness brightness,
    required Color backgroundColor,
    required Color actionFill,
    required Color actionText,
    required Color surfaceElevated,
    required Color surface,
    required Color border,
    required Color textPrimary,
    required Color textMuted,
    required Brightness statusBarBrightness,
  }) {
    final isDark = brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: backgroundColor,
      colorScheme: brightness == Brightness.dark
          ? ColorScheme.dark(
              brightness: brightness,
              primary: AppColors.primary,
              onPrimary: textPrimary,
              secondary: AppColors.secondary,
              onSecondary: backgroundColor,
              tertiary: AppColors.tertiary,
              onTertiary: textPrimary,
              surface: surface,
              onSurface: textPrimary,
              error: AppColors.statusError,
              onError: textPrimary,
              outline: border,
            )
          : ColorScheme.light(
              brightness: brightness,
              primary: AppColors.primary,
              onPrimary: actionText,
              secondary: AppColors.secondary,
              onSecondary: backgroundColor,
              tertiary: AppColors.tertiary,
              onTertiary: textPrimary,
              surface: surface,
              onSurface: textPrimary,
              error: AppColors.statusError,
              onError: textPrimary,
              outline: border,
            ),
      textTheme: GoogleFonts.interTextTheme(
        isDark ? ThemeData.dark().textTheme : ThemeData.light().textTheme,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: backgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: actionFill,
          foregroundColor: actionText,
          minimumSize: const Size(double.infinity, 52),
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          elevation: 0,
          shadowColor: Colors.transparent,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: actionFill,
        foregroundColor: actionText,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          minimumSize: const Size(double.infinity, 52),
          side: BorderSide(color: border),
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceElevated,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: AppColors.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: AppColors.statusError),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: AppColors.statusError, width: 1.5),
        ),
        hintStyle: GoogleFonts.jetBrainsMono(
          fontSize: 13,
          color: textMuted,
          letterSpacing: 0.8,
        ),
        labelStyle: GoogleFonts.jetBrainsMono(
          fontSize: 11,
          color: textMuted,
          letterSpacing: 0.6,
        ),
      ),
      dividerTheme: DividerThemeData(color: border, thickness: 0.5),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaceElevated,
        contentTextStyle: GoogleFonts.jetBrainsMono(
          fontSize: 12,
          color: textPrimary,
        ),
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      ),
    );
  }
}
