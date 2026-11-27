import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granite_lake/app.dart';
import 'package:granite_lake/core/state/granite_lake_controller.dart';
import 'package:granite_lake/features/trade3/widgets/trade3_target_picker.dart';

class _Controller extends GraniteLakeController {
  _Controller({required this.canDeposit});

  final bool canDeposit;

  @override
  bool get canSelectTrade3Target => canDeposit;
}

Future<void> _pumpField(WidgetTester tester, _Controller controller) {
  return tester.pumpWidget(
    GraniteLakeScope(
      controller: controller,
      child: const MaterialApp(home: Scaffold(body: Trade3TargetField())),
    ),
  );
}

void main() {
  const pickerTitle = 'SELECT PROJECT · TRADE3';

  testWidgets('without the deposit right, shows why and opens nothing', (
    tester,
  ) async {
    await _pumpField(tester, _Controller(canDeposit: false));

    expect(
      find.text(GraniteLakeController.depositRightsMessage),
      findsOneWidget,
    );
    await tester.tap(find.byType(Trade3TargetField));
    await tester.pumpAndSettle();
    expect(find.text(pickerTitle), findsNothing);
  });

  testWidgets('with the deposit right, the picker opens', (tester) async {
    await _pumpField(tester, _Controller(canDeposit: true));

    expect(find.text(GraniteLakeController.depositRightsMessage), findsNothing);
    await tester.tap(find.byType(Trade3TargetField));
    await tester.pumpAndSettle();
    expect(find.text(pickerTitle), findsOneWidget);
  });

  test('without the deposit right, a selection is ignored', () async {
    final controller = _Controller(canDeposit: false);

    await controller.selectTrade3Target(
      const Trade3TargetSelection(
        masterContractId: '1',
        masterContractTitle: 'Contract',
        transactionId: '2',
        transactionTitle: 'Transaction',
        paymentScheduleId: '3',
        paymentScheduleTitle: 'Schedule',
      ),
    );

    expect(controller.selectedTrade3Target, isNull);
  });
}
