import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app.dart';
import '../../../core/router/app_router.dart';
import '../../../core/state/granite_lake_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';

enum _VerificationFilter { any, anchored, pending, failed }

enum _VerificationStatus { anchored, pending, failed }

enum _PeriodFilter { allTime, today, last7Days, last30Days }

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _verificationRequested = <String>{};

  bool _isSearchVisible = false;
  String _searchQuery = '';
  String _selectedProject = 'All';
  _VerificationFilter _verificationFilter = _VerificationFilter.any;
  _PeriodFilter _periodFilter = _PeriodFilter.allTime;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = GraniteLakeScope.of(context);
    final captures = controller.captureHistory;
    final projectTitlesById = {
      for (final project in controller.projects) project.projectId: project.title,
    };
    final availableProjects = <String>{
      'All',
      ...captures.map((capture) => _projectLabel(capture, projectTitlesById)),
    }.toList()..sort();
    final filteredCaptures = captures
        .where((capture) => _matchesSearch(capture, projectTitlesById))
        .where((capture) => _matchesProject(capture, projectTitlesById))
        .where((capture) => _matchesVerification(capture, controller))
        .where(_matchesPeriod)
        .toList();
    final capturesToVerify = filteredCaptures
        .where(
          (capture) =>
              capture.isAttestationAnchored &&
              !_verificationRequested.contains(capture.captureId),
        )
        .toList();
    if (capturesToVerify.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _verificationRequested.addAll(
          capturesToVerify.map((capture) => capture.captureId),
        );
        controller.verifyCapturesOnChain(capturesToVerify);
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'History',
                      style: AppTextStyles.displayMedium.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  _HeaderIconButton(
                    icon: _isSearchVisible
                        ? Icons.close_rounded
                        : Icons.search_rounded,
                    onTap: _toggleSearch,
                  ),
                  const SizedBox(width: 8),
                  _HeaderIconButton(
                    icon: Icons.tune_rounded,
                    menuItems: [
                      const PopupMenuItem<String>(
                        value: 'clear',
                        child: Text('Clear filters'),
                      ),
                      PopupMenuItem<String>(
                        value: _isSearchVisible ? 'hide_search' : 'show_search',
                        child: Text(
                          _isSearchVisible ? 'Hide search' : 'Show search',
                        ),
                      ),
                    ],
                    onSelected: (value) {
                      if (value == 'clear') {
                        _clearFilters();
                      } else if (value == 'show_search' ||
                          value == 'hide_search') {
                        _toggleSearch();
                      }
                    },
                  ),
                ],
              ),
              if (_isSearchVisible) ...[
                const SizedBox(height: 14),
                TextField(
                  controller: _searchController,
                  onChanged: (value) {
                    setState(() => _searchQuery = value.trim().toLowerCase());
                  },
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: AppColors.textPrimary,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Search project, note, tags, or hash',
                    hintStyle: AppTextStyles.bodyMedium.copyWith(
                      color: AppColors.textMuted,
                    ),
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      color: AppColors.textSecondary,
                    ),
                    suffixIcon: _searchQuery.isEmpty
                        ? null
                        : IconButton(
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                            icon: const Icon(
                              Icons.close_rounded,
                              color: AppColors.textSecondary,
                            ),
                          ),
                    filled: true,
                    fillColor: AppColors.surface,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(
                        color: AppColors.borderActive,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: AppColors.primary),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _MenuChip<String>(
                      label: 'Project: $_selectedProject',
                      isActive: _selectedProject != 'All',
                      value: _selectedProject,
                      items: availableProjects,
                      labelBuilder: (value) => value,
                      onSelected: (value) {
                        setState(() => _selectedProject = value);
                      },
                    ),
                    const SizedBox(width: 8),
                    _MenuChip<_VerificationFilter>(
                      label:
                          'Verification: ${_verificationLabel(_verificationFilter)}',
                      isActive: _verificationFilter != _VerificationFilter.any,
                      value: _verificationFilter,
                      items: _VerificationFilter.values,
                      labelBuilder: _verificationLabel,
                      onSelected: (value) {
                        setState(() => _verificationFilter = value);
                      },
                    ),
                    const SizedBox(width: 8),
                    _MenuChip<_PeriodFilter>(
                      label: 'Period: ${_periodLabel(_periodFilter)}',
                      isActive: _periodFilter != _PeriodFilter.allTime,
                      value: _periodFilter,
                      items: _PeriodFilter.values,
                      labelBuilder: _periodLabel,
                      onSelected: (value) {
                        setState(() => _periodFilter = value);
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Expanded(
          child: filteredCaptures.isEmpty
              ? _EmptyHistoryState(hasFilters: _hasActiveFilters)
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 20),
                  itemCount: filteredCaptures.length,
                  separatorBuilder: (context, index) =>
                      const Divider(height: 1, color: AppColors.border),
                  itemBuilder: (context, index) {
                    final capture = filteredCaptures[index];
                    return _HistoryRow(
                      capture: capture,
                      projectLabel: _projectLabel(capture, projectTitlesById),
                      verification: controller.captureVerificationFor(
                        capture.captureId,
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  bool get _hasActiveFilters =>
      _searchQuery.isNotEmpty ||
      _selectedProject != 'All' ||
      _verificationFilter != _VerificationFilter.any ||
      _periodFilter != _PeriodFilter.allTime;

  void _toggleSearch() {
    setState(() {
      if (_isSearchVisible) {
        _searchController.clear();
        _searchQuery = '';
      }
      _isSearchVisible = !_isSearchVisible;
    });
  }

  bool _matchesSearch(
    CaptureRecord capture,
    Map<String, String> projectTitlesById,
  ) {
    if (_searchQuery.isEmpty) {
      return true;
    }

    final haystack = [
      _projectLabel(capture, projectTitlesById),
      capture.displayTitle,
      capture.imageSha256,
      capture.shortHash,
      ...capture.tags,
    ].join(' ').toLowerCase();

    return haystack.contains(_searchQuery);
  }

  bool _matchesProject(
    CaptureRecord capture,
    Map<String, String> projectTitlesById,
  ) {
    if (_selectedProject == 'All') {
      return true;
    }
    return _projectLabel(capture, projectTitlesById) == _selectedProject;
  }

  String _projectLabel(
    CaptureRecord capture,
    Map<String, String> projectTitlesById,
  ) {
    final projectId = capture.projectId?.trim();
    if (projectId == null || projectId.isEmpty) {
      return 'UNASSIGNED';
    }

    final title = projectTitlesById[projectId]?.trim();
    if (title != null && title.isNotEmpty) {
      return title;
    }

    return projectId;
  }

  bool _matchesVerification(
    CaptureRecord capture,
    GraniteLakeController controller,
  ) {
    final status = _verificationStatusFor(
      capture,
      controller.captureVerificationFor(capture.captureId),
    );
    switch (_verificationFilter) {
      case _VerificationFilter.any:
        return true;
      case _VerificationFilter.anchored:
        return status == _VerificationStatus.anchored;
      case _VerificationFilter.pending:
        return status == _VerificationStatus.pending;
      case _VerificationFilter.failed:
        return status == _VerificationStatus.failed;
    }
  }

  bool _matchesPeriod(CaptureRecord capture) {
    final capturedAt = capture.capturedAt.toLocal();
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);

    switch (_periodFilter) {
      case _PeriodFilter.allTime:
        return true;
      case _PeriodFilter.today:
        return !capturedAt.isBefore(todayStart);
      case _PeriodFilter.last7Days:
        return !capturedAt.isBefore(now.subtract(const Duration(days: 7)));
      case _PeriodFilter.last30Days:
        return !capturedAt.isBefore(now.subtract(const Duration(days: 30)));
    }
  }

  void _clearFilters() {
    setState(() {
      _selectedProject = 'All';
      _verificationFilter = _VerificationFilter.any;
      _periodFilter = _PeriodFilter.allTime;
      _searchController.clear();
      _searchQuery = '';
      _isSearchVisible = false;
    });
  }

  static String _verificationLabel(_VerificationFilter filter) {
    return switch (filter) {
      _VerificationFilter.any => 'Any',
      _VerificationFilter.anchored => 'Anchored',
      _VerificationFilter.pending => 'Pending',
      _VerificationFilter.failed => 'Failed',
    };
  }

  static String _periodLabel(_PeriodFilter filter) {
    return switch (filter) {
      _PeriodFilter.allTime => 'All Time',
      _PeriodFilter.today => 'Today',
      _PeriodFilter.last7Days => 'Last 7D',
      _PeriodFilter.last30Days => 'Last 30D',
    };
  }

  static _VerificationStatus _verificationStatusFor(
    CaptureRecord capture,
    CaptureChainVerificationRecord? verification,
  ) {
    if (verification?.isVerified == true) {
      return _VerificationStatus.anchored;
    }
    if (verification?.isPending == true) {
      return _VerificationStatus.pending;
    }
    if (capture.isAttestationAnchored) {
      return _VerificationStatus.pending;
    }
    if (capture.isAttestationPending) {
      return _VerificationStatus.pending;
    }
    return _VerificationStatus.failed;
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.icon,
    this.onTap,
    this.menuItems,
    this.onSelected,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final List<PopupMenuEntry<String>>? menuItems;
  final ValueChanged<String>? onSelected;

  @override
  Widget build(BuildContext context) {
    final button = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.borderActive),
        color: AppColors.surface,
      ),
      child: Icon(icon, size: 18, color: AppColors.textSecondary),
    );

    if (menuItems != null && onSelected != null) {
      return PopupMenuButton<String>(
        onSelected: onSelected,
        color: AppColors.surfaceElevated,
        itemBuilder: (context) => menuItems!,
        child: button,
      );
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: button,
    );
  }
}

class _MenuChip<T> extends StatelessWidget {
  const _MenuChip({
    required this.label,
    required this.items,
    required this.value,
    required this.labelBuilder,
    required this.onSelected,
    this.isActive = false,
  });

  final String label;
  final List<T> items;
  final T value;
  final String Function(T value) labelBuilder;
  final ValueChanged<T> onSelected;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      onSelected: onSelected,
      color: AppColors.surfaceElevated,
      itemBuilder: (context) => items
          .map(
            (item) => PopupMenuItem<T>(
              value: item,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      labelBuilder(item),
                      style: AppTextStyles.bodyMedium.copyWith(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  if (item == value)
                    const Icon(Icons.check_rounded, color: AppColors.primary),
                ],
              ),
            ),
          )
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? AppColors.primary.withAlpha(18) : AppColors.surface,
          border: Border.all(
            color: isActive ? AppColors.primary : AppColors.borderActive,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label.toUpperCase(),
              style: AppTextStyles.labelMedium.copyWith(
                color: isActive ? AppColors.primary : AppColors.textSecondary,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.arrow_drop_down_rounded,
              size: 18,
              color: isActive ? AppColors.primary : AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyHistoryState extends StatelessWidget {
  const _EmptyHistoryState({required this.hasFilters});

  final bool hasFilters;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history_rounded, size: 48, color: AppColors.textMuted),
            const SizedBox(height: 16),
            Text(
              hasFilters ? 'NO MATCHING CAPTURES' : 'NO CAPTURES YET',
              style: AppTextStyles.labelMedium.copyWith(
                color: AppColors.textMuted,
                letterSpacing: 1.0,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              hasFilters
                  ? 'Try adjusting search, project, verification, or period filters.'
                  : 'Start a secure session and save a capture to build your on-device ledger.',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.textMuted,
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.capture,
    required this.projectLabel,
    required this.verification,
  });

  final CaptureRecord capture;
  final String projectLabel;
  final CaptureChainVerificationRecord? verification;

  @override
  Widget build(BuildContext context) {
    final imageFile = File(capture.imagePath);
    final hasImage = imageFile.existsSync();
    final verificationStatus = _HistoryScreenState._verificationStatusFor(
      capture,
      verification,
    );

    return InkWell(
      onTap: () {
        context.push(AppRoutes.historyDetail, extra: capture);
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 64,
              height: 64,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                border: Border.all(color: AppColors.borderActive),
              ),
              child: hasImage
                  ? Image.file(
                      imageFile,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) =>
                          const _MissingThumb(),
                    )
                  : const _MissingThumb(),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    projectLabel.toUpperCase(),
                    style: AppTextStyles.labelMedium.copyWith(
                      color: AppColors.primary,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'SHA256: ${capture.shortHash}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: AppColors.textPrimary,
                    ),
                  ),
                  if (capture.tags.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      capture.tags.join(' • '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.labelSmall.copyWith(
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _VerificationBadge(status: verificationStatus),
                const SizedBox(height: 6),
                Text(
                  _formatTimestamp(capture.capturedAt),
                  style: AppTextStyles.labelSmall.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _formatTimestamp(DateTime timestampUtc) {
    final local = timestampUtc.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(local.year, local.month, local.day);

    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final ss = local.second.toString().padLeft(2, '0');

    if (date == today) {
      return '$hh:$mm:$ss';
    }

    if (date == today.subtract(const Duration(days: 1))) {
      return 'Yesterday';
    }

    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }
}

class _VerificationBadge extends StatelessWidget {
  const _VerificationBadge({required this.status});

  final _VerificationStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, background, border, foreground) = switch (status) {
      _VerificationStatus.anchored => (
        'ANCHORED',
        AppColors.statusActive.withAlpha(18),
        AppColors.statusActive.withAlpha(70),
        AppColors.statusActive,
      ),
      _VerificationStatus.pending => (
        'PENDING',
        AppColors.primary.withAlpha(20),
        AppColors.primary.withAlpha(70),
        AppColors.primary,
      ),
      _VerificationStatus.failed => (
        'FAILED',
        AppColors.statusError.withAlpha(18),
        AppColors.statusError.withAlpha(70),
        AppColors.statusError,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: border),
      ),
      child: Text(
        label,
        style: AppTextStyles.labelSmall.copyWith(
          color: foreground,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

class _MissingThumb extends StatelessWidget {
  const _MissingThumb();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surfaceElevated,
      child: const Center(
        child: Icon(
          Icons.image_not_supported_outlined,
          color: AppColors.textMuted,
          size: 20,
        ),
      ),
    );
  }
}
