import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:go_router/go_router.dart';

import '../../../app.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/state/granite_lake_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';

Color get _detailActionFill => AppColors.actionFill;
Color get _detailActionText => AppColors.actionText;
Color get _detailPanel => AppColors.surface;
Color get _detailPanelBorder => AppColors.border;
Color get _detailTelemetryScrim => AppColors.scrim;
Color get _detailHeaderBorder => AppColors.border;
Color get _detailMutedText => AppColors.textSecondary;
Color get _detailCorner => AppColors.borderActive;

class CaptureDetailScreen extends StatefulWidget {
  const CaptureDetailScreen({super.key, required this.record});

  final CaptureRecord record;

  @override
  State<CaptureDetailScreen> createState() => _CaptureDetailScreenState();
}

class _CaptureDetailScreenState extends State<CaptureDetailScreen> {
  bool _isSavingImage = false;
  bool _verificationRequested = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_verificationRequested) {
      return;
    }
    _verificationRequested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      GraniteLakeScope.of(context).verifyCaptureOnChain(widget.record);
    });
  }

  Future<void> _copyProofBundle() async {
    final controller = GraniteLakeScope.of(context);
    final record =
        controller.captureHistory
            .where((capture) => capture.captureId == widget.record.captureId)
            .firstOrNull ??
        widget.record;
    final proofPayload = record.proofPayload;
    final payload = [
      'Capture ID: ${record.captureId}',
      'Captured At: ${record.capturedAt.toIso8601String()}',
      'Submitted At: ${record.effectiveSubmittedAt.toIso8601String()}',
      'Project: ${record.displayProject}',
      if (record.tags.isNotEmpty) 'Tags: ${record.tags.join(', ')}',
      if (record.note?.trim().isNotEmpty == true)
        'Note: ${record.note!.trim()}',
      'SHA-256: ${record.imageSha256}',
      'Image Path: ${record.imagePath}',
      if (proofPayload.readString('sessionStartedAt') != null)
        'Session Started: ${proofPayload.readString('sessionStartedAt')}',
      if (proofPayload.readString('sessionExpiresAt') != null)
        'Session Expires: ${proofPayload.readString('sessionExpiresAt')}',
      'Wallet: ${record.walletAddress}',
      'Sui Transaction Digest: ${record.suiTxDigest}',
      'Sui Submission Status: ${record.suiSubmissionStatus}',
      if (record.attestationErrorLabel != null)
        'Sui Attestation Error: ${record.attestationErrorLabel}',
    ].join('\n');

    await Clipboard.setData(ClipboardData(text: payload));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Proof bundle copied')));
  }

  Future<void> _downloadImage() async {
    final imageFile = File(widget.record.imagePath);
    if (!await imageFile.exists()) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Captured image is unavailable')),
        );
      return;
    }

    setState(() => _isSavingImage = true);
    try {
      await Gal.putImage(imageFile.path, album: AppConstants.appTitle);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Image saved to gallery')));
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Failed to save image')));
    } finally {
      if (mounted) {
        setState(() => _isSavingImage = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = GraniteLakeScope.of(context);
    final record =
        controller.captureHistory
            .where((capture) => capture.captureId == widget.record.captureId)
            .firstOrNull ??
        widget.record;
    final verification = controller.captureVerificationFor(record.captureId);
    final proofPayload = record.proofPayload;
    final imageFile = File(record.imagePath);
    final verificationStyle = _verificationStyle(record, verification);
    final title = record.note?.trim().isNotEmpty == true
        ? record.note!.trim()
        : record.displayTitle;
    final captureLabel = record.captureId;
    final headerLabel = _headerLabel(proofPayload);
    final overlayStats = _overlayStats(record, proofPayload);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Container(
              height: 64,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: _detailHeaderBorder)),
              ),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => context.pop(),
                    icon: const Icon(
                      Icons.arrow_back_rounded,
                      color: Color(0xFF7D8196),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      headerLabel,
                      style: AppTextStyles.labelLarge.copyWith(
                        color: _detailMutedText,
                        letterSpacing: 1.8,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      border: Border.all(color: AppColors.borderActive),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'AUTHENTICATED',
                      style: AppTextStyles.labelSmall.copyWith(
                        color: AppColors.textSecondary,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AspectRatio(
                      aspectRatio: 16 / 9,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Container(
                            color: AppColors.surfaceElevated,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Image.file(
                                  imageFile,
                                  fit: BoxFit.contain,
                                  errorBuilder: (context, error, stackTrace) {
                                    return Container(
                                      color: AppColors.surfaceElevated,
                                      alignment: Alignment.center,
                                      child: Text(
                                        'Preview unavailable',
                                        style: AppTextStyles.bodyMedium
                                            .copyWith(
                                              color: AppColors.textSecondary,
                                            ),
                                      ),
                                    );
                                  },
                                ),
                                IgnorePointer(
                                  child: CustomPaint(
                                    painter: _PreviewFramePainter(),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Positioned(
                            left: 24,
                            right: 24,
                            bottom: 22,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: _detailTelemetryScrim,
                              ),
                              child: Wrap(
                                spacing: 14,
                                runSpacing: 4,
                                children: [
                                  for (final stat in overlayStats)
                                    _OverlayStat(
                                      label: stat.label,
                                      value: stat.value,
                                      highlight: stat.highlight,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Capture ID: #$captureLabel',
                            style: AppTextStyles.headlineLarge.copyWith(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            title.toUpperCase(),
                            style: AppTextStyles.labelLarge.copyWith(
                              color: _detailMutedText,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 18),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: _copyProofBundle,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _detailActionFill,
                                foregroundColor: _detailActionText,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 18,
                                  vertical: 18,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                elevation: 0,
                              ),
                              icon: const Icon(
                                Icons.description_outlined,
                                size: 20,
                              ),
                              label: Text(
                                'COPY PROOF BUNDLE',
                                style: AppTextStyles.buttonText.copyWith(
                                  color: _detailActionText,
                                  letterSpacing: 1.1,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: _isSavingImage ? null : _downloadImage,
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(color: _detailPanelBorder),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 18,
                                  vertical: 16,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(6),
                                ),
                              ),
                              icon: _isSavingImage
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.download_rounded,
                                      size: 18,
                                    ),
                              label: Text(
                                _isSavingImage
                                    ? 'SAVING IMAGE'
                                    : 'DOWNLOAD CAPTURED IMAGE',
                                style: AppTextStyles.buttonText.copyWith(
                                  color: AppColors.textPrimary,
                                  letterSpacing: 1.1,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          Container(height: 1, color: _detailHeaderBorder),
                          const SizedBox(height: 18),
                          Container(
                            decoration: BoxDecoration(
                              color: _detailPanel,
                              border: Border.all(color: _detailPanelBorder),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Column(
                              children: [
                                _DetailCell(
                                  label: 'PROJECT_SOURCE',
                                  value: record.displayProject.toUpperCase(),
                                ),
                                _DetailCell(
                                  label: 'CAPTURED_AT',
                                  value:
                                      '${record.capturedAt.millisecondsSinceEpoch / 1000} // ${record.capturedAt.toIso8601String()}',
                                ),
                                _DetailCell(
                                  label: 'SUBMITTED_AT',
                                  value:
                                      '${record.effectiveSubmittedAt.millisecondsSinceEpoch / 1000} // ${record.effectiveSubmittedAt.toIso8601String()}',
                                ),
                                _DetailCell(
                                  label: 'GEOSPATIAL_COORDINATES',
                                  value: _geospatialValue(proofPayload),
                                  accent: _geospatialAccent(proofPayload),
                                ),
                                _DetailCell(
                                  label: 'INVESTIGATOR_FIELD_NOTES',
                                  value: record.note?.trim().isNotEmpty == true
                                      ? record.note!.trim()
                                      : 'No investigator notes were provided for this capture.',
                                ),
                                _DetailCell(
                                  label: 'TAGS',
                                  value: record.tags.isNotEmpty
                                      ? record.tags.join(' • ')
                                      : 'No tags recorded',
                                ),
                                _DetailCell(
                                  label: 'SHA256_CONTENT_HASH',
                                  value: record.imageSha256,
                                  canCopy: true,
                                  copyValue: record.imageSha256,
                                ),
                                _DetailCell(
                                  label: 'WALLET_ADDRESS',
                                  value: record.walletAddress,
                                  canCopy: true,
                                  copyValue: record.walletAddress,
                                ),
                                _DetailCell(
                                  label: 'SUI_TX_DIGEST',
                                  value: record.suiTxDigest,
                                  canCopy: true,
                                  copyValue: record.suiTxDigest,
                                ),
                                _DetailCell(
                                  label: 'SUI_SUBMISSION_STATUS',
                                  value: record.suiSubmissionStatus,
                                  canCopy: true,
                                  copyValue: record.suiSubmissionStatus,
                                ),
                                if (record.attestationErrorLabel != null)
                                  _DetailCell(
                                    label: 'SUI_ATTESTATION_ERROR',
                                    value: record.attestationErrorLabel!,
                                    canCopy: true,
                                    copyValue: record.attestationErrorLabel!,
                                  ),
                                if (proofPayload.readString(
                                          'sessionStartedAt',
                                        ) !=
                                        null ||
                                    proofPayload.readString(
                                          'sessionExpiresAt',
                                        ) !=
                                        null)
                                  _DetailCell(
                                    label: 'SESSION_WINDOW',
                                    value:
                                        '${proofPayload.readString('sessionStartedAt') ?? 'Unknown'}  //  ${proofPayload.readString('sessionExpiresAt') ?? 'Unknown'}',
                                    showDivider: false,
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 16,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.statusActive.withAlpha(10),
                              border: Border.all(
                                color: AppColors.statusActive.withAlpha(42),
                              ),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.verified_rounded,
                                  color: verificationStyle.$2,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'VERIFICATION STATUS: ${verificationStyle.$1}',
                                  style: AppTextStyles.labelMedium.copyWith(
                                    color: verificationStyle.$2,
                                    letterSpacing: 1,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            decoration: BoxDecoration(
                              color: _detailPanel,
                              border: Border.all(color: _detailPanelBorder),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Column(
                              children: [
                                _DetailCell(
                                  label: 'CHAIN_HASH_MATCH',
                                  value: _verificationValue(
                                    verification?.photoHashMatches,
                                  ),
                                ),
                                _DetailCell(
                                  label: 'CHAIN_SENDER_MATCH',
                                  value: _verificationValue(
                                    verification?.senderMatches,
                                  ),
                                ),
                                _DetailCell(
                                  label: 'CHAIN_GPS_MATCH',
                                  value: _verificationValue(
                                    verification?.gpsMatches,
                                  ),
                                ),
                                _DetailCell(
                                  label: 'CHAIN_ALTITUDE_MATCH',
                                  value: _verificationValue(
                                    verification?.altitudeMatches,
                                  ),
                                ),
                                _DetailCell(
                                  label: 'CHAIN_PROJECT_ID_MATCH',
                                  value: _verificationValue(
                                    verification?.projectIdMatches,
                                  ),
                                ),
                                _DetailCell(
                                  label: 'CHAIN_SUBMITTED_TIME_MATCH',
                                  value: _verificationValue(
                                    verification?.timestampWithinTolerance,
                                  ),
                                ),
                                _DetailCell(
                                  label: 'CHAIN_TIMESTAMP',
                                  value:
                                      verification?.chainTimestamp
                                          ?.toIso8601String() ??
                                      'Chain timestamp unavailable',
                                ),
                                _DetailCell(
                                  label: 'CHAIN_VERIFICATION_RESULT',
                                  value:
                                      verification?.failureReason ??
                                      verification?.transactionStatus ??
                                      'Verification has not completed yet.',
                                  showDivider: false,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _headerLabel(CaptureProofPayload proofPayload) {
    final appName =
        proofPayload.readString('appName')?.trim().isNotEmpty == true
        ? proofPayload.readString('appName')!
        : AppConstants.appName;
    final appVersion =
        proofPayload.readString('appVersion')?.trim().isNotEmpty == true
        ? proofPayload.readString('appVersion')!
        : AppConstants.appVersion;
    return '${appName.toUpperCase().replaceAll(' ', '_')}_${appVersion.toLowerCase()}';
  }

  (String, Color) _verificationStyle(
    CaptureRecord record,
    CaptureChainVerificationRecord? verification,
  ) {
    if (verification?.isVerified == true) {
      return ('ANCHORED', AppColors.statusActive);
    }
    if (verification?.isPending == true || record.isAttestationPending) {
      return ('PENDING', AppColors.primary);
    }
    if (record.isAttestationAnchored) {
      return ('PENDING', AppColors.primary);
    }
    return ('FAILED', AppColors.statusError);
  }

  String _verificationValue(bool? value) {
    if (value == null) {
      return 'PENDING CHECK';
    }
    return value ? 'MATCH' : 'MISMATCH';
  }

  List<_TelemetryStatData> _overlayStats(
    CaptureRecord record,
    CaptureProofPayload proofPayload,
  ) {
    final cameraLabel = proofPayload.readStringAny(const ['cameraLabel']);
    final cameraDetails = proofPayload.readStringAny(const [
      'cameraDetailsLabel',
    ]);
    final buildLabel = proofPayload.readStringAny(const [
      'buildLabel',
      'appVersion',
    ]);

    return [
      _TelemetryStatData(label: 'CAM', value: cameraLabel ?? 'UNKNOWN'),
      _TelemetryStatData(
        label: 'DETAIL',
        value: cameraDetails ?? buildLabel ?? 'UNAVAILABLE',
        highlight: true,
      ),
    ];
  }

  String _geospatialValue(CaptureProofPayload proofPayload) {
    final gpsLabel = proofPayload.readStringAny(const [
      'gpsLabel',
      'gps',
      'locationLabel',
    ]);
    final altitudeLabel = proofPayload.readStringAny(const [
      'altitudeLabel',
      'altitude',
    ]);
    if (gpsLabel != null) {
      if (altitudeLabel == null) {
        return gpsLabel;
      }
      return '$gpsLabel // ALT $altitudeLabel';
    }

    final latitude = proofPayload.readNumberAny(const ['latitude', 'lat']);
    final longitude = proofPayload.readNumberAny(const [
      'longitude',
      'lng',
      'lon',
    ]);
    if (latitude != null && longitude != null) {
      final accuracy = proofPayload.readNumberAny(const [
        'accuracy',
        'gpsAccuracy',
      ]);
      final coordLabel =
          '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}';
      if (accuracy == null) {
        if (altitudeLabel == null) {
          return coordLabel;
        }
        return '$coordLabel // ALT $altitudeLabel';
      }
      final base = '$coordLabel (${accuracy.toStringAsFixed(0)}m)';
      if (altitudeLabel == null) {
        return base;
      }
      return '$base // ALT $altitudeLabel';
    }

    return 'Geospatial metadata unavailable for this capture.';
  }

  String? _geospatialAccent(CaptureProofPayload proofPayload) {
    final gpsLabel = proofPayload.readStringAny(const [
      'gpsLabel',
      'gps',
      'locationLabel',
    ]);
    if (gpsLabel == null) {
      return 'LOCK UNAVAILABLE';
    }
    if (gpsLabel.contains(', ')) {
      return 'GPS LOCK';
    }
    return null;
  }
}

class _TelemetryStatData {
  const _TelemetryStatData({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  final String label;
  final String value;
  final bool highlight;
}

class _PreviewFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = _detailCorner
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    const inset = 18.0;
    const corner = 14.0;
    final corners = [
      (
        const Offset(inset, inset),
        const Offset(inset + corner, inset),
        const Offset(inset, inset + corner),
      ),
      (
        Offset(size.width - inset, inset),
        Offset(size.width - inset - corner, inset),
        Offset(size.width - inset, inset + corner),
      ),
      (
        Offset(inset, size.height - inset),
        Offset(inset + corner, size.height - inset),
        Offset(inset, size.height - inset - corner),
      ),
      (
        Offset(size.width - inset, size.height - inset),
        Offset(size.width - inset - corner, size.height - inset),
        Offset(size.width - inset, size.height - inset - corner),
      ),
    ];

    for (final cornerData in corners) {
      final path = Path()
        ..moveTo(cornerData.$1.dx, cornerData.$1.dy)
        ..lineTo(cornerData.$2.dx, cornerData.$2.dy)
        ..moveTo(cornerData.$1.dx, cornerData.$1.dy)
        ..lineTo(cornerData.$3.dx, cornerData.$3.dy);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _OverlayStat extends StatelessWidget {
  const _OverlayStat({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: '$label ',
            style: AppTextStyles.labelLarge.copyWith(
              color: const Color(0xFFD0D3DE),
              letterSpacing: 0.8,
            ),
          ),
          TextSpan(
            text: value,
            style: AppTextStyles.labelLarge.copyWith(
              color: highlight ? AppColors.statusActive : Colors.white,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailCell extends StatelessWidget {
  const _DetailCell({
    required this.label,
    required this.value,
    this.canCopy = false,
    this.copyValue,
    this.showDivider = true,
    this.accent,
  });

  final String label;
  final String value;
  final bool canCopy;
  final String? copyValue;
  final bool showDivider;
  final String? accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: showDivider
            ? Border(bottom: BorderSide(color: _detailPanelBorder))
            : null,
      ),
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  label,
                  style: AppTextStyles.labelSmall.copyWith(
                    color: _detailMutedText,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              if (accent != null)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    accent!,
                    style: AppTextStyles.labelSmall.copyWith(
                      color: AppColors.statusActive,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              if (canCopy && copyValue != null)
                InkWell(
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: copyValue!));
                    if (!context.mounted) {
                      return;
                    }
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(SnackBar(content: Text('$label copied')));
                  },
                  child: Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Icon(
                      Icons.content_copy_rounded,
                      size: 16,
                      color: _detailMutedText,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: AppTextStyles.labelLarge.copyWith(
              color: AppColors.textPrimary,
              height: 1.55,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}
