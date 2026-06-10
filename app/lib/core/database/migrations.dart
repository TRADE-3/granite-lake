import 'package:sqflite/sqflite.dart';

import 'granite_lake_database_service.dart';

class Migrations {
  static Future<void> onCreate(Database db, int version) async {
    await _createVersionOneSchema(db);
  }

  static Future<void> onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    for (var version = oldVersion + 1; version <= newVersion; version += 1) {
      switch (version) {
        case 1:
          await _createVersionOneSchema(db);
          break;
        case 2:
          await _upgradeToVersionTwo(db);
          break;
        case 3:
          await _upgradeToVersionThree(db);
          break;
        case 4:
          await _upgradeToVersionFour(db);
          break;
        case 5:
          await _upgradeToVersionFive(db);
          break;
        case 6:
          await _upgradeToVersionSix(db);
          break;
        default:
          throw UnsupportedError(
            'No migration registered for database version $version.',
          );
      }
    }
  }

  static Future<void> _createVersionOneSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${GraniteLakeDatabaseService.employeesTable} (
        employee_id TEXT PRIMARY KEY,
        full_name TEXT NOT NULL,
        role TEXT NOT NULL,
        tenant_name TEXT NOT NULL,
        company_domain TEXT NOT NULL DEFAULT '',
        initials TEXT NOT NULL,
        is_placeholder INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${GraniteLakeDatabaseService.projectsTable} (
        project_id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${GraniteLakeDatabaseService.capturesTable} (
        capture_id TEXT PRIMARY KEY,
        captured_at TEXT NOT NULL,
        submitted_at TEXT,
        image_path TEXT NOT NULL,
        image_sha256 TEXT NOT NULL,
        signature_base64 TEXT NOT NULL,
        wallet_address TEXT NOT NULL,
        public_key_hex TEXT NOT NULL,
        proof_payload_json TEXT NOT NULL,
        sui_tx_digest TEXT NOT NULL DEFAULT '',
        sui_object_id TEXT NOT NULL DEFAULT '',
        sui_submission_status TEXT NOT NULL DEFAULT 'PENDING_SUBMISSION',
        sui_error_message TEXT NOT NULL DEFAULT '',
        project_id TEXT,
        tags_json TEXT NOT NULL,
        note TEXT,
        FOREIGN KEY (project_id) REFERENCES ${GraniteLakeDatabaseService.projectsTable}(project_id)
          ON DELETE SET NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${GraniteLakeDatabaseService.configTable} (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_projects_created_at ON ${GraniteLakeDatabaseService.projectsTable}(created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_captures_captured_at ON ${GraniteLakeDatabaseService.capturesTable}(captured_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_captures_project_id ON ${GraniteLakeDatabaseService.capturesTable}(project_id)',
    );
  }

  static Future<void> _upgradeToVersionTwo(Database db) async {
    await db.execute(
      "ALTER TABLE ${GraniteLakeDatabaseService.capturesTable} ADD COLUMN proof_payload_json TEXT NOT NULL DEFAULT '{}'",
    );
  }

  static Future<void> _upgradeToVersionThree(Database db) async {
    await db.execute(
      "ALTER TABLE ${GraniteLakeDatabaseService.capturesTable} ADD COLUMN sui_tx_digest TEXT NOT NULL DEFAULT ''",
    );
    await db.execute(
      "ALTER TABLE ${GraniteLakeDatabaseService.capturesTable} ADD COLUMN sui_object_id TEXT NOT NULL DEFAULT ''",
    );
    await db.execute(
      "ALTER TABLE ${GraniteLakeDatabaseService.capturesTable} ADD COLUMN sui_submission_status TEXT NOT NULL DEFAULT 'PENDING_SUBMISSION'",
    );
  }

  static Future<void> _upgradeToVersionFour(Database db) async {
    await db.execute(
      "ALTER TABLE ${GraniteLakeDatabaseService.employeesTable} ADD COLUMN company_domain TEXT NOT NULL DEFAULT ''",
    );
  }

  static Future<void> _upgradeToVersionFive(Database db) async {
    await db.execute(
      "ALTER TABLE ${GraniteLakeDatabaseService.capturesTable} ADD COLUMN sui_error_message TEXT NOT NULL DEFAULT ''",
    );
  }

  static Future<void> _upgradeToVersionSix(Database db) async {
    await db.execute(
      "ALTER TABLE ${GraniteLakeDatabaseService.capturesTable} ADD COLUMN submitted_at TEXT",
    );
    await db.execute(
      'UPDATE ${GraniteLakeDatabaseService.capturesTable} SET submitted_at = captured_at WHERE submitted_at IS NULL',
    );
  }

}
