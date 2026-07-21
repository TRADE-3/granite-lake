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
        case 7:
          await _upgradeToVersionSeven(db);
          break;
        case 8:
          await _upgradeToVersionEight(db);
          break;
        case 9:
          await _upgradeToVersionNine(db);
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

    await _createPhotoCapturesTable(db);
    await _createUploadedFilesTable(db);

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
      'CREATE INDEX IF NOT EXISTS idx_photo_captures_recorded_at ON ${GraniteLakeDatabaseService.photoCapturesTable}(captured_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_photo_captures_project_id ON ${GraniteLakeDatabaseService.photoCapturesTable}(project_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_uploaded_files_recorded_at ON ${GraniteLakeDatabaseService.uploadedFilesTable}(captured_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_uploaded_files_project_id ON ${GraniteLakeDatabaseService.uploadedFilesTable}(project_id)',
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

  static Future<void> _upgradeToVersionSeven(Database db) async {
    await db.execute(
      "ALTER TABLE ${GraniteLakeDatabaseService.capturesTable} ADD COLUMN asset_type TEXT NOT NULL DEFAULT 'photo'",
    );
    await db.execute(
      'ALTER TABLE ${GraniteLakeDatabaseService.capturesTable} ADD COLUMN file_name TEXT',
    );
    await db.execute(
      'ALTER TABLE ${GraniteLakeDatabaseService.capturesTable} ADD COLUMN mime_type TEXT',
    );
    await db.execute(
      'ALTER TABLE ${GraniteLakeDatabaseService.capturesTable} ADD COLUMN file_size_bytes INTEGER',
    );
    await db.execute(
      'ALTER TABLE ${GraniteLakeDatabaseService.capturesTable} ADD COLUMN file_extension TEXT',
    );
    await db.execute(
      "ALTER TABLE ${GraniteLakeDatabaseService.capturesTable} ADD COLUMN preview_kind TEXT NOT NULL DEFAULT 'image'",
    );
    await db.execute(
      "ALTER TABLE ${GraniteLakeDatabaseService.capturesTable} ADD COLUMN storage_mode TEXT NOT NULL DEFAULT 'LOCAL_ONLY'",
    );
    await db.execute(
      "UPDATE ${GraniteLakeDatabaseService.capturesTable} SET asset_type = 'photo' WHERE asset_type IS NULL OR trim(asset_type) = ''",
    );
  }

  static Future<void> _upgradeToVersionEight(Database db) async {
    await _createPhotoCapturesTable(db);
    await _createUploadedFilesTable(db);

    await db.execute('''
      INSERT OR REPLACE INTO ${GraniteLakeDatabaseService.photoCapturesTable} (
        photo_capture_id,
        captured_at,
        submitted_at,
        image_path,
        image_sha256,
        signature_base64,
        wallet_address,
        public_key_hex,
        proof_payload_json,
        sui_tx_digest,
        sui_object_id,
        sui_submission_status,
        sui_error_message,
        project_id,
        tags_json,
        note,
        preview_kind,
        storage_mode
      )
      SELECT
        capture_id,
        captured_at,
        submitted_at,
        image_path,
        image_sha256,
        signature_base64,
        wallet_address,
        public_key_hex,
        proof_payload_json,
        sui_tx_digest,
        sui_object_id,
        sui_submission_status,
        sui_error_message,
        project_id,
        tags_json,
        note,
        COALESCE(preview_kind, 'image'),
        COALESCE(storage_mode, 'LOCAL_ONLY')
      FROM ${GraniteLakeDatabaseService.capturesTable}
      WHERE lower(COALESCE(asset_type, 'photo')) = 'photo'
    ''');

    await db.execute('''
      INSERT OR REPLACE INTO ${GraniteLakeDatabaseService.uploadedFilesTable} (
        uploaded_file_id,
        captured_at,
        submitted_at,
        file_path,
        file_sha256,
        signature_base64,
        wallet_address,
        public_key_hex,
        proof_payload_json,
        sui_tx_digest,
        sui_object_id,
        sui_submission_status,
        sui_error_message,
        project_id,
        tags_json,
        note,
        file_name,
        mime_type,
        file_size_bytes,
        file_extension,
        preview_kind,
        storage_mode
      )
      SELECT
        capture_id,
        captured_at,
        submitted_at,
        image_path,
        image_sha256,
        signature_base64,
        wallet_address,
        public_key_hex,
        proof_payload_json,
        sui_tx_digest,
        sui_object_id,
        sui_submission_status,
        sui_error_message,
        project_id,
        tags_json,
        note,
        file_name,
        mime_type,
        file_size_bytes,
        file_extension,
        COALESCE(preview_kind, 'document'),
        COALESCE(storage_mode, 'LOCAL_ONLY')
      FROM ${GraniteLakeDatabaseService.capturesTable}
      WHERE lower(COALESCE(asset_type, 'photo')) = 'file'
    ''');
  }

  static Future<void> _upgradeToVersionNine(Database db) async {
    await db.execute(
      "ALTER TABLE ${GraniteLakeDatabaseService.employeesTable} ADD COLUMN wallet_address TEXT NOT NULL DEFAULT ''",
    );
  }

  static Future<void> _createPhotoCapturesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${GraniteLakeDatabaseService.photoCapturesTable} (
        photo_capture_id TEXT PRIMARY KEY,
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
        preview_kind TEXT NOT NULL DEFAULT 'image',
        storage_mode TEXT NOT NULL DEFAULT 'LOCAL_ONLY',
        FOREIGN KEY (project_id) REFERENCES ${GraniteLakeDatabaseService.projectsTable}(project_id)
          ON DELETE SET NULL
      )
    ''');
  }

  static Future<void> _createUploadedFilesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ${GraniteLakeDatabaseService.uploadedFilesTable} (
        uploaded_file_id TEXT PRIMARY KEY,
        captured_at TEXT NOT NULL,
        submitted_at TEXT,
        file_path TEXT NOT NULL,
        file_sha256 TEXT NOT NULL,
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
        file_name TEXT NOT NULL,
        mime_type TEXT,
        file_size_bytes INTEGER,
        file_extension TEXT,
        preview_kind TEXT NOT NULL DEFAULT 'document',
        storage_mode TEXT NOT NULL DEFAULT 'LOCAL_ONLY',
        FOREIGN KEY (project_id) REFERENCES ${GraniteLakeDatabaseService.projectsTable}(project_id)
          ON DELETE SET NULL
      )
    ''');
  }
}
