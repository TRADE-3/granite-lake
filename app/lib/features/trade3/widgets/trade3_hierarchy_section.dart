import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/services/trade3_api_service.dart';
import '../../../core/utils/sync_time_format.dart';
import '../../../core/state/granite_lake_controller.dart';

/// EP-03 hierarchy explorer shown in the Projects tab: the user's Trade3
/// Master Contract → Transaction → Payment Schedule tree, refreshable on
/// demand (the last sync is cached for offline use). Tapping a payment
/// schedule makes it the active project for capture.
class Trade3HierarchySection extends StatelessWidget {
  const Trade3HierarchySection({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = GraniteLakeScope.of(context);
    final hierarchy = controller.trade3Hierarchy;
    final isSyncing = controller.isSyncingTrade3Hierarchy;

    if (!controller.isTrade3Paired) {
      return const _LinkAccountCard();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'TRADE3 PROJECTS',
                style: AppTextStyles.labelMedium.copyWith(
                  color: AppColors.textSecondary,
                  letterSpacing: 1.1,
                ),
              ),
            ),
            if (controller.trade3HierarchySyncedAt != null)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(
                  'Synced ${formatSyncStamp(controller.trade3HierarchySyncedAt!)}',
                  style: AppTextStyles.labelSmall.copyWith(
                    color: AppColors.textMuted,
                  ),
                ),
              ),
            isSyncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    onPressed: () => controller
                        .syncTrade3Hierarchy(), // unawaited on purpose
                    icon: const Icon(Icons.sync_rounded, size: 20),
                    color: AppColors.textSecondary,
                    tooltip: 'Sync Trade3 projects',
                    visualDensity: VisualDensity.compact,
                  ),
          ],
        ),
        const SizedBox(height: 10),
        if (controller.trade3SyncError != null) ...[
          _SyncErrorBanner(message: controller.trade3SyncError!),
          const SizedBox(height: 10),
        ],
        if (hierarchy == null || hierarchy.isEmpty)
          _EmptyHierarchyState(isFirstSync: hierarchy == null)
        else
          ...List.generate(hierarchy.length, (index) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: index == hierarchy.length - 1 ? 0 : 10,
              ),
              child: _MasterContractCard(contract: hierarchy[index]),
            );
          }),
      ],
    );
  }
}

class _LinkAccountCard extends StatelessWidget {
  const _LinkAccountCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderActive),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppColors.statusEncrypt.withAlpha(20),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Icons.link_rounded,
              color: AppColors.statusEncrypt,
              size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Trade3 Projects',
                  style: AppTextStyles.headlineMedium.copyWith(fontSize: 16),
                ),
                const SizedBox(height: 4),
                Text(
                  'Link your Trade3 account to browse your contracts here.',
                  style: AppTextStyles.bodySmall.copyWith(
                    color: AppColors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.tonal(
            onPressed: () => GoRouter.of(context).push(AppRoutes.pair),
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            child: Text('LINK', style: AppTextStyles.buttonText),
          ),
        ],
      ),
    );
  }
}

class _SyncErrorBanner extends StatelessWidget {
  const _SyncErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.statusError.withAlpha(16),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.statusError.withAlpha(60)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 16,
            color: AppColors.statusError,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyHierarchyState extends StatelessWidget {
  const _EmptyHierarchyState({required this.isFirstSync});

  // True when no sync has ever succeeded vs. synced-but-empty — the doc's
  // permission-limited responses return 200 with empty lists, and the
  // copy differs accordingly.
  final bool isFirstSync;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Icon(
            Icons.account_tree_outlined,
            color: AppColors.textMuted,
            size: 26,
          ),
          const SizedBox(height: 12),
          Text(
            isFirstSync
                ? 'Loading your Trade3 projects…'
                : 'No Trade3 projects to show',
            style: AppTextStyles.headlineMedium.copyWith(
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (!isFirstSync) ...[
            const SizedBox(height: 6),
            Text(
              'Your account may not have contract access yet. Tap sync to check again.',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MasterContractCard extends StatefulWidget {
  const _MasterContractCard({required this.contract});

  final Trade3MasterContract contract;

  @override
  State<_MasterContractCard> createState() => _MasterContractCardState();
}

class _MasterContractCardState extends State<_MasterContractCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final contract = widget.contract;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderActive),
      ),
      child: Column(
        children: [
          _ExpandableHeader(
            title: contract.title,
            caption: contract.reference.isEmpty
                ? '${contract.transactions.length} transactions'
                : contract.reference,
            status: contract.status,
            expanded: _expanded,
            onTap: () => setState(() => _expanded = !_expanded),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                children: [
                  for (var i = 0; i < contract.transactions.length; i++)
                    _TransactionCard(
                      contract: contract,
                      transaction: contract.transactions[i],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TransactionCard extends StatefulWidget {
  const _TransactionCard({required this.contract, required this.transaction});

  final Trade3MasterContract contract;
  final Trade3Transaction transaction;

  @override
  State<_TransactionCard> createState() => _TransactionCardState();
}

class _TransactionCardState extends State<_TransactionCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final transaction = widget.transaction;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          _ExpandableHeader(
            title: transaction.title,
            caption: '${transaction.paymentSchedules.length} payment schedules',
            status: transaction.status,
            expanded: _expanded,
            dense: true,
            onTap: () => setState(() => _expanded = !_expanded),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Column(
                children: [
                  for (var i = 0; i < transaction.paymentSchedules.length; i++)
                    _PaymentScheduleTile(
                      contract: widget.contract,
                      transaction: transaction,
                      schedule: transaction.paymentSchedules[i],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PaymentScheduleTile extends StatefulWidget {
  const _PaymentScheduleTile({
    required this.contract,
    required this.transaction,
    required this.schedule,
  });

  final Trade3MasterContract contract;
  final Trade3Transaction transaction;
  final Trade3PaymentSchedule schedule;

  @override
  State<_PaymentScheduleTile> createState() => _PaymentScheduleTileState();
}

class _PaymentScheduleTileState extends State<_PaymentScheduleTile> {
  bool _expanded = false;

  Future<void> _select(
    BuildContext context,
    GraniteLakeController controller,
  ) async {
    await controller.selectTrade3Target(
      Trade3TargetSelection(
        masterContractId: widget.contract.id,
        masterContractTitle: widget.contract.title,
        transactionId: widget.transaction.id,
        transactionTitle: widget.transaction.title,
        paymentScheduleId: widget.schedule.id,
        paymentScheduleTitle: widget.schedule.title,
      ),
    );
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Active project updated')));
  }

  @override
  Widget build(BuildContext context) {
    final schedule = widget.schedule;
    final controller = GraniteLakeScope.of(context);
    final target = controller.selectedTrade3Target;
    final isSelected =
        target != null &&
        target.masterContractId == widget.contract.id &&
        target.transactionId == widget.transaction.id &&
        target.paymentScheduleId == schedule.id;
    // Completed schedules read muted but stay selectable.
    final isCompleted = schedule.status.toUpperCase() == 'COMPLETED';

    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isSelected
              ? AppColors.statusActive
              : isCompleted
              ? AppColors.border
              : AppColors.borderActive,
        ),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => _select(context, controller),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    isSelected
                        ? Icons.radio_button_checked_rounded
                        : isCompleted
                        ? Icons.task_alt_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 16,
                    color: isSelected
                        ? AppColors.statusActive
                        : isCompleted
                        ? AppColors.textMuted
                        : AppColors.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      schedule.title,
                      style: AppTextStyles.labelLarge.copyWith(
                        color: isCompleted
                            ? AppColors.textMuted
                            : AppColors.textPrimary,
                      ),
                    ),
                  ),
                  if (schedule.documents.isNotEmpty)
                    // Separate hit target so expanding the document list
                    // doesn't also select the schedule.
                    InkWell(
                      onTap: () => setState(() => _expanded = !_expanded),
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Row(
                          children: [
                            Text(
                              '${schedule.documents.length} docs',
                              style: AppTextStyles.labelSmall.copyWith(
                                color: AppColors.textMuted,
                              ),
                            ),
                            Icon(
                              _expanded
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                              size: 16,
                              color: AppColors.textSecondary,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final document in schedule.documents)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.description_outlined,
                            size: 14,
                            color: AppColors.textMuted,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              document.fileName,
                              style: AppTextStyles.bodySmall.copyWith(
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                          if (document.isRequired)
                            Text(
                              'REQUIRED',
                              style: AppTextStyles.labelSmall.copyWith(
                                color: AppColors.textWarning,
                              ),
                            ),
                        ],
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

class _ExpandableHeader extends StatelessWidget {
  const _ExpandableHeader({
    required this.title,
    required this.caption,
    required this.status,
    required this.expanded,
    required this.onTap,
    this.dense = false,
  });

  final String title;
  final String caption;
  final String status;
  final bool expanded;
  final VoidCallback onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style:
                        (dense
                                ? AppTextStyles.labelLarge
                                : AppTextStyles.headlineMedium)
                            .copyWith(
                              color: AppColors.textPrimary,
                              fontSize: dense ? 14 : 17,
                              fontWeight: FontWeight.w700,
                            ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    caption,
                    style: AppTextStyles.labelSmall.copyWith(
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (status.isNotEmpty)
              Text(
                status.toUpperCase(),
                style: AppTextStyles.labelSmall.copyWith(
                  color: status.toUpperCase() == 'COMPLETED'
                      ? AppColors.textMuted
                      : AppColors.statusActive,
                  letterSpacing: 0.8,
                ),
              ),
            Icon(
              expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
