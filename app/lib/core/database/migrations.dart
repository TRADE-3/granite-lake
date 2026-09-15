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
        case 10:
          await _upgradeToVersionTen(db);
          break;
        case 11:
          await _upgradeToVersionEleven(db);
          break;
        case 12:
          await _upgradeToVersionTwelve(db);
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
        updated_at TEXT NOT NULL,
        wallet_address TEXT NOT NULL DEFAULT ''
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

  // Offline-capture design doc §8: is_online/is_forced_offline record
  // ground-truth connectivity and whether the crew overrode it, per capture,
  // independently of has_gps/is_gps_forced_null (photo_captures only - file
  // attestation never carried location data). Defaults assume prior rows
  // were captured online, not forced, with a GPS fix, matching today's
  // pre-offline-capture behavior.
  static Future<void> _upgradeToVersionTen(Database db) async {
    await db.execute(
      'ALTER TABLE ${GraniteLakeDatabaseService.photoCapturesTable} ADD COLUMN is_online INTEGER NOT NULL DEFAULT 1',
    );
    await db.execute(
      'ALTER TABLE ${GraniteLakeDatabaseService.photoCapturesTable} ADD COLUMN is_forced_offline INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE ${GraniteLakeDatabaseService.photoCapturesTable} ADD COLUMN has_gps INTEGER NOT NULL DEFAULT 1',
    );
    await db.execute(
      'ALTER TABLE ${GraniteLakeDatabaseService.photoCapturesTable} ADD COLUMN is_gps_forced_null INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE ${GraniteLakeDatabaseService.uploadedFilesTable} ADD COLUMN is_online INTEGER NOT NULL DEFAULT 1',
    );
    await db.execute(
      'ALTER TABLE ${GraniteLakeDatabaseService.uploadedFilesTable} ADD COLUMN is_forced_offline INTEGER NOT NULL DEFAULT 0',
    );
  }

  // Offline-capture design doc §4b/§8: mandatory null-reason text and its
  // hash, required exactly when the corresponding field above is null or
  // its force toggle overrode a present one (contract-enforced on-chain,
  // see granite_lake.move). Nullable - NULL exactly when no reason was
  // needed (the field was present, not overridden). gps_null_reason* only
  // on photo_captures, same reasoning as has_gps/is_gps_forced_null above.
  //
  // The hash is computed once, at capture time, from the plaintext - the
  // same moment photo_hash is computed - and folded into the signed proof
  // bundle alongside it (see granite_lake_capture_workflow_service.dart),
  // so a later edit to the plaintext is detectable against the originally
  // signed hash. It is persisted here (not recomputed on the spot at
  // submission time) specifically so what gets submitted on-chain is
  // provably the value that was signed at capture, not a value derived
  // from whatever the reason column happens to contain by then. The
  // plaintext itself stays local for disclosure; it's never transmitted
  // on-chain, only this hash is.
  static Future<void> _upgradeToVersionEleven(Database db) async {
    await db.execute(
      'ALTER TABLE ${GraniteLakeDatabaseService.photoCapturesTable} ADD COLUMN internet_null_reason TEXT',
    );
    await db.execute(
      'ALTER TABLE ${GraniteLakeDatabaseService.photoCapturesTable} ADD COLUMN internet_null_reason_hash TEXT',
    );
    await db.execute(
      'ALTER TABLE ${GraniteLakeDatabaseService.photoCapturesTable} ADD COLUMN gps_null_reason TEXT',
    );
    await db.execute(
      'ALTER TABLE ${GraniteLakeDatabaseService.photoCapturesTable} ADD COLUMN gps_null_reason_hash TEXT',
    );
    await db.execute(
      'ALTER TABLE ${GraniteLakeDatabaseService.uploadedFilesTable} ADD COLUMN internet_null_reason TEXT',
    );
    await db.execute(
      'ALTER TABLE ${GraniteLakeDatabaseService.uploadedFilesTable} ADD COLUMN internet_null_reason_hash TEXT',
    );
  }

  // App-local only - never submitted on-chain. Tracks how many times a
  // genuine submission attempt has actually been made for this row
  // (whether the very first, online, attempt, or a later queue retry), and
  // when the most recent one happened, so the crew can see why something
  // is still queued instead of it just silently sitting there. Not
  // incremented for a capture that was persisted while offline/forced
  // offline and skipped the network call entirely (see
  // GraniteLakeController.persistCaptureWithMetadata's initial-attempt
  // skip) - only real attempts count.
  static Future<void> _upgradeToVersionTwelve(Database db) async {
    await db.execute(
      'ALTER TABLE ${GraniteLakeDatabaseService.photoCapturesTable} ADD COLUMN submission_attempt_count INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE ${GraniteLakeDatabaseService.photoCapturesTable} ADD COLUMN last_attempt_at TEXT',
    );
    await db.execute(
      'ALTER TABLE ${GraniteLakeDatabaseService.uploadedFilesTable} ADD COLUMN submission_attempt_count INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE ${GraniteLakeDatabaseService.uploadedFilesTable} ADD COLUMN last_attempt_at TEXT',
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
        is_online INTEGER NOT NULL DEFAULT 1,
        is_forced_offline INTEGER NOT NULL DEFAULT 0,
        has_gps INTEGER NOT NULL DEFAULT 1,
        is_gps_forced_null INTEGER NOT NULL DEFAULT 0,
        internet_null_reason TEXT,
        internet_null_reason_hash TEXT,
        gps_null_reason TEXT,
        gps_null_reason_hash TEXT,
        submission_attempt_count INTEGER NOT NULL DEFAULT 0,
        last_attempt_at TEXT,
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
        is_online INTEGER NOT NULL DEFAULT 1,
        is_forced_offline INTEGER NOT NULL DEFAULT 0,
        internet_null_reason TEXT,
        internet_null_reason_hash TEXT,
        submission_attempt_count INTEGER NOT NULL DEFAULT 0,
        last_attempt_at TEXT,
        FOREIGN KEY (project_id) REFERENCES ${GraniteLakeDatabaseService.projectsTable}(project_id)
          ON DELETE SET NULL
      )
    ''');
  }
}
