import 'package:sqflite/sqflite.dart';

import '../granite_lake_database_service.dart';

class ProjectDao {
  ProjectDao(this._databaseService);

  final GraniteLakeDatabaseService _databaseService;

  Future<List<Map<String, dynamic>>> listProjects() async {
    final database = await _databaseService.database;
    final rows = await database.query(
      GraniteLakeDatabaseService.projectsTable,
      orderBy: 'created_at DESC',
    );
    return rows.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  /// Insert-or-update without `REPLACE`: replacing a parent row would delete
  /// it first, which trips the capture tables' foreign keys.
  Future<void> upsert(Map<String, dynamic> project) async {
    final database = await _databaseService.database;
    await database.insert(
      GraniteLakeDatabaseService.projectsTable,
      <String, dynamic>{
        'project_id': project['projectId'],
        'title': project['title'],
        'created_at': project['createdAt'],
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    await database.update(
      GraniteLakeDatabaseService.projectsTable,
      <String, dynamic>{'title': project['title']},
      where: 'project_id = ?',
      whereArgs: [project['projectId']],
    );
  }

  Future<void> deleteAll() async {
    final database = await _databaseService.database;
    await database.delete(GraniteLakeDatabaseService.projectsTable);
  }
}
