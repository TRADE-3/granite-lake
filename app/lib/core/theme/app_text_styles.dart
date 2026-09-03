import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';

/// Trade3 type system: Raleway for display/headings, Karla for body/labels.
/// See Work/T3/design.md section 3.
abstract final class AppTextStyles {
  // ── Display / Headline (Raleway) ────────────────────────────────────────
  static TextStyle get displayLarge => GoogleFonts.raleway(
    fontSize: 32,
    fontWeight: FontWeight.w800,
    letterSpacing: 0.5,
    color: AppColors.textPrimary,
  );

  static TextStyle get displayMedium => GoogleFonts.raleway(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.5,
    color: AppColors.textPrimary,
  );

  static TextStyle get headlineLarge => GoogleFonts.raleway(
    fontSize: 24,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.3,
    color: AppColors.textPrimary,
  );

  static TextStyle get headlineMedium => GoogleFonts.raleway(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );

  // ── Body (Karla) ─────────────────────────────────────────────────────────
  static TextStyle get bodyLarge => GoogleFonts.karla(
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 1.6,
    color: AppColors.textSecondary,
  );

  static TextStyle get bodyMedium => GoogleFonts.karla(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.5,
    color: AppColors.textSecondary,
  );

  static TextStyle get bodySmall => GoogleFonts.karla(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: AppColors.textMuted,
  );

  // ── Label (Karla) ────────────────────────────────────────────────────────
  static TextStyle get labelLarge => GoogleFonts.karla(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.4,
    color: AppColors.textPrimary,
  );

  static TextStyle get labelMedium => GoogleFonts.karla(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.3,
    color: AppColors.textSecondary,
  );

  static TextStyle get labelSmall => GoogleFonts.karla(
    fontSize: 10,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.3,
    color: AppColors.textMuted,
  );

  // ── Button (Karla) ───────────────────────────────────────────────────────
  static TextStyle get buttonText => GoogleFonts.karla(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
    color: AppColors.actionText,
  );

  // ── HUD / Status (Mono — technical readouts, per design.md's mono role) ──
  static TextStyle get hudLabel => GoogleFonts.jetBrainsMono(
    fontSize: 9,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.8,
    color: AppColors.textMuted,
  );

  static TextStyle get hudValue => GoogleFonts.jetBrainsMono(
    fontSize: 9,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.8,
    color: AppColors.textSecondary,
  );
}
