import 'package:flutter_test/flutter_test.dart';
import 'package:granite_lake/core/services/granite_lake_capture_workflow_service.dart';

void main() {
  final capturedAt = DateTime.utc(2026, 11, 25, 14, 30, 52, 123);
  const projectId = '550e8400-e29b-41d4-a716-446655440000';

  group('GraniteLakeCaptureWorkflowService.evidenceFileName', () {
    test('local project capture keeps the extension and uses epoch ms', () {
      final name = GraniteLakeCaptureWorkflowService.evidenceFileName(
        projectId: projectId,
        capturedAt: capturedAt,
        sourceFileName: 'capture.jpg',
      );

      expect(name, 'evidence_${projectId}_1795617052123.jpg');
    });

    test('imported file under a local project keeps its own extension', () {
      final name = GraniteLakeCaptureWorkflowService.evidenceFileName(
        projectId: projectId,
        capturedAt: capturedAt,
        sourceFileName: 'bill_of_lading.pdf',
      );

      expect(name, 'evidence_${projectId}_1795617052123.pdf');
    });

    test('imported file without an extension stays extensionless', () {
      final name = GraniteLakeCaptureWorkflowService.evidenceFileName(
        projectId: projectId,
        capturedAt: capturedAt,
        sourceFileName: 'field-notes',
      );

      expect(name, 'evidence_${projectId}_1795617052123');
    });

    test('Trade3 capture names contract, transaction, and schedule', () {
      final name = GraniteLakeCaptureWorkflowService.evidenceFileName(
        projectId: 't3:12:45:101',
        capturedAt: capturedAt,
        trade3MasterContractId: '12',
        trade3TransactionId: '45',
        trade3PaymentScheduleId: '101',
        sourceFileName: 'capture.jpg',
      );

      expect(name, 'tr3_evidence_12_45_101_1795617052123.jpg');
    });

    test('Trade3 capture without a master contract id omits it', () {
      final name = GraniteLakeCaptureWorkflowService.evidenceFileName(
        projectId: 't3:12:45:101',
        capturedAt: capturedAt,
        trade3TransactionId: '45',
        trade3PaymentScheduleId: '101',
        sourceFileName: 'report.pdf',
      );

      expect(name, 'tr3_evidence_45_101_1795617052123.pdf');
    });

    test('partial Trade3 selection falls back to the local project name', () {
      final name = GraniteLakeCaptureWorkflowService.evidenceFileName(
        projectId: projectId,
        capturedAt: capturedAt,
        trade3TransactionId: '45',
        sourceFileName: 'capture.jpg',
      );

      expect(name, 'evidence_${projectId}_1795617052123.jpg');
    });

    test('missing project id falls back to unassigned', () {
      final name = GraniteLakeCaptureWorkflowService.evidenceFileName(
        projectId: null,
        capturedAt: capturedAt,
        sourceFileName: 'capture.jpg',
      );

      expect(name, 'evidence_unassigned_1795617052123.jpg');
    });

    test('whitespace-only ids are treated as missing', () {
      final name = GraniteLakeCaptureWorkflowService.evidenceFileName(
        projectId: '  ',
        capturedAt: capturedAt,
        trade3TransactionId: '  ',
        trade3PaymentScheduleId: '101',
        sourceFileName: 'capture.jpg',
      );

      expect(name, 'evidence_unassigned_1795617052123.jpg');
    });
  });
}
