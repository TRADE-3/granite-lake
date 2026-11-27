import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granite_lake/app.dart';
import 'package:granite_lake/core/database/controllers/employee_data_controller.dart';
import 'package:granite_lake/core/database/dao/employee_dao.dart';
import 'package:granite_lake/core/services/gl_session_service.dart';
import 'package:granite_lake/core/state/granite_lake_controller.dart';
import 'package:granite_lake/features/history/screens/history_screen.dart';

class _Controller extends GraniteLakeController {
  _Controller({required this.offered, required this.result});

  bool offered;
  final ActionResult result;

  @override
  bool get canRestoreFiles => offered;

  @override
  Future<ActionResult> restoreFiles() async {
    // As the real one does: success withdraws the offer before returning.
    if (result.isSuccess) {
      offered = false;
      notifyListeners();
    }
    return result;
  }
}

class _EmployeeDao implements EmployeeDao {
  Map<String, dynamic>? row;

  @override
  Future<Map<String, dynamic>?> fetchPrimaryEmployee() async => row;

  @override
  Future<void> upsert(Map<String, dynamic> value) async => row = value;

  @override
  Future<void> deleteAll() async => row = null;

  @override
  Future<int> count() async => row == null ? 0 : 1;

  @override
  Future<void> updateWalletAddress(String walletAddress) async {}
}

const _profile = Trade3Profile(
  userId: '1',
  name: 'User',
  email: 'a@b.com',
  position: '',
  companyId: '7',
  companyName: 'Company',
  role: 'OWNER',
);

void main() {
  Future<void> pump(WidgetTester tester, _Controller controller) {
    return tester.pumpWidget(
      GraniteLakeScope(
        controller: controller,
        child: const MaterialApp(home: Scaffold(body: HistoryScreen())),
      ),
    );
  }

  final button = find.text('RESTORE FILES');

  testWidgets('is only offered for a wallet still to be restored', (
    tester,
  ) async {
    await pump(
      tester,
      _Controller(offered: false, result: const ActionResult.success()),
    );
    expect(button, findsNothing);
  });

  testWidgets('goes away after success with nothing to restore', (
    tester,
  ) async {
    await pump(
      tester,
      _Controller(
        offered: true,
        result: const ActionResult.successWithMessage(
          'Nothing new to restore.',
        ),
      ),
    );

    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(button, findsNothing);
    expect(find.text('Nothing new to restore.'), findsOneWidget);
  });

  testWidgets('stays after a failure, to try again', (tester) async {
    await pump(
      tester,
      _Controller(
        offered: true,
        result: const ActionResult.failure('No connection.'),
      ),
    );

    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(button, findsOneWidget);
    expect(find.text('No connection.'), findsOneWidget);
  });

  test('the flags are stored and survive a relink', () async {
    final dao = _EmployeeDao();
    final employees = EmployeeDataController(dao);
    Future<void> register({required bool imported}) =>
        employees.saveClaimedEmployee(
          employeeId: 'user-1',
          companyDomain: 'tr3.io',
          tenantName: 'tr3.io',
          walletAddress: '0xabc',
          profile: _profile,
          walletRestored: imported,
        );

    await register(imported: true);
    expect(dao.row!['wallet_restored'], 1);
    expect(dao.row!['files_restored'], 0);

    await employees.markFilesRestored();
    await register(imported: false);

    expect(dao.row!['wallet_restored'], 1);
    expect(dao.row!['files_restored'], 1);
  });
}
