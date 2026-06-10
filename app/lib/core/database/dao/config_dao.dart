import 'package:sqflite/sqflite.dart';

import '../granite_lake_database_service.dart';

class ConfigDao {
  ConfigDao(this._databaseService);

  final GraniteLakeDatabaseService _databaseService;

  Future<String?> readValue(String key) async {
    final database = await _databaseService.database;
    final rows = await database.query(
      GraniteLakeDatabaseService.configTable,
      columns: const ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return rows.first['value'] as String?;
  }

  Future<void> writeValue(String key, String? value) async {
    final database = await _databaseService.database;
    if (value == null || value.isEmpty) {
      await database.delete(
        GraniteLakeDatabaseService.configTable,
        where: 'key = ?',
        whereArgs: [key],
      );
      return;
    }

    await database.insert(
      GraniteLakeDatabaseService.configTable,
      <String, dynamic>{'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteAll() async {
    final database = await _databaseService.database;
    await database.delete(GraniteLakeDatabaseService.configTable);
  }
}