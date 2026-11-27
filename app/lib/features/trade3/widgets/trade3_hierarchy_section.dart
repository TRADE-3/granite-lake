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
  const Trade3HierarchySection({super.key, this.query = ''});

  /// Lower-cased search text; empty shows the whole tree.
  final String query;

  @override
  Widget build(BuildContext context) {
    final controller = GraniteLakeScope.of(context);
    final hierarchy = controller.trade3Hierarchy;
    final isSyncing = controller.isSyncingTrade3Hierarchy;

    if (!controller.isTrade3Paired) {
      return const _LinkAccountCard();
    }

    final matches = [
      for (final contract in hierarchy ?? const <Trade3MasterContract>[])
        ?_ContractMatch.of(contract, query),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'TRADE3 PROJECTS',
                    style: AppTextStyles.labelMedium.copyWith(
                      color: AppColors.textSecondary,
                      letterSpacing: 1.1,
                    ),
                  ),
                  if (controller.trade3HierarchySyncedAt != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Synced ${formatSyncStamp(controller.trade3HierarchySyncedAt!)}',
                      style: AppTextStyles.labelSmall.copyWith(
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ],
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
        else if (matches.isEmpty)
          Text(
            'No projects match your search.',
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textSecondary,
            ),
          )
        else
          for (var index = 0; index < matches.length; index++)
            Padding(
              padding: EdgeInsets.only(
                bottom: index == matches.length - 1 ? 0 : 10,
              ),
              child: _MasterContractCard(
                // Keyed on search mode so cards re-apply their default
                // expansion when a search starts or ends.
                key: ValueKey((matches[index].contract.id, query.isEmpty)),
                match: matches[index],
              ),
            ),
      ],
    );
  }
}

/// A contract narrowed to what matches the search. A hit on a parent keeps all
/// of its children; a hit on a child keeps just that branch and expands to it.
class _ContractMatch {
  const _ContractMatch(this.contract, this.transactions, this.expand);

  final Trade3MasterContract contract;
  final List<_TransactionMatch> transactions;
  final bool expand;

  static _ContractMatch? of(Trade3MasterContract contract, String query) {
    final selfMatches =
        query.isEmpty ||
        contract.title.toLowerCase().contains(query) ||
        contract.reference.toLowerCase().contains(query);
    final transactions = <_TransactionMatch>[];
    for (final transaction in contract.transactions) {
      final keepAll =
          selfMatches || transaction.title.toLowerCase().contains(query);
      final schedules = keepAll
          ? transaction.paymentSchedules
          : transaction.paymentSchedules
                .where((s) => s.title.toLowerCase().contains(query))
                .toList();
      if (keepAll || schedules.isNotEmpty) {
        transactions.add(
          _TransactionMatch(transaction, schedules, expand: !keepAll),
        );
      }
    }
    if (!selfMatches && transactions.isEmpty) {
      return null;
    }
    return _ContractMatch(contract, transactions, !selfMatches);
  }
}

class _TransactionMatch {
  const _TransactionMatch(
    this.transaction,
    this.schedules, {
    required this.expand,
  });

  final Trade3Transaction transaction;
  final List<Trade3PaymentSchedule> schedules;
  final bool expand;
}

String _count(int count, String noun) => '$count $noun${count == 1 ? '' : 's'}';

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
  const _MasterContractCard({super.key, required this.match});

  final _ContractMatch match;

  @override
  State<_MasterContractCard> createState() => _MasterContractCardState();
}

class _MasterContractCardState extends State<_MasterContractCard> {
  late bool _expanded = widget.match.expand;

  @override
  Widget build(BuildContext context) {
    final contract = widget.match.contract;
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
                ? _count(contract.transactions.length, 'transaction')
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
                  for (final match in widget.match.transactions)
                    _TransactionCard(
                      key: ValueKey(match.transaction.id),
                      contract: contract,
                      match: match,
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
  const _TransactionCard({
    super.key,
    required this.contract,
    required this.match,
  });

  final Trade3MasterContract contract;
  final _TransactionMatch match;

  @override
  State<_TransactionCard> createState() => _TransactionCardState();
}

class _TransactionCardState extends State<_TransactionCard> {
  late bool _expanded = widget.match.expand;

  @override
  Widget build(BuildContext context) {
    final transaction = widget.match.transaction;
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
            caption: _count(
              transaction.paymentSchedules.length,
              'payment schedule',
            ),
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
                  for (final schedule in widget.match.schedules)
                    _PaymentScheduleTile(
                      key: ValueKey(schedule.id),
                      contract: widget.contract,
                      transaction: transaction,
                      schedule: schedule,
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
    super.key,
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
    if (!controller.canSelectTrade3Target) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(GraniteLakeController.depositRightsMessage),
          ),
        );
      return;
    }
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
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
                              _count(schedule.documents.length, 'doc'),
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
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style:
                        (dense
                                ? AppTextStyles.labelLarge
                                : AppTextStyles.headlineMedium)
                            .copyWith(
                              color: AppColors.textPrimary,
                              fontSize: dense ? 14 : 16,
                              fontWeight: FontWeight.w700,
                              height: 1.3,
                            ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (status.isNotEmpty) _StatusChip(status: status),
                      Text(
                        caption,
                        style: AppTextStyles.labelSmall.copyWith(
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
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

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = status.toUpperCase() == 'COMPLETED'
        ? AppColors.textMuted
        : AppColors.statusActive;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(24),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status.toUpperCase().replaceAll('_', ' '),
        style: AppTextStyles.labelSmall.copyWith(
          color: color,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}
