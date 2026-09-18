import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../app.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/router/app_router.dart';
import '../../../core/state/granite_lake_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _isDeletingAccount = false;

  @override
  void initState() {
    super.initState();
    // Deferred to a microtask: GraniteLakeScope.of(context) is an
    // inherited-widget lookup that Flutter forbids calling synchronously
    // before initState() returns.
    unawaited(Future.microtask(_refreshWalletBalance));
  }

  Future<void> _refreshWalletBalance() async {
    if (!mounted) {
      return;
    }
    await GraniteLakeScope.of(context).refreshWalletSuiBalance();
  }

  @override
  Widget build(BuildContext context) {
    final controller = GraniteLakeScope.of(context);
    final employee = controller.employee;
    final identity = controller.identity;
    final binding = controller.biometricBinding;
    final deviceRegistration = controller.deviceRegistration;
    final session = controller.session;
    final isSessionActive = controller.hasActiveSession;
    final employeeId = employee?.employeeId ?? _employeeId(identity);
    final createdAt = identity == null
        ? 'Pending provisioning'
        : _formatDateTime(identity.createdAt);
    final boundAt = binding == null
        ? 'Not bound to this device'
        : _formatDateTime(binding.boundAt);
    final deviceModel =
        deviceRegistration?.displayModel ?? 'Device model unavailable';
    final platformLabel =
        deviceRegistration?.platformLabel ?? 'Awaiting device registration';
    final registeredDeviceAt = deviceRegistration == null
        ? 'Pending registration'
        : _formatDateTime(deviceRegistration.registeredAt);
    final operatorName = employee?.fullName ?? _operatorName;
    final operatorRole = employee?.role ?? _operatorRole;
    final tenantName = employee?.tenantName ?? _tenantName;
    final operatorInitials = employee?.initials ?? _operatorInitials;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'PROFILE & IDENTITY BINDING',
            style: AppTextStyles.labelMedium.copyWith(
              color: AppColors.textMuted,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Profile',
            style: AppTextStyles.displayMedium.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 20),
          _ProfileHeaderCard(
            initials: operatorInitials,
            isVerified: identity != null && binding != null,
            employeeId: employeeId,
            operatorName: operatorName,
            operatorRole: operatorRole,
            tenantName: tenantName,
            walletAddress: identity?.walletAddress ?? 'Wallet not provisioned',
            createdAt: createdAt,
            biometricLabel:
                binding?.modalitiesLabel ?? 'Awaiting biometric bind',
          ),
          const SizedBox(height: 22),
          const _SectionLabel('Wallet Balance'),
          const SizedBox(height: 10),
          _Panel(
            child: _WalletBalanceTile(
              suiBalance: controller.walletSuiBalanceSui,
              isRefreshing: controller.isRefreshingWalletSuiBalance,
              hasEnoughForAttestation: controller.hasEnoughSuiForAttestation,
              hasWallet: identity != null,
              onRefresh: () => controller.refreshWalletSuiBalance(force: true),
            ),
          ),
          const SizedBox(height: 22),
          const _SectionLabel('Session Protocol'),
          const SizedBox(height: 10),
          _Panel(
            child: Column(
              children: [
                _ProtocolTile(
                  icon: Icons.timer_outlined,
                  title: 'Session Limit',
                  subtitle: isSessionActive
                      ? '${_formatRemainingSession(controller.remainingSessionDuration)} remaining before secure lock'
                      : '${AppConstants.captureSessionDurationMinutes}m inactivity timeout',
                ),
                Divider(height: 1, color: AppColors.border),
                _ProtocolTile(
                  icon: Icons.lock_clock_outlined,
                  title: 'Auto-Lock',
                  subtitle: isSessionActive
                      ? 'Secure session expires at ${_formatTime(session?.expiresAt)}'
                      : 'Biometric unlock required to reactivate capture',
                  trailing: _StatusPill(
                    label: isSessionActive ? 'ENFORCED' : 'IDLE',
                    color: isSessionActive
                        ? AppColors.statusEncrypt
                        : AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          const _SectionLabel('Appearance'),
          const SizedBox(height: 10),
          _Panel(
            child: _ThemePreferenceTile(
              isDarkMode: controller.isDarkMode,
              onToggle: controller.toggleTheme,
            ),
          ),
          const SizedBox(height: 22),
          const _SectionLabel('Hardware Attestation'),
          const SizedBox(height: 10),
          _Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: AppColors.statusActive.withAlpha(18),
                      ),
                      child: Icon(
                        Icons.smartphone_rounded,
                        color: AppColors.statusActive,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Device Model',
                            style: AppTextStyles.bodyLarge.copyWith(
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            deviceModel,
                            style: AppTextStyles.labelLarge.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _StatusPill(
                      label: binding != null ? 'BOUND' : 'PENDING',
                      color: binding != null
                          ? AppColors.statusActive
                          : AppColors.textSecondary,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Divider(height: 1, color: AppColors.border),
                const SizedBox(height: 16),
                _DataBlock(
                  label: 'Public Key Fingerprint',
                  value:
                      identity?.publicKeyHex.toUpperCase() ??
                      'Public key unavailable until identity is created.',
                  canCopy: identity != null,
                  copyValue: identity?.publicKeyHex,
                ),
                const SizedBox(height: 12),
                _KeyValueGrid(
                  items: [
                    _KeyValueItem(label: 'Identity Created', value: createdAt),
                    _KeyValueItem(label: 'Biometric Bound', value: boundAt),
                    _KeyValueItem(label: 'Device OS', value: platformLabel),
                    _KeyValueItem(
                      label: 'Registered On',
                      value: registeredDeviceAt,
                    ),
                    _KeyValueItem(
                      label: 'Projects',
                      value: controller.projects.isEmpty
                          ? 'No linked projects'
                          : '${controller.projects.length} assigned',
                    ),
                    _KeyValueItem(
                      label: 'Capture History',
                      value: controller.attestationHistory.isEmpty
                          ? 'No verified captures'
                          : '${controller.attestationHistory.length} records stored',
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          _DangerZoneCard(
            isDeleting: _isDeletingAccount,
            pendingCount: controller.pendingAttestationCount,
            onDelete: () => _confirmDeleteAccount(controller),
          ),
          const SizedBox(height: 14),
          Center(
            child: Text(
              _buildLabel,
              textAlign: TextAlign.center,
              style: AppTextStyles.hudValue.copyWith(
                color: AppColors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteAccount(GraniteLakeController controller) async {
    // Defensive re-check: the button itself is disabled while any
    // submission is pending (see _DangerZoneCard), but this guards the
    // actual deletion regardless of how it's triggered - resetApplicationState
    // wipes local capture history unconditionally, and a pending row is
    // evidence that was captured but never actually anchored on-chain yet,
    // so it must never be silently discarded.
    if (controller.pendingAttestationCount > 0) {
      return;
    }

    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: AppColors.surfaceElevated,
          title: Row(
            children: [
              Icon(Icons.warning_rounded, color: AppColors.statusError),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Delete account?',
                  style: AppTextStyles.headlineMedium,
                ),
              ),
            ],
          ),
          content: Text(
            'This removes registration, identity keys, biometric binding, secure session state, projects, and local capture history from this device.',
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textSecondary,
              height: 1.5,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(
                'CANCEL',
                style: AppTextStyles.buttonText.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(
                'DELETE',
                style: AppTextStyles.buttonText.copyWith(
                  color: AppColors.statusError,
                ),
              ),
            ),
          ],
        );
      },
    );

    if (shouldDelete != true || !mounted) {
      return;
    }

    setState(() => _isDeletingAccount = true);
    await controller.deleteAccount();
    if (!mounted) {
      return;
    }
    setState(() => _isDeletingAccount = false);
    GoRouter.of(context).go(AppRoutes.welcome);
  }
}

/// A "danger zone" treatment for account deletion - set apart from the rest
/// of the profile with its own tinted card, warning header, and filled
/// (rather than plain outlined) button, so the destructive action reads with
/// appropriate visual weight instead of blending in as just another row.
/// Also the one place that enforces "no pending submissions" - blocking the
/// button and explaining why, rather than letting the crew tap it and get an
/// unexplained rejection.
class _DangerZoneCard extends StatelessWidget {
  const _DangerZoneCard({
    required this.isDeleting,
    required this.pendingCount,
    required this.onDelete,
  });

  final bool isDeleting;
  final int pendingCount;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final isBlocked = pendingCount > 0;
    final contentColor = (isDeleting || isBlocked)
        ? AppColors.textMuted
        : AppColors.actionText;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.statusError.withAlpha(16),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.statusError.withAlpha(70)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.statusError.withAlpha(28),
                ),
                child: Icon(
                  Icons.warning_rounded,
                  size: 18,
                  color: AppColors.statusError,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'DANGER ZONE',
                style: AppTextStyles.labelMedium.copyWith(
                  color: AppColors.statusError,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Deleting your account permanently removes your identity keys, biometric binding, and local capture history from this device. This cannot be undone.',
            style: AppTextStyles.bodySmall.copyWith(
              color: AppColors.textSecondary,
              height: 1.5,
            ),
          ),
          if (isBlocked) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.borderActive),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.hourglass_top_rounded,
                    size: 16,
                    color: AppColors.textWarning,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      pendingCount == 1
                          ? '1 capture is still pending submission. Submit or resolve it before deleting your account, so it isn\'t lost.'
                          : '$pendingCount captures are still pending submission. Submit or resolve them before deleting your account, so they aren\'t lost.',
                      style: AppTextStyles.bodySmall.copyWith(
                        color: AppColors.textWarning,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: (isDeleting || isBlocked) ? null : onDelete,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.statusError,
                disabledBackgroundColor: AppColors.statusError.withAlpha(40),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
              icon: isDeleting
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: contentColor,
                      ),
                    )
                  : Icon(
                      isBlocked
                          ? Icons.lock_outline_rounded
                          : Icons.delete_forever_rounded,
                      color: contentColor,
                    ),
              label: Text(
                isDeleting
                    ? 'DELETING ACCOUNT'
                    : isBlocked
                    ? 'RESOLVE PENDING SUBMISSIONS FIRST'
                    : 'DELETE ACCOUNT',
                style: AppTextStyles.buttonText.copyWith(color: contentColor),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileHeaderCard extends StatelessWidget {
  const _ProfileHeaderCard({
    required this.initials,
    required this.isVerified,
    required this.employeeId,
    required this.operatorName,
    required this.operatorRole,
    required this.tenantName,
    required this.walletAddress,
    required this.createdAt,
    required this.biometricLabel,
  });

  final String initials;
  final bool isVerified;
  final String employeeId;
  final String operatorName;
  final String operatorRole;
  final String tenantName;
  final String walletAddress;
  final String createdAt;
  final String biometricLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withAlpha(24),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(21),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    initials,
                    style: AppTextStyles.labelLarge.copyWith(
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'TRADE3',
                    style: AppTextStyles.labelLarge.copyWith(
                      color: AppColors.textPrimary,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                Icon(
                  isVerified
                      ? Icons.verified_rounded
                      : Icons.gpp_maybe_outlined,
                  color: const Color(0xFFC5D0FF),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: AppColors.border),
          Container(
            width: double.infinity,
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surfaceElevated,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.borderActive),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'AUTH LEVEL: ALPHA',
                            style: AppTextStyles.labelSmall.copyWith(
                              color: AppColors.textSecondary,
                              letterSpacing: 0.8,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            operatorName,
                            style: AppTextStyles.headlineLarge,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            operatorRole,
                            style: AppTextStyles.labelLarge.copyWith(
                              color: AppColors.statusActive,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.qr_code_2_rounded,
                      color: AppColors.statusActive.withAlpha(220),
                      size: 30,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Divider(height: 1, color: AppColors.border),
                const SizedBox(height: 16),
                _KeyValueGrid(
                  items: [
                    _KeyValueItem(label: 'Employee ID', value: employeeId),
                    _KeyValueItem(label: 'Tenant', value: tenantName),
                    _KeyValueItem(label: 'Identity Created', value: createdAt),
                    _KeyValueItem(label: 'Binding Mode', value: biometricLabel),
                  ],
                ),
                const SizedBox(height: 14),
                _DataBlock(
                  label: 'Wallet Address',
                  value: walletAddress,
                  canCopy: walletAddress != 'Wallet not provisioned',
                  copyValue: walletAddress != 'Wallet not provisioned'
                      ? walletAddress
                      : null,
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.statusActive.withAlpha(16),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: AppColors.statusActive.withAlpha(72),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isVerified
                              ? Icons.verified_user_rounded
                              : Icons.warning_amber_rounded,
                          color: isVerified
                              ? AppColors.statusActive
                              : const Color(0xFFFFB347),
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          isVerified
                              ? 'IDENTITY VERIFIED'
                              : 'IDENTITY INCOMPLETE',
                          style: AppTextStyles.labelMedium.copyWith(
                            color: isVerified
                                ? AppColors.statusActive
                                : const Color(0xFFFFB347),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WalletBalanceTile extends StatelessWidget {
  const _WalletBalanceTile({
    required this.suiBalance,
    required this.isRefreshing,
    required this.hasEnoughForAttestation,
    required this.hasWallet,
    required this.onRefresh,
  });

  final double? suiBalance;
  final bool isRefreshing;
  final bool hasEnoughForAttestation;
  final bool hasWallet;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final showLowBalanceWarning =
        hasWallet && suiBalance != null && !hasEnoughForAttestation;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: AppColors.statusActive.withAlpha(18),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.account_balance_wallet_outlined,
                color: AppColors.statusActive,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'SUI Balance',
                    style: AppTextStyles.headlineMedium.copyWith(fontSize: 18),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    hasWallet
                        ? _formatSuiBalance(suiBalance)
                        : 'Wallet not provisioned',
                    style: AppTextStyles.labelLarge.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (isRefreshing)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              IconButton(
                onPressed: hasWallet ? onRefresh : null,
                icon: const Icon(Icons.refresh_rounded),
                color: AppColors.textSecondary,
                tooltip: 'Refresh balance',
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
        if (showLowBalanceWarning) ...[
          const SizedBox(height: 16),
          Divider(height: 1, color: AppColors.border),
          const SizedBox(height: 16),
          Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                color: Color(0xFFFFB347),
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Balance is too low to cover attestation gas fees.',
                  style: AppTextStyles.labelLarge.copyWith(
                    color: const Color(0xFFFFB347),
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _ThemePreferenceTile extends StatelessWidget {
  const _ThemePreferenceTile({
    required this.isDarkMode,
    required this.onToggle,
  });

  final bool isDarkMode;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(
                isDarkMode ? Icons.dark_mode : Icons.light_mode,
                color: AppColors.textPrimary,
                size: 20,
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Theme',
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isDarkMode ? 'Dark mode' : 'Light mode',
                    style: AppTextStyles.labelLarge.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ],
          ),
          Switch(
            value: isDarkMode,
            onChanged: (_) => onToggle(),
            activeThumbColor: AppColors.primary,
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: AppTextStyles.labelLarge.copyWith(
        color: AppColors.textSecondary,
        letterSpacing: 1.0,
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.borderActive),
      ),
      child: child,
    );
  }
}

class _ProtocolTile extends StatelessWidget {
  const _ProtocolTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppColors.surface.withAlpha(130),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: AppColors.textSecondary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppTextStyles.headlineMedium.copyWith(fontSize: 18),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: AppTextStyles.labelLarge.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ],
      ),
    );
  }
}

class _DataBlock extends StatelessWidget {
  const _DataBlock({
    required this.label,
    required this.value,
    this.canCopy = false,
    this.copyValue,
  });

  final String label;
  final String value;
  final bool canCopy;
  final String? copyValue;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: AppTextStyles.labelSmall.copyWith(
            color: AppColors.textSecondary,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  value,
                  style: AppTextStyles.labelLarge.copyWith(
                    color: AppColors.textPrimary,
                    height: 1.5,
                  ),
                ),
              ),
              if (canCopy && copyValue != null)
                IconButton(
                  onPressed: () => _copyValue(context, label, copyValue!),
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  color: AppColors.textSecondary,
                  tooltip: 'Copy $label',
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _KeyValueGrid extends StatelessWidget {
  const _KeyValueGrid({required this.items});

  final List<_KeyValueItem> items;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 20,
      runSpacing: 16,
      children: items
          .map(
            (item) => SizedBox(
              width: 140,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.label.toUpperCase(),
                    style: AppTextStyles.labelSmall.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.value,
                    style: AppTextStyles.labelLarge.copyWith(
                      color: AppColors.textPrimary,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          )
          .toList(growable: false),
    );
  }
}

class _KeyValueItem {
  const _KeyValueItem({required this.label, required this.value});

  final String label;
  final String value;
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(110)),
      ),
      child: Text(
        label,
        style: AppTextStyles.labelMedium.copyWith(color: color),
      ),
    );
  }
}

void _copyValue(BuildContext context, String label, String value) {
  Clipboard.setData(ClipboardData(text: value));
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text('$label copied')));
}

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  final year = local.year.toString().padLeft(4, '0');
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$year-$month-$day $hour:$minute';
}

String _formatTime(DateTime? value) {
  if (value == null) {
    return '--:--';
  }

  final local = value.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

String _formatRemainingSession(Duration value) {
  final bounded = value.isNegative ? Duration.zero : value;
  final minutes = bounded.inMinutes;
  final seconds = bounded.inSeconds.remainder(60);
  return '${minutes.toString().padLeft(2, '0')}m ${seconds.toString().padLeft(2, '0')}s';
}

String _formatSuiBalance(double? sui) {
  if (sui == null) {
    return 'Fetching balance…';
  }
  return '${sui.toStringAsFixed(4)} SUI';
}

String _employeeId(IdentityRecord? identity) {
  final key = identity?.publicKeyHex.toUpperCase();
  if (key == null || key.length < 6) {
    return 'OP-UNASSIGNED';
  }

  return 'OP-${key.substring(0, 4)}${key.substring(key.length - 2)}';
}

const String _operatorName = 'John Doe';
const String _operatorRole = 'Senior Inspector';
const String _tenantName = 'Global Audit Corp';
const String _buildLabel = 'TRADE3';
const String _operatorInitials = 'JD';
