import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:granite_lake/core/services/trade3_api_service.dart';
import 'package:granite_lake/core/state/granite_lake_models.dart';

void main() {
  const target = Trade3TargetSelection(
    masterContractId: '12',
    masterContractTitle: 'Master Contract Title',
    transactionId: '45',
    transactionTitle: 'Shipment #1',
    paymentScheduleId: '101',
    paymentScheduleTitle: 'Customs Clearance',
  );

  test('derives a deterministic namespaced project id', () {
    expect(target.projectId, 't3:12:45:101');
    expect(Trade3TargetSelection.isTrade3ProjectId(target.projectId), isTrue);
    expect(
      Trade3TargetSelection.isTrade3ProjectId(
        '3f2b8f0e-6a58-4d0a-9d3c-0f6b8f6f9a11',
      ),
      isFalse,
    );
    expect(Trade3TargetSelection.isTrade3ProjectId(null), isFalse);
  });

  test('titles form a breadcrumb', () {
    expect(
      target.projectTitle,
      'Master Contract Title › Shipment #1 › Customs Clearance',
    );
  });

  test('round-trips through JSON', () {
    final restored = Trade3TargetSelection.fromJson(
      jsonDecode(jsonEncode(target.toJson())) as Map<String, dynamic>,
    );
    expect(restored.projectId, target.projectId);
    expect(restored.projectTitle, target.projectTitle);
  });

  test('hierarchy cache JSON round-trips including completed schedules', () {
    final contracts = Trade3MasterContract.listFromJson([
      {
        'id': 12,
        'title': 'MC',
        'reference': 'mc-slug',
        'status': 'ACTIVE',
        'transactions': [
          {
            'id': 45,
            'title': 'Shipment #1',
            'status': 'IN_PROGRESS',
            'payment_schedules': [
              {
                'id': 101,
                'title': 'Customs Clearance',
                'status': 'COMPLETED',
                'documents': [
                  {
                    'id': 502,
                    'file_name': 'bill_of_lading.pdf',
                    'document_type': 'BILL_OF_LADING',
                    'status': 'Pending',
                    'is_required': true,
                  },
                ],
              },
            ],
          },
        ],
      },
    ]);
    final restored = Trade3MasterContract.listFromJson(
      jsonDecode(jsonEncode([for (final c in contracts) c.toJson()])),
    );
    final schedule =
        restored.single.transactions.single.paymentSchedules.single;
    expect(schedule.id, '101');
    expect(schedule.status, 'COMPLETED');
    expect(schedule.documents.single.fileName, 'bill_of_lading.pdf');
  });
}
