import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';

abstract final class AppTextStyles {
  // ── Headline (Inter) ──────────────────────────────────────────────────────
  static TextStyle get displayLarge => GoogleFonts.inter(
    fontSize: 32,
    fontWeight: FontWeight.w800,
    letterSpacing: 0.5,
    color: AppColors.textPrimary,
  );

  static TextStyle get displayMedium => GoogleFonts.inter(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.5,
    color: AppColors.textPrimary,
  );

  static TextStyle get headlineLarge => GoogleFonts.inter(
    fontSize: 24,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.3,
    color: AppColors.textPrimary,
  );

  static TextStyle get headlineMedium => GoogleFonts.inter(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );

  // ── Body (Inter) ──────────────────────────────────────────────────────────
  static TextStyle get bodyLarge => GoogleFonts.inter(
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 1.6,
    color: AppColors.textSecondary,
  );

  static TextStyle get bodyMedium => GoogleFonts.inter(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.5,
    color: AppColors.textSecondary,
  );

  static TextStyle get bodySmall => GoogleFonts.inter(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: AppColors.textMuted,
  );

  // ── Label / Monospace (JetBrains Mono) ────────────────────────────────────
  static TextStyle get labelLarge => GoogleFonts.jetBrainsMono(
    fontSize: 13,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.8,
    color: AppColors.textPrimary,
  );

  static TextStyle get labelMedium => GoogleFonts.jetBrainsMono(
    fontSize: 11,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.6,
    color: AppColors.textSecondary,
  );

  static TextStyle get labelSmall => GoogleFonts.jetBrainsMono(
    fontSize: 10,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.5,
    color: AppColors.textMuted,
  );

  // ── Button ─────────────────────────────────────────────────────────────────
  static TextStyle get buttonText => GoogleFonts.jetBrainsMono(
    fontSize: 12,
    fontWeight: FontWeight.w700,
    letterSpacing: 2.0,
    color: AppColors.actionText,
  );

  // ── HUD / Status (JetBrains Mono) ─────────────────────────────────────────
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
