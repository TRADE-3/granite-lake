import 'package:sqflite/sqflite.dart';

import '../granite_lake_database_service.dart';

class EmployeeDao {
  EmployeeDao(this._databaseService);

  final GraniteLakeDatabaseService _databaseService;

  Future<Map<String, dynamic>?> fetchPrimaryEmployee() async {
    final database = await _databaseService.database;
    final rows = await database.query(
      GraniteLakeDatabaseService.employeesTable,
      orderBy: 'created_at ASC',
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return Map<String, dynamic>.from(rows.first);
  }

  Future<int> count() async {
    final database = await _databaseService.database;
    return Sqflite.firstIntValue(
          await database.rawQuery(
            'SELECT COUNT(*) FROM ${GraniteLakeDatabaseService.employeesTable}',
          ),
        ) ??
        0;
  }

  Future<void> upsert(Map<String, dynamic> employeeRow) async {
    final database = await _databaseService.database;
    await database.insert(
      GraniteLakeDatabaseService.employeesTable,
      employeeRow,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteAll() async {
    final database = await _databaseService.database;
    await database.delete(GraniteLakeDatabaseService.employeesTable);
  }
}
