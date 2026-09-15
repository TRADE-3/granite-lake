import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../app.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/connectivity_heuristic_service.dart';
import '../../../core/services/time_sync_service.dart';
import '../../../core/state/granite_lake_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/utils.dart';

enum _FileFlow { selecting, review, submitting, success }

class _SelectedFileSnapshot {
  const _SelectedFileSnapshot({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.mimeType,
    required this.modifiedAt,
    required this.previewKind,
    required this.sha256,
  });

  final String path;
  final String name;
  final int sizeBytes;
  final String mimeType;
  final DateTime modifiedAt;
  final AttestationPreviewKind previewKind;
  final String sha256;

  bool get hasImagePreview => previewKind == AttestationPreviewKind.image;

  String get extension {
    final index = name.lastIndexOf('.');
    if (index == -1 || index == name.length - 1) {
      return '';
    }
    return name.substring(index + 1).toUpperCase();
  }

  String get formattedSize {
    if (sizeBytes < 1024) {
      return '$sizeBytes B';
    }
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String get shortHash {
    if (sha256.length <= 24) {
      return sha256.toUpperCase();
    }
    return '${sha256.substring(0, 12).toUpperCase()}...${sha256.substring(sha256.length - 12).toUpperCase()}';
  }
}

class FileAttestationScreen extends StatefulWidget {
  const FileAttestationScreen({super.key});

  @override
  State<FileAttestationScreen> createState() => _FileAttestationScreenState();
}

class _FileAttestationScreenState extends State<FileAttestationScreen> {
  static const int _maxFileSizeBytes = 50 * 1024 * 1024;

  final TextEditingController _noteController = TextEditingController();
  _FileFlow _flow = _FileFlow.selecting;
  int _submissionRunId = 0;
  Future<void> _submissionProgressQueue = Future<void>.value();
  _SelectedFileSnapshot? _selectedFile;
  AttestationRecord? _submittedRecord;
  AttestationSubmissionStage? _activeSubmissionStage;
  String? _errorMessage;
  String _submissionMessage = 'READY_FOR_HASHING';
  final Map<AttestationSubmissionStage, AttestationSubmissionStageState>
  _stageStates = {
    for (final stage in AttestationSubmissionStage.values)
      stage: AttestationSubmissionStageState.pending,
  };
  final ConnectivityHeuristicService _connectivityService =
      ConnectivityHeuristicService();
  final TimeSyncService _timeSyncService = TimeSyncService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_pickFile(autoExitOnCancel: true));
    });
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  void _resetSubmissionProgress() {
    _submissionProgressQueue = Future<void>.value();
    _activeSubmissionStage = null;
    _submissionMessage = 'READY_FOR_HASHING';
    for (final stage in AttestationSubmissionStage.values) {
      _stageStates[stage] = AttestationSubmissionStageState.pending;
    }
  }

  Future<void> _pickFile({bool autoExitOnCancel = false}) async {
    setState(() {
      _flow = _FileFlow.selecting;
      _errorMessage = null;
      _resetSubmissionProgress();
    });

    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.any,
      );
      if (!mounted) {
        return;
      }
      if (result == null || result.files.isEmpty) {
        if (autoExitOnCancel) {
          context.pop();
          return;
        }
        setState(() {
          _flow = _selectedFile == null
              ? _FileFlow.selecting
              : _FileFlow.review;
        });
        return;
      }

      final picked = result.files.single;
      final filePath = picked.path;
      if (filePath == null || filePath.trim().isEmpty) {
        throw const FileSystemException('Selected file path is unavailable.');
      }
      if (picked.size <= 0) {
        throw const FileSystemException('Selected file is empty.');
      }
      if (picked.size > _maxFileSizeBytes) {
        throw const FileSystemException(
          'Selected file exceeds the 50MB limit.',
        );
      }

      final file = File(filePath);
      final stat = await file.stat();
      final bytes = await file.readAsBytes();
      final digest = await Sha256().hash(bytes);
      final mimeType = _resolveMimeType(
        explicitMimeType: null,
        fileName: picked.name,
      );
      final previewKind = _resolvePreviewKind(
        mimeType: mimeType,
        fileName: picked.name,
      );

      setState(() {
        _selectedFile = _SelectedFileSnapshot(
          path: filePath,
          name: picked.name,
          sizeBytes: picked.size,
          mimeType: mimeType,
          modifiedAt: stat.modified.toUtc(),
          previewKind: previewKind,
          sha256: _hex(digest.bytes),
        );
        _flow = _FileFlow.review;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = '$error';
        _flow = _selectedFile == null ? _FileFlow.selecting : _FileFlow.review;
      });
    }
  }

  /// Blocking modal collecting the mandatory free-text reason for an
  /// offline/forced-offline file attestation (offline-capture design doc
  /// §4b) - "Minimal now, polish later." Returns null if the crew cancels.
  Future<String?> _collectNullReason() {
    final reasonController = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final canContinue = reasonController.text.trim().isNotEmpty;
            return AlertDialog(
              backgroundColor: AppColors.surfaceElevated,
              title: Text(
                'Reason Required',
                style: AppTextStyles.headlineMedium,
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'This file will be attested without internet. Explain why before continuing - this is stored with the attestation and hashed on-chain.',
                    style: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: reasonController,
                    maxLines: 2,
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: AppColors.textPrimary,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Why is internet unavailable/overridden?',
                      hintStyle: AppTextStyles.bodyMedium.copyWith(
                        color: AppColors.textMuted,
                      ),
                      filled: true,
                      fillColor: AppColors.surface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: AppColors.borderActive),
                      ),
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(
                    'CANCEL',
                    style: AppTextStyles.buttonText.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: canContinue
                      ? () => Navigator.of(
                          dialogContext,
                        ).pop(reasonController.text.trim())
                      : null,
                  child: Text(
                    'CONTINUE',
                    style: AppTextStyles.buttonText.copyWith(
                      color: canContinue
                          ? AppColors.primary
                          : AppColors.textMuted,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<DateTime?> _fetchBackendUtcTimestamp() async {
    final domain = GraniteLakeScope.of(context).employee?.companyDomain;
    if (domain == null || domain.isEmpty) {
      return null;
    }
    return await AppUtils.fetchBackendUtcTimestamp(domain: domain);
  }

  Future<void> _submit() async {
    final selectedFile = _selectedFile;
    if (selectedFile == null) {
      return;
    }

    final controller = GraniteLakeScope.of(context);
    final projectId = controller.selectedProjectId;
    if (projectId == null || projectId.trim().isEmpty) {
      setState(() {
        _errorMessage =
            'Select a project before uploading a file for attestation.';
      });
      return;
    }

    // isForcedOffline distinguishes *why* this is offline, not just whether
    // the app toggle happens to be on (matches capture_screen.dart): the
    // toggle always means forced (a deliberate override, skipping the
    // network call entirely rather than just ignoring its result); absent
    // that, forced only when there's no OS interface at all (wifi/data off,
    // airplane mode - itself a deliberate device-level action), never when
    // an interface is present but genuinely can't reach anything (a dead
    // zone isn't the crew's doing).
    final appToggleForcedOffline = controller.isOfflineCaptureForced;
    final bool isOnline;
    final bool isForcedOffline;
    if (appToggleForcedOffline) {
      isOnline = false;
      isForcedOffline = true;
    } else {
      final domain = GraniteLakeScope.of(context).employee?.companyDomain;
      final classification = await _connectivityService.check(domain: domain);
      isOnline = classification == ConnectivityClass.online;
      isForcedOffline = isOnline ? false : !_connectivityService.hasOsInterface;
    }

    String? internetNullReason;
    if (!isOnline || isForcedOffline) {
      internetNullReason = await _collectNullReason();
      if (internetNullReason == null) {
        // Crew cancelled the mandatory reason prompt - abort submission.
        return;
      }
    }

    _submissionRunId++;
    final submissionRunId = _submissionRunId;
    setState(() {
      _resetSubmissionProgress();
      _flow = _FileFlow.submitting;
      _errorMessage = null;
      _submissionMessage = 'HASHING_LOCAL_FILE';
    });

    // The file id is derived from this timestamp (see
    // GraniteLakeCaptureWorkflowService.persistFile), so it must come from
    // a clock the client doesn't control. The file's own local
    // last-modified time is not that: it only records when a copy was last
    // written on this device, not a verifiable attestation moment. Falls
    // back to the offline-safe clock rather than hard-failing when there's
    // no live backend to ask (offline-capture design doc §6).
    final liveTimestamp = (isOnline && !isForcedOffline)
        ? await _fetchBackendUtcTimestamp()
        : null;
    final attestedAtUtc = liveTimestamp ?? _timeSyncService.nowUtc();

    final result = await controller.persistFileWithMetadata(
      sourceFilePath: selectedFile.path,
      sourceFileName: selectedFile.name,
      fileSizeBytes: selectedFile.sizeBytes,
      mimeType: selectedFile.mimeType,
      projectId: projectId,
      note: _noteController.text.trim().isEmpty
          ? null
          : _noteController.text.trim(),
      capturedAtUtc: attestedAtUtc,
      submittedAtUtc: attestedAtUtc,
      buildLabel: 'FILE_IMPORT_V1',
      isOnline: isOnline,
      isForcedOffline: isForcedOffline,
      internetNullReason: internetNullReason,
      onProgress: (progress) {
        unawaited(_applySubmissionProgress(progress, submissionRunId));
      },
    );

    if (!mounted) {
      return;
    }
    if (!result.isSuccess || result.record == null) {
      await _submissionProgressQueue;
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      _submissionRunId++;
      if (!mounted) {
        return;
      }
      setState(() {
        _flow = _FileFlow.review;
        _errorMessage = result.message ?? 'File attestation failed.';
      });
      return;
    }

    await _submissionProgressQueue;
    _submissionRunId++;
    final submittedRecord = _resolveSubmittedRecord(controller, result.record!);
    final shouldPauseForFailure = submittedRecord.normalizedSuiSubmissionStatus
        .startsWith('FAILED');
    await Future<void>.delayed(
      Duration(milliseconds: shouldPauseForFailure ? 1600 : 900),
    );
    if (!mounted) {
      return;
    }

    setState(() {
      _submittedRecord = submittedRecord;
      _flow = _FileFlow.success;
    });
  }

  Future<void> _applySubmissionProgress(
    AttestationSubmissionProgress progress,
    int runId,
  ) {
    _submissionProgressQueue = _submissionProgressQueue.then((_) async {
      if (!mounted || _submissionRunId != runId) {
        return;
      }

      setState(() {
        _stageStates[progress.stage] = progress.state;
        _activeSubmissionStage = progress.stage;
        _submissionMessage = progress.message ?? _submissionMessage;
      });

      final delay = switch (progress.state) {
        AttestationSubmissionStageState.active => const Duration(
          milliseconds: 1200,
        ),
        AttestationSubmissionStageState.completed => const Duration(
          milliseconds: 900,
        ),
        AttestationSubmissionStageState.failed => const Duration(
          milliseconds: 1400,
        ),
        AttestationSubmissionStageState.pending => Duration.zero,
      };
      if (delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }
    });
    return _submissionProgressQueue;
  }

  @override
  Widget build(BuildContext context) {
    final controller = GraniteLakeScope.of(context);
    final selectedProject = controller.selectedProject;
    final walletTag = controller.identity?.walletTag ?? 'UNAVAILABLE';

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: switch (_flow) {
            _FileFlow.selecting => _buildSelectingScreen(),
            _FileFlow.review => _buildReviewScreen(
              projectId: selectedProject?.projectId ?? 'UNASSIGNED',
              walletTag: walletTag,
            ),
            _FileFlow.submitting => _buildSubmissionScreen(),
            _FileFlow.success => _buildSuccessScreen(controller),
          },
        ),
      ),
    );
  }

  Widget _buildSelectingScreen() {
    return Column(
      key: const ValueKey('file-selecting'),
      children: [
        _Header(
          onBack: () => context.pop(),
          title: 'FILE_IMPORT',
          status: _submissionMessage,
        ),
        const Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
                SizedBox(height: 18),
                Text('OPENING FILE PICKER'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildReviewScreen({
    required String projectId,
    required String walletTag,
  }) {
    return Column(
      key: const ValueKey('file-review'),
      children: [
        _Header(
          onBack: () => context.pop(),
          title: 'FILE_IMPORT',
          status: _submissionMessage,
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
            child: _buildReview(projectId: projectId, walletTag: walletTag),
          ),
        ),
      ],
    );
  }

  Widget _buildSubmissionScreen() {
    return Column(
      key: const ValueKey('file-submitting'),
      children: [
        _Header(
          onBack: () {},
          title: 'FILE_IMPORT',
          status: _submissionMessage,
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: Column(
              children: [
                const Spacer(),
                SizedBox(
                  width: 176,
                  height: 176,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: 176,
                        height: 176,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: AppColors.statusActive.withAlpha(70),
                            width: 2,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 64,
                        height: 64,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          valueColor: AlwaysStoppedAnimation(
                            AppColors.statusActive,
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(painter: _SubmissionScanPainter()),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  _submissionHeadline,
                  style: AppTextStyles.headlineLarge.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: Text(
                    _submissionDetail,
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: AppColors.textSecondary,
                      height: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: Column(
                    children: [
                      _SubmissionStep(
                        title: 'Hashing And Signing Evidence',
                        value: _submissionStageValue(
                          AttestationSubmissionStage.signing,
                          activeLabel:
                              'Hashing the file and signing the proof bundle',
                          completeLabel: 'Proof bundle signed for this session',
                          failedLabel: 'Signing the local proof bundle failed',
                        ),
                        state:
                            _stageStates[AttestationSubmissionStage.signing]!,
                      ),
                      _SubmissionStep(
                        title: 'Saving Local Record',
                        value: _submissionStageValue(
                          AttestationSubmissionStage.savingLocalRecord,
                          activeLabel:
                              'Writing file metadata and manifest to this device',
                          completeLabel: 'Local file record saved on-device',
                          failedLabel: 'Saving the local file record failed',
                        ),
                        state:
                            _stageStates[AttestationSubmissionStage
                                .savingLocalRecord]!,
                      ),
                      _SubmissionStep(
                        title: 'Submitting To Sui Testnet',
                        value: _submissionStageValue(
                          AttestationSubmissionStage.submittingToChain,
                          activeLabel:
                              'Calling `attest_file` with UserCap, Registry, hash, file id, and project id',
                          completeLabel:
                              'Sui attestation transaction submitted',
                          failedLabel: 'Sui attestation transaction failed',
                        ),
                        state:
                            _stageStates[AttestationSubmissionStage
                                .submittingToChain]!,
                      ),
                      _SubmissionStep(
                        title: 'Refreshing Device History',
                        value: _submissionStageValue(
                          AttestationSubmissionStage.refreshingHistory,
                          activeLabel: 'Refreshing the local file ledger',
                          completeLabel:
                              'File ledger updated with the latest status',
                          failedLabel:
                              'Refreshing the local file ledger failed',
                        ),
                        state:
                            _stageStates[AttestationSubmissionStage
                                .refreshingHistory]!,
                      ),
                    ],
                  ),
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildReview({required String projectId, required String walletTag}) {
    final selectedFile = _selectedFile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ProjectContextCard(projectId: projectId),
        const SizedBox(height: 18),
        if (selectedFile == null)
          _EmptyPickerCard(onPick: _pickFile)
        else ...[
          _SectionLabel(
            title: 'Selected File',
            subtitle: 'Review what will be stored locally and sent on-chain.',
          ),
          const SizedBox(height: 10),
          _FileIdentityCard(
            file: selectedFile,
            onDiscard: () {
              setState(() {
                _selectedFile = null;
                _submittedRecord = null;
                _errorMessage = null;
              });
              unawaited(_pickFile());
            },
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 760;
              final children = [
                _SummaryCard(
                  title: 'LOCAL_RECORD',
                  icon: Icons.storage_rounded,
                  accent: AppColors.statusActive,
                  rows: [
                    ('uploaded_file_id', _projectedFileId(selectedFile)),
                    ('file_name', selectedFile.name),
                    ('file_sha256', selectedFile.shortHash),
                    ('file_path', selectedFile.path),
                    ('mime_type', selectedFile.mimeType),
                    ('file_size_bytes', '${selectedFile.sizeBytes}'),
                    ('storage_mode', 'LOCAL_ONLY'),
                  ],
                ),
                _SummaryCard(
                  title: 'ON_CHAIN_EVENT',
                  icon: Icons.verified_rounded,
                  accent: AppColors.primary,
                  rows: [
                    ('file_hash', selectedFile.shortHash),
                    ('user_wallet', walletTag),
                    ('file_id', _projectedFileId(selectedFile)),
                    ('project_id', projectId),
                  ],
                  footer: _submissionMessage,
                ),
              ];

              if (isWide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: children[0]),
                    const SizedBox(width: 12),
                    Expanded(child: children[1]),
                  ],
                );
              }

              return Column(
                children: [
                  children[0],
                  const SizedBox(height: 12),
                  children[1],
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          _NotesCard(
            controller: _noteController,
            helperText:
                'Saved with this upload on the device. Not included in the on-chain FileAttested event.',
          ),
          const SizedBox(height: 16),
          _SummaryCard(
            title: 'FILE_METADATA',
            icon: Icons.analytics_outlined,
            accent: AppColors.textSecondary,
            rows: [
              ('date_modified', _formatUtc(selectedFile.modifiedAt)),
              (
                'extension',
                selectedFile.extension.isEmpty ? 'N/A' : selectedFile.extension,
              ),
              ('preview_kind', selectedFile.previewKind.name),
              ('storage_mode', 'LOCAL_ONLY'),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SUBMISSION_STAGES',
                  style: AppTextStyles.labelMedium.copyWith(
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(height: 12),
                _LogPanel(stageStates: _stageStates),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _errorMessage!,
                style: AppTextStyles.bodyMedium.copyWith(
                  color: AppColors.statusError,
                ),
              ),
            ),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _flow == _FileFlow.submitting ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.actionText,
                padding: const EdgeInsets.symmetric(vertical: 18),
              ),
              icon: _flow == _FileFlow.submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.verified_rounded),
              label: Text(
                _flow == _FileFlow.submitting
                    ? 'ATTESTING_FILE'
                    : 'ATTEST_FILE',
                style: AppTextStyles.buttonText.copyWith(color: Colors.white),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSuccessScreen(GraniteLakeController controller) {
    final record = _currentSubmittedRecord(controller);
    if (record == null) {
      return const SizedBox.shrink();
    }
    final verification = controller.attestationVerificationFor(
      record.captureId,
    );

    return Column(
      key: const ValueKey('file-success'),
      children: [
        _Header(
          onBack: () => context.pop(),
          title: 'ATTESTATION_SUCCESSFUL',
          status: 'HASH_COMMITTED',
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
            child: Column(
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.statusActive, width: 2),
                    color: AppColors.statusActive.withAlpha(20),
                  ),
                  child: Icon(
                    Icons.check_circle_rounded,
                    color: AppColors.statusActive,
                    size: 56,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'File Attested',
                  style: AppTextStyles.headlineLarge.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AppColors.statusActive,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Data integrity verified and sequenced',
                  style: AppTextStyles.labelMedium.copyWith(
                    color: AppColors.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                _MetadataCard(
                  title: 'HASH_FINGERPRINT',
                  icon: Icons.fingerprint_rounded,
                  rows: [
                    ('SHA256', record.contentSha256),
                    ('File', record.assetName),
                    ('file_id', record.fileId),
                  ],
                ),
                const SizedBox(height: 12),
                _MetadataCard(
                  title: 'CHAIN_REFERENCE',
                  icon: Icons.receipt_long_rounded,
                  rows: [
                    ('Project', record.displayProject),
                    (
                      'Transaction',
                      record.suiTxDigest.isEmpty
                          ? 'Pending'
                          : record.suiTxDigest,
                    ),
                    ('Status', _successStatusLabelFor(record, verification)),
                  ],
                ),
                if (record.note?.trim().isNotEmpty == true) ...[
                  const SizedBox(height: 12),
                  _MetadataCard(
                    title: 'ADDITIONAL_NOTE',
                    icon: Icons.note_alt_rounded,
                    rows: [('Note', record.note!.trim())],
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => context.go(AppRoutes.capture),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 18),
                    ),
                    icon: const Icon(Icons.radio_button_checked_rounded),
                    label: Text(
                      'BACK_TO_CAPTURE',
                      style: AppTextStyles.buttonText.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      _noteController.clear();
                      setState(() {
                        _submittedRecord = null;
                        _selectedFile = null;
                        _errorMessage = null;
                        _resetSubmissionProgress();
                      });
                      await _pickFile();
                    },
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: AppColors.borderActive),
                      padding: const EdgeInsets.symmetric(vertical: 18),
                    ),
                    icon: const Icon(Icons.upload_file_rounded),
                    label: Text(
                      'UPLOAD_ANOTHER',
                      style: AppTextStyles.buttonText.copyWith(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  AttestationRecord? _currentSubmittedRecord(GraniteLakeController controller) {
    final submittedRecord = _submittedRecord;
    if (submittedRecord == null) {
      return null;
    }
    return _resolveSubmittedRecord(controller, submittedRecord);
  }

  AttestationRecord _resolveSubmittedRecord(
    GraniteLakeController controller,
    AttestationRecord fallback,
  ) {
    for (final record in controller.attestationHistory) {
      if (record.captureId == fallback.captureId) {
        return record;
      }
    }
    return fallback;
  }

  String get _submissionHeadline {
    final hasFailure = _stageStates.values.contains(
      AttestationSubmissionStageState.failed,
    );
    if (hasFailure) {
      return 'File Submission Needs Attention';
    }
    return switch (_activeSubmissionStage) {
      AttestationSubmissionStage.signing || null => 'Preparing File Evidence',
      AttestationSubmissionStage.savingLocalRecord => 'Saving Local Proof',
      AttestationSubmissionStage.submittingToChain =>
        'Writing Attestation To Chain',
      AttestationSubmissionStage.refreshingHistory => 'Updating File Ledger',
    };
  }

  String get _submissionDetail => _submissionMessage;

  String _submissionStageValue(
    AttestationSubmissionStage stage, {
    required String activeLabel,
    required String completeLabel,
    required String failedLabel,
  }) {
    return switch (_stageStates[stage]!) {
      AttestationSubmissionStageState.pending => 'Queued',
      AttestationSubmissionStageState.active => activeLabel,
      AttestationSubmissionStageState.completed => completeLabel,
      AttestationSubmissionStageState.failed => failedLabel,
    };
  }

  String _verificationLabelFor(
    AttestationRecord record,
    AttestationChainVerificationRecord? verification,
  ) {
    if (verification?.isVerified == true) {
      return 'ANCHORED';
    }
    if (verification != null &&
        !verification.isVerified &&
        !verification.isPending) {
      return 'FAILED';
    }
    if (record.isAttestationAnchored) {
      return 'ANCHORED';
    }
    if (verification?.isPending == true) {
      return 'PENDING';
    }
    if (record.isAttestationPending) {
      return 'PENDING';
    }
    return 'FAILED';
  }

  String _successStatusLabelFor(
    AttestationRecord record,
    AttestationChainVerificationRecord? verification,
  ) {
    if (verification?.isVerified == true) {
      return 'ANCHORED';
    }
    if (verification != null &&
        !verification.isVerified &&
        !verification.isPending) {
      return 'FAILED';
    }
    if (record.isAttestationAnchored) {
      return 'ANCHORED';
    }
    if (record.suiTxDigest.trim().isNotEmpty &&
        (verification?.isPending == true || record.isAttestationPending)) {
      return 'SUBMITTED';
    }
    return _verificationLabelFor(record, verification);
  }

  String _resolveMimeType({
    required String? explicitMimeType,
    required String fileName,
  }) {
    final normalizedExplicit = explicitMimeType?.trim().toLowerCase();
    if (normalizedExplicit != null && normalizedExplicit.isNotEmpty) {
      return normalizedExplicit;
    }

    final lower = fileName.toLowerCase();
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.doc')) return 'application/msword';
    if (lower.endsWith('.docx')) {
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    }
    if (lower.endsWith('.xls')) return 'application/vnd.ms-excel';
    if (lower.endsWith('.xlsx')) {
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    }
    if (lower.endsWith('.txt')) return 'text/plain';
    if (lower.endsWith('.csv')) return 'text/csv';
    return 'application/octet-stream';
  }

  AttestationPreviewKind _resolvePreviewKind({
    required String mimeType,
    required String fileName,
  }) {
    final normalizedMime = mimeType.toLowerCase();
    if (normalizedMime.startsWith('image/')) {
      return AttestationPreviewKind.image;
    }
    if (normalizedMime == 'application/pdf' ||
        normalizedMime.contains('document') ||
        normalizedMime.contains('sheet') ||
        normalizedMime.contains('text/')) {
      return AttestationPreviewKind.document;
    }

    final lower = fileName.toLowerCase();
    if (lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp')) {
      return AttestationPreviewKind.image;
    }
    if (lower.endsWith('.pdf') ||
        lower.endsWith('.doc') ||
        lower.endsWith('.docx') ||
        lower.endsWith('.txt') ||
        lower.endsWith('.csv')) {
      return AttestationPreviewKind.document;
    }
    return AttestationPreviewKind.binary;
  }

  String _formatUtc(DateTime timestamp) {
    final utc = timestamp.toUtc();
    final month = utc.month.toString().padLeft(2, '0');
    final day = utc.day.toString().padLeft(2, '0');
    final hour = utc.hour.toString().padLeft(2, '0');
    final minute = utc.minute.toString().padLeft(2, '0');
    final second = utc.second.toString().padLeft(2, '0');
    return '${utc.year}-$month-$day $hour:$minute:$second UTC';
  }

  String _hex(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}

class _ProjectContextCard extends StatelessWidget {
  const _ProjectContextCard({required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('PROJECT_CONTEXT', style: AppTextStyles.labelMedium),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.statusActive.withAlpha(18),
                  border: Border.all(color: AppColors.borderActive),
                ),
                child: Text(
                  'LOCAL_ONLY',
                  style: AppTextStyles.labelSmall.copyWith(
                    color: AppColors.statusActive,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            projectId,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.labelLarge.copyWith(
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title.toUpperCase(), style: AppTextStyles.labelMedium),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: AppTextStyles.bodySmall.copyWith(
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.onBack,
    required this.title,
    required this.status,
  });

  final VoidCallback onBack;
  final String title;
  final String status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.labelLarge.copyWith(
                color: AppColors.primary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 200),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surfaceOverlay,
                  border: Border.all(color: AppColors.borderActive),
                ),
                child: Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: AppTextStyles.labelSmall.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyPickerCard extends StatelessWidget {
  const _EmptyPickerCard({required this.onPick});

  final Future<void> Function({bool autoExitOnCancel}) onPick;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.borderActive),
      ),
      child: Column(
        children: [
          Icon(Icons.upload_file_rounded, size: 42, color: AppColors.primary),
          const SizedBox(height: 16),
          Text(
            'Select a file to hash and attest',
            style: AppTextStyles.headlineMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'PDF, image, DOCX, spreadsheet, or any other supported local file up to 50MB.',
            style: AppTextStyles.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 18),
          ElevatedButton.icon(
            onPressed: () => onPick(),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.folder_open_rounded),
            label: Text(
              'CHOOSE_FILE',
              style: AppTextStyles.buttonText.copyWith(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

class _FileIdentityCard extends StatelessWidget {
  const _FileIdentityCard({required this.file, required this.onDiscard});

  final _SelectedFileSnapshot file;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.borderActive),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 76,
                height: 92,
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  border: Border.all(color: AppColors.borderActive),
                ),
                child: file.hasImagePreview
                    ? ClipRect(
                        child: Image.file(File(file.path), fit: BoxFit.cover),
                      )
                    : Icon(
                        file.mimeType == 'application/pdf'
                            ? Icons.picture_as_pdf_rounded
                            : Icons.insert_drive_file_rounded,
                        size: 40,
                        color: AppColors.primary,
                      ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name.toUpperCase(),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.headlineMedium.copyWith(
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${file.formattedSize} • ${file.mimeType.toUpperCase()}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onDiscard,
              icon: Icon(Icons.close_rounded, color: AppColors.textSecondary),
              label: Text(
                'DISCARD',
                style: AppTextStyles.labelMedium.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.title,
    required this.icon,
    required this.accent,
    required this.rows,
    this.footer,
  });

  final String title;
  final IconData icon;
  final Color accent;
  final List<(String, String)> rows;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: AppTextStyles.labelMedium.copyWith(color: accent),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final row in rows) ...[
            Text(row.$1, style: AppTextStyles.labelSmall),
            const SizedBox(height: 4),
            Text(
              row.$2,
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
          ],
          if (footer != null) ...[
            const SizedBox(height: 2),
            Text(
              footer!,
              style: AppTextStyles.labelSmall.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NotesCard extends StatelessWidget {
  const _NotesCard({required this.controller, required this.helperText});

  final TextEditingController controller;
  final String helperText;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ADDITIONAL_NOTES',
            style: AppTextStyles.labelMedium.copyWith(color: AppColors.primary),
          ),
          const SizedBox(height: 6),
          Text(
            helperText,
            style: AppTextStyles.bodySmall.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            maxLines: 4,
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textPrimary,
            ),
            decoration: InputDecoration(
              border: OutlineInputBorder(
                borderSide: BorderSide(color: AppColors.borderActive),
              ),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: AppColors.borderActive),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: AppColors.primary),
              ),
              hintText:
                  'Add optional operational context for this uploaded file',
              hintStyle: AppTextStyles.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetadataCard extends StatelessWidget {
  const _MetadataCard({
    required this.title,
    required this.icon,
    required this.rows,
  });

  final String title;
  final IconData icon;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: AppColors.primary),
              const SizedBox(width: 8),
              Text(
                title,
                style: AppTextStyles.labelMedium.copyWith(
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final row in rows) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    row.$1.toUpperCase(),
                    style: AppTextStyles.labelSmall,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          _middleEllipsis(row.$2),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: AppTextStyles.bodySmall.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      InkWell(
                        onTap: () => _copyValue(context, row.$1, row.$2),
                        borderRadius: BorderRadius.circular(16),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            Icons.copy_rounded,
                            size: 16,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Future<void> _copyValue(
    BuildContext context,
    String label,
    String value,
  ) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('${label.toUpperCase()} copied')));
  }
}

String _middleEllipsis(String value, {int keepStart = 14, int keepEnd = 12}) {
  final normalized = value.trim();
  if (normalized.length <= keepStart + keepEnd + 3) {
    return normalized;
  }
  final start = normalized.substring(0, keepStart);
  final end = normalized.substring(normalized.length - keepEnd);
  return '$start...$end';
}

class _LogPanel extends StatelessWidget {
  const _LogPanel({required this.stageStates});

  final Map<AttestationSubmissionStage, AttestationSubmissionStageState>
  stageStates;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: AttestationSubmissionStage.values.map((stage) {
        final state =
            stageStates[stage] ?? AttestationSubmissionStageState.pending;
        final status = switch (state) {
          AttestationSubmissionStageState.pending => 'PENDING',
          AttestationSubmissionStageState.active => 'ACTIVE',
          AttestationSubmissionStageState.completed => 'OK',
          AttestationSubmissionStageState.failed => 'FAILED',
        };
        final accent = switch (state) {
          AttestationSubmissionStageState.completed => AppColors.statusActive,
          AttestationSubmissionStageState.active => AppColors.primary,
          AttestationSubmissionStageState.failed => AppColors.statusError,
          AttestationSubmissionStageState.pending => AppColors.textSecondary,
        };

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.surfaceElevated,
            border: Border.all(color: AppColors.borderActive),
          ),
          child: Row(
            children: [
              Icon(Icons.fiber_manual_record_rounded, size: 10, color: accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  stage.name.toUpperCase(),
                  style: AppTextStyles.labelMedium.copyWith(
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              Text(
                status,
                style: AppTextStyles.labelSmall.copyWith(color: accent),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _SubmissionStep extends StatelessWidget {
  const _SubmissionStep({
    required this.title,
    required this.value,
    required this.state,
  });

  final String title;
  final String value;
  final AttestationSubmissionStageState state;

  @override
  Widget build(BuildContext context) {
    final isActive = state == AttestationSubmissionStageState.active;
    final isComplete = state == AttestationSubmissionStageState.completed;
    final isFailed = state == AttestationSubmissionStageState.failed;
    final accent = isFailed
        ? AppColors.statusError
        : isComplete || isActive
        ? AppColors.statusActive
        : AppColors.borderActive;
    final icon = isFailed
        ? Icons.close_rounded
        : isComplete
        ? Icons.check_rounded
        : Icons.more_horiz_rounded;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: accent.withAlpha(isActive ? 180 : 100)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent.withAlpha(isActive ? 36 : 20),
              border: Border.all(color: accent),
            ),
            child: isActive
                ? Padding(
                    padding: const EdgeInsets.all(6),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(accent),
                    ),
                  )
                : Icon(icon, size: 16, color: accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTextStyles.labelMedium),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: AppTextStyles.bodySmall.copyWith(
                    color: AppColors.textSecondary,
                    height: 1.45,
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

class _SubmissionScanPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = AppColors.statusActive.withAlpha(70)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final glowPaint = Paint()
      ..color = AppColors.statusActive.withAlpha(32)
      ..style = PaintingStyle.fill;
    final centerY = size.height * 0.5;
    final rect = Rect.fromLTWH(0, centerY - 6, size.width, 12);
    canvas.drawRect(rect, glowPaint);
    canvas.drawLine(
      Offset(18, centerY),
      Offset(size.width - 18, centerY),
      linePaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// The real file id is assigned from the backend clock at submission time
// (see _FileAttestationScreenState._submit), not from anything known about
// the file before then, so there is nothing meaningful to preview here.
String _projectedFileId(_SelectedFileSnapshot file) {
  return 'ASSIGNED_AT_SUBMISSION';
}
