import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import 'migrations.dart';

class GraniteLakeDatabaseService {
  static const String databaseName = 'granite_lake.db';
  static const int databaseVersion = 13;

  static const String employeesTable = 'employees';
  static const String projectsTable = 'projects';
  static const String capturesTable = 'captures';
  static const String photoCapturesTable = 'photo_captures';
  static const String uploadedFilesTable = 'uploaded_files';
  static const String configTable = 'app_config';

  static const String selectedProjectConfigKey = 'selected_project_id';
  static const String photoAttestationContractConfigKey =
      'photo_attestation_contract_config';
  static const String photoAttestationClaimConfigKey =
      'photo_attestation_claim';
  static const String offlineCaptureForcedConfigKey = 'offline_capture_forced';
  static const String gpsCaptureForcedNullConfigKey = 'gps_capture_forced_null';

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }

    _database = await _init();
    return _database!;
  }

  Future<void> initialize({required FlutterSecureStorage secureStorage}) async {
    await database;
  }

  Future<void> dispose() async {
    final database = _database;
    _database = null;
    if (database != null && database.isOpen) {
      await database.close();
    }
  }

  Future<Database> _init() async {
    final databasePath = path.join(await getDatabasesPath(), databaseName);

    return openDatabase(
      databasePath,
      version: databaseVersion,
      onConfigure: (database) async {
        await database.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: Migrations.onCreate,
      onUpgrade: Migrations.onUpgrade,
    );
  }
}
