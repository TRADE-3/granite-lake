import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'controllers/capture_data_controller.dart';
import 'controllers/config_data_controller.dart';
import 'controllers/employee_data_controller.dart';
import 'controllers/project_data_controller.dart';
import 'dao/capture_dao.dart';
import 'dao/config_dao.dart';
import 'dao/employee_dao.dart';
import 'dao/project_dao.dart';
import 'granite_lake_database_service.dart';

class GraniteLakeDataControllers {
  GraniteLakeDataControllers._({
    required this.databaseService,
    required this.employee,
    required this.project,
    required this.capture,
    required this.config,
  });

  factory GraniteLakeDataControllers.create() {
    final databaseService = GraniteLakeDatabaseService();
    return GraniteLakeDataControllers._(
      databaseService: databaseService,
      employee: EmployeeDataController(EmployeeDao(databaseService)),
      project: ProjectDataController(ProjectDao(databaseService)),
      capture: CaptureDataController(CaptureDao(databaseService)),
      config: ConfigDataController(ConfigDao(databaseService)),
    );
  }

  final GraniteLakeDatabaseService databaseService;
  final EmployeeDataController employee;
  final ProjectDataController project;
  final CaptureDataController capture;
  final ConfigDataController config;

  Future<void> initialize({required FlutterSecureStorage secureStorage}) {
    return databaseService.initialize(secureStorage: secureStorage);
  }

  Future<void> dispose() {
    return databaseService.dispose();
  }
}