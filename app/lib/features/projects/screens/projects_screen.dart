import 'package:flutter/material.dart';

import '../../../app.dart';
import '../../../core/state/granite_lake_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../trade3/widgets/trade3_hierarchy_section.dart';

class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key});

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _showCreateProjectDialog() async {
    final created = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => const _CreateProjectDialog(),
    );
    if (!mounted || created != true) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('Project created and set active')),
      );
  }

  Future<void> _selectProject(String projectId) async {
    final controller = GraniteLakeScope.of(context);
    await controller.selectProject(projectId);
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Active project updated')));
  }

  @override
  Widget build(BuildContext context) {
    final controller = GraniteLakeScope.of(context);
    final isPaired = controller.isTrade3Paired;
    final projects = controller.localProjects;
    final selectedProjectId = controller.selectedProjectId;
    final captureCounts = <String, int>{};
    for (final capture in controller.attestationHistory) {
      final projectId = capture.projectId;
      if (projectId == null || projectId.isEmpty) {
        continue;
      }
      captureCounts[projectId] = (captureCounts[projectId] ?? 0) + 1;
    }

    // The bar only appears when there is something to search; a stale query
    // must not keep filtering once it is hidden.
    final canSearch = isPaired
        ? controller.trade3Hierarchy?.isNotEmpty ?? false
        : projects.isNotEmpty;
    final query = canSearch ? _searchQuery : '';
    final visibleProjects = projects
        .where(
          (project) =>
              project.title.toLowerCase().contains(query) ||
              project.projectId.toLowerCase().contains(query),
        )
        .toList();

    return Scaffold(
      backgroundColor: AppColors.background,
      floatingActionButton: isPaired || projects.isEmpty
          ? null
          : FloatingActionButton(
              onPressed: _showCreateProjectDialog,
              child: const Icon(Icons.add_rounded),
            ),
      body: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Projects',
                style: AppTextStyles.displayMedium.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                isPaired
                    ? 'Tap a payment schedule to make it the active project for capture.'
                    : projects.isEmpty
                    ? 'Create one project to unlock capture.'
                    : 'Tap a project to make it active for capture.',
                style: AppTextStyles.bodyMedium.copyWith(
                  color: AppColors.textSecondary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              if (canSearch) ...[
                TextField(
                  controller: _searchController,
                  onChanged: (value) {
                    setState(() => _searchQuery = value.trim().toLowerCase());
                  },
                  textInputAction: TextInputAction.search,
                  style: AppTextStyles.bodyMedium.copyWith(
                    color: AppColors.textPrimary,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Search projects',
                    hintStyle: AppTextStyles.bodyMedium.copyWith(
                      color: AppColors.textMuted,
                    ),
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      color: AppColors.textSecondary,
                    ),
                    suffixIcon: _searchQuery.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                            icon: Icon(
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
                      borderSide: BorderSide(color: AppColors.borderActive),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: AppColors.primary),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 32),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  children: [
                    Trade3HierarchySection(query: query),
                    // Paired: the Trade3 payment schedules above are the
                    // projects, so the local registry is hidden.
                    if (!isPaired) ...[
                      const SizedBox(height: 20),
                      Text(
                        'Registry: ${projects.length.toString().padLeft(2, '0')}',
                        style: AppTextStyles.labelMedium.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 14),
                      if (projects.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 24),
                          child: _EmptyProjectsState(
                            onCreatePressed: _showCreateProjectDialog,
                          ),
                        )
                      else if (visibleProjects.isEmpty)
                        Text(
                          'No projects match your search.',
                          style: AppTextStyles.bodyMedium.copyWith(
                            color: AppColors.textSecondary,
                          ),
                        )
                      else
                        for (final project in visibleProjects)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _ProjectCard(
                              project: project,
                              captureCount:
                                  captureCounts[project.projectId] ?? 0,
                              isActive: project.projectId == selectedProjectId,
                              onTap: () => _selectProject(project.projectId),
                            ),
                          ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateProjectDialog extends StatefulWidget {
  const _CreateProjectDialog();

  @override
  State<_CreateProjectDialog> createState() => _CreateProjectDialogState();
}

class _CreateProjectDialogState extends State<_CreateProjectDialog> {
  final TextEditingController _titleController = TextEditingController();
  bool _isSaving = false;
  String? _errorMessage;

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSaving) {
      return;
    }

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    final controller = GraniteLakeScope.of(context);
    final result = await controller.createProject(title: _titleController.text);
    if (!mounted) {
      return;
    }

    if (!result.isSuccess) {
      setState(() {
        _isSaving = false;
        _errorMessage = result.message;
      });
      return;
    }

    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surfaceElevated,
      title: Text('Create Project', style: AppTextStyles.headlineMedium),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Project ID will be generated automatically.',
              style: AppTextStyles.bodyMedium.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _titleController,
              textCapitalization: TextCapitalization.words,
              autofocus: true,
              decoration: _inputDecoration(
                label: 'Project Title',
                hint: 'Perimeter Security Audit',
              ),
              style: AppTextStyles.bodyMedium.copyWith(
                color: AppColors.textPrimary,
              ),
              onSubmitted: (_) => _submit(),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                style: AppTextStyles.bodySmall.copyWith(
                  color: AppColors.statusError,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(false),
          child: Text(
            'CANCEL',
            style: AppTextStyles.buttonText.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
        ),
        ElevatedButton(
          onPressed: _isSaving ? null : _submit,
          child: Text(
            _isSaving ? 'CREATING' : 'CREATE',
            style: AppTextStyles.buttonText,
          ),
        ),
      ],
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    required this.project,
    required this.captureCount,
    required this.isActive,
    required this.onTap,
  });

  final ProjectRecord project;
  final int captureCount;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isActive ? AppColors.statusActive : AppColors.borderActive,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      project.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.headlineMedium.copyWith(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      project.projectId,
                      style: AppTextStyles.labelSmall.copyWith(
                        color: AppColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '$captureCount ${captureCount == 1 ? 'capture' : 'captures'}'
                      ' · ${_formatProjectDate(project.createdAt)}',
                      style: AppTextStyles.bodySmall.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                isActive
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: isActive ? AppColors.statusActive : AppColors.textMuted,
                semanticLabel: isActive ? 'Active project' : 'Not active',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyProjectsState extends StatelessWidget {
  const _EmptyProjectsState({required this.onCreatePressed});

  final VoidCallback onCreatePressed;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
              ),
              child: Icon(
                Icons.folder_open_rounded,
                color: AppColors.textSecondary,
                size: 30,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'No projects created',
              style: AppTextStyles.headlineMedium.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Create a project, then select it before saving captures.',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodyMedium.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onCreatePressed,
                icon: const Icon(Icons.add_rounded),
                label: Text('CREATE PROJECT', style: AppTextStyles.buttonText),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

InputDecoration _inputDecoration({
  required String label,
  required String hint,
}) {
  return InputDecoration(
    labelText: label,
    hintText: hint,
    hintStyle: AppTextStyles.bodyMedium.copyWith(color: AppColors.textMuted),
    labelStyle: AppTextStyles.bodyMedium.copyWith(
      color: AppColors.textSecondary,
    ),
    filled: true,
    fillColor: AppColors.surface,
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: AppColors.borderActive),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: AppColors.primary),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: AppColors.statusError),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: AppColors.statusError),
    ),
  );
}

String _formatProjectDate(DateTime dateTime) {
  final local = dateTime.toLocal();
  final year = local.year.toString().padLeft(4, '0');
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}
