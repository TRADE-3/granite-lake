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

  /// Trade3 type pairing: Raleway for display/headline/title, Karla for
  /// body/label. See Work/T3/design.md section 3.
  static TextTheme _buildTextTheme(bool isDark) {
    final base = isDark
        ? ThemeData.dark().textTheme
        : ThemeData.light().textTheme;
    return GoogleFonts.karlaTextTheme(base).copyWith(
      displayLarge: GoogleFonts.raleway(
        textStyle: base.displayLarge,
        fontWeight: FontWeight.w800,
      ),
      displayMedium: GoogleFonts.raleway(
        textStyle: base.displayMedium,
        fontWeight: FontWeight.w800,
      ),
      displaySmall: GoogleFonts.raleway(
        textStyle: base.displaySmall,
        fontWeight: FontWeight.w700,
      ),
      headlineLarge: GoogleFonts.raleway(
        textStyle: base.headlineLarge,
        fontWeight: FontWeight.w700,
      ),
      headlineMedium: GoogleFonts.raleway(
        textStyle: base.headlineMedium,
        fontWeight: FontWeight.w600,
      ),
      headlineSmall: GoogleFonts.raleway(
        textStyle: base.headlineSmall,
        fontWeight: FontWeight.w600,
      ),
      titleLarge: GoogleFonts.raleway(
        textStyle: base.titleLarge,
        fontWeight: FontWeight.w600,
      ),
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
      textTheme: _buildTextTheme(isDark),
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8), // radius-md
          ),
          elevation: 0,
          shadowColor: Colors.transparent,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: actionFill,
        foregroundColor: actionText,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)), // radius-lg
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          minimumSize: const Size(double.infinity, 52),
          side: BorderSide(color: border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8), // radius-md
          ),
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
          borderRadius: BorderRadius.circular(8), // radius-md
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.statusError),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.statusError, width: 1.5),
        ),
        hintStyle: GoogleFonts.karla(fontSize: 14, color: textMuted),
        labelStyle: GoogleFonts.karla(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: textMuted,
        ),
      ),
      dividerTheme: DividerThemeData(color: border, thickness: 0.5),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaceElevated,
        contentTextStyle: GoogleFonts.karla(
          fontSize: 13,
          fontWeight: FontWeight.w400,
          color: textPrimary,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8), // radius-md
        ),
      ),
    );
  }
}
