import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app.dart';
import '../../../core/services/trade3_api_service.dart';
import '../../../core/state/granite_lake_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';

/// Inline control shown in the capture flows (photo + file) while a Trade3
/// account is linked. The chosen payment schedule *is* the capture's project:
/// this displays the sticky selection and opens the cascading picker.
class Trade3TargetField extends StatelessWidget {
  const Trade3TargetField({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = GraniteLakeScope.of(context);
    final target = controller.selectedTrade3Target;

    return InkWell(
      onTap: controller.canSelectTrade3Target
          ? () => unawaited(showTrade3TargetPicker(context, controller))
          : null,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: target == null
                ? AppColors.borderActive
                : AppColors.statusActive.withAlpha(120),
          ),
        ),
        child: Row(
          children: [
            Icon(
              target == null
                  ? Icons.account_tree_outlined
                  : Icons.push_pin_outlined,
              size: 20,
              color: target == null
                  ? AppColors.textSecondary
                  : AppColors.statusActive,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    target == null
                        ? 'Select Trade3 payment schedule'
                        : 'Trade3 project',
                    style: AppTextStyles.labelSmall.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    !controller.canSelectTrade3Target
                        ? GraniteLakeController.depositRightsMessage
                        : target?.displayLabel ?? 'Required to capture',
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: target == null
                          ? AppColors.textMuted
                          : AppColors.textPrimary,
                    ),
                    maxLines: controller.canSelectTrade3Target ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// Cascading Master Contract → Transaction → Payment Schedule picker.
/// Completed schedules stay selectable (shown muted, with their status).
Future<void> showTrade3TargetPicker(
  BuildContext context,
  GraniteLakeController controller,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surfaceElevated,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) => const _Trade3TargetPickerSheet(),
  );
}

class _Trade3TargetPickerSheet extends StatefulWidget {
  const _Trade3TargetPickerSheet();

  @override
  State<_Trade3TargetPickerSheet> createState() =>
      _Trade3TargetPickerSheetState();
}

class _Trade3TargetPickerSheetState extends State<_Trade3TargetPickerSheet> {
  Trade3MasterContract? _masterContract;
  Trade3Transaction? _transaction;

  @override
  void initState() {
    super.initState();
    // Inherited lookups must not run synchronously in initState.
    unawaited(
      Future.microtask(() {
        if (!mounted) {
          return;
        }
        final controller = GraniteLakeScope.of(context);
        if (controller.trade3Hierarchy == null && controller.isTrade3Paired) {
          unawaited(controller.syncTrade3Hierarchy());
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = GraniteLakeScope.of(context);
    final hierarchy = controller.trade3Hierarchy;
    final masterContract = _masterContract;
    final transaction = _transaction;
    final syncing = controller.isSyncingTrade3Hierarchy;

    final title = transaction != null
        ? '${masterContract?.title} › ${transaction.title}'
        : masterContract != null
        ? masterContract.title
        : 'Master Contracts';

    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (sheetContext, scrollController) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'SELECT PROJECT · TRADE3',
                          style: AppTextStyles.labelSmall.copyWith(
                            color: AppColors.textSecondary,
                            letterSpacing: 1.1,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          title,
                          style: AppTextStyles.headlineMedium.copyWith(
                            fontSize: 18,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (masterContract != null)
                    IconButton(
                      // One level up: schedules → transactions → contracts.
                      onPressed: () => setState(() {
                        if (_transaction != null) {
                          _transaction = null;
                        } else {
                          _masterContract = null;
                        }
                      }),
                      icon: const Icon(Icons.arrow_upward_rounded, size: 20),
                      color: AppColors.textSecondary,
                      tooltip: 'Back',
                    ),
                  IconButton(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    icon: const Icon(Icons.close_rounded, size: 20),
                    color: AppColors.textSecondary,
                    tooltip: 'Close',
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: AppColors.border),
            Expanded(
              child: syncing && (hierarchy == null || hierarchy.isEmpty)
                  ? const Center(
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : (hierarchy == null || hierarchy.isEmpty)
                  ? _SyncPrompt(controller: controller)
                  : ListView(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
                      children: [
                        if (transaction != null)
                          for (final schedule in transaction.paymentSchedules)
                            _PaymentScheduleTile(
                              schedule: schedule,
                              isSelected:
                                  controller
                                          .selectedTrade3Target
                                          ?.paymentScheduleId ==
                                      schedule.id &&
                                  controller
                                          .selectedTrade3Target
                                          ?.transactionId ==
                                      transaction.id &&
                                  controller
                                          .selectedTrade3Target
                                          ?.masterContractId ==
                                      masterContract!.id,
                              onTap: () => _select(
                                sheetContext,
                                controller,
                                masterContract!,
                                transaction,
                                schedule,
                              ),
                            )
                        else if (masterContract != null)
                          for (final item in masterContract.transactions)
                            _PickerListTile(
                              icon: Icons.swap_horiz_rounded,
                              title: item.title,
                              subtitle:
                                  '${item.paymentSchedules.length} payment schedules',
                              status: item.status,
                              onTap: () => setState(() => _transaction = item),
                            )
                        else
                          for (final item in hierarchy)
                            _PickerListTile(
                              icon: Icons.folder_outlined,
                              title: item.title,
                              subtitle: item.reference.isEmpty
                                  ? '${item.transactions.length} transactions'
                                  : item.reference,
                              status: item.status,
                              onTap: () =>
                                  setState(() => _masterContract = item),
                            ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _select(
    BuildContext sheetContext,
    GraniteLakeController controller,
    Trade3MasterContract masterContract,
    Trade3Transaction transaction,
    Trade3PaymentSchedule schedule,
  ) async {
    await controller.selectTrade3Target(
      Trade3TargetSelection(
        masterContractId: masterContract.id,
        masterContractTitle: masterContract.title,
        transactionId: transaction.id,
        transactionTitle: transaction.title,
        paymentScheduleId: schedule.id,
        paymentScheduleTitle: schedule.title,
      ),
    );
    if (sheetContext.mounted) {
      Navigator.of(sheetContext).pop();
    }
  }
}

class _PaymentScheduleTile extends StatelessWidget {
  const _PaymentScheduleTile({
    required this.schedule,
    required this.isSelected,
    required this.onTap,
  });

  final Trade3PaymentSchedule schedule;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Completed schedules read muted but remain selectable.
    final isCompleted = schedule.status.toUpperCase() == 'COMPLETED';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
                  ? AppColors.statusActive
                  : isCompleted
                  ? AppColors.border
                  : AppColors.borderActive,
            ),
          ),
          child: Row(
            children: [
              Icon(
                isSelected
                    ? Icons.radio_button_checked_rounded
                    : isCompleted
                    ? Icons.task_alt_rounded
                    : Icons.schedule_rounded,
                size: 18,
                color: isSelected
                    ? AppColors.statusActive
                    : isCompleted
                    ? AppColors.textMuted
                    : AppColors.statusActive,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  schedule.title,
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: isCompleted
                        ? AppColors.textMuted
                        : AppColors.textPrimary,
                  ),
                ),
              ),
              Text(
                schedule.status.toUpperCase(),
                style: AppTextStyles.labelSmall.copyWith(
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PickerListTile extends StatelessWidget {
  const _PickerListTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.status,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.borderActive),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: AppColors.textSecondary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AppTextStyles.bodyMedium.copyWith(
                        color: AppColors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: AppTextStyles.labelSmall.copyWith(
                        color: AppColors.textMuted,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (status.isNotEmpty)
                Text(
                  status.toUpperCase(),
                  style: AppTextStyles.labelSmall.copyWith(
                    color: AppColors.textMuted,
                  ),
                ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: AppColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SyncPrompt extends StatelessWidget {
  const _SyncPrompt({required this.controller});

  final GraniteLakeController controller;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 30,
              color: AppColors.textMuted,
            ),
            const SizedBox(height: 14),
            Text(
              'No Trade3 projects loaded',
              style: AppTextStyles.headlineMedium.copyWith(fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              'Sync your Trade3 projects, or check your connection and permissions.',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.tonalIcon(
              onPressed: () => unawaited(controller.syncTrade3Hierarchy()),
              icon: const Icon(Icons.sync_rounded, size: 16),
              label: Text('SYNC NOW', style: AppTextStyles.buttonText),
            ),
          ],
        ),
      ),
    );
  }
}
