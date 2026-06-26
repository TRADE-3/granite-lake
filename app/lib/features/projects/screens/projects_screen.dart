import 'package:flutter/material.dart';

import '../../../app.dart';
import '../../../core/state/granite_lake_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';

class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key});

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
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
    final projects = controller.projects;
    final selectedProjectId = controller.selectedProjectId;
    final captureCounts = <String, int>{};
    for (final capture in controller.captureHistory) {
      final projectId = capture.projectId;
      if (projectId == null || projectId.isEmpty) {
        continue;
      }
      captureCounts[projectId] = (captureCounts[projectId] ?? 0) + 1;
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      floatingActionButton: projects.isEmpty
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
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'ASSIGNED OPERATIONS REGISTRY',
                          style: AppTextStyles.labelMedium.copyWith(
                            color: AppColors.textSecondary,
                            letterSpacing: 1.1,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Projects',
                          style: AppTextStyles.displayMedium.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          projects.isEmpty
                              ? 'Create one project to unlock capture.'
                              : 'Tap a project to make it active for capture.',
                          style: AppTextStyles.bodyMedium.copyWith(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Registry: ${projects.length.toString().padLeft(2, '0')}',
                style: AppTextStyles.labelMedium.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: projects.isEmpty
                    ? _EmptyProjectsState(
                        onCreatePressed: _showCreateProjectDialog,
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.only(bottom: 32),
                        itemCount: projects.length,
                        separatorBuilder: (context, index) =>
                            const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final project = projects[index];
                          final isActive =
                              project.projectId == selectedProjectId;
                          return _ProjectCard(
                            project: project,
                            captureCount: captureCounts[project.projectId] ?? 0,
                            isActive: isActive,
                            onTap: () => _selectProject(project.projectId),
                          );
                        },
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    isActive ? 'ACTIVE' : 'STANDBY',
                    style: AppTextStyles.labelMedium.copyWith(
                      color: isActive
                          ? AppColors.statusActive
                          : AppColors.textSecondary,
                      letterSpacing: 1.0,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      project.projectId,
                      style: AppTextStyles.labelSmall.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  Icon(
                    isActive
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: isActive
                        ? AppColors.statusActive
                        : AppColors.textMuted,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                project.title,
                style: AppTextStyles.headlineMedium.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '$captureCount captures',
                      style: AppTextStyles.bodySmall.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  Text(
                    _formatProjectDate(project.createdAt),
                    style: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
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
