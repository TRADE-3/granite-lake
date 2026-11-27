import 'dart:convert';

import '../../constants/app_constants.dart';
import '../../state/granite_lake_models.dart';
import '../dao/config_dao.dart';
import '../granite_lake_database_service.dart';

class ConfigDataController {
  ConfigDataController(this._configDao);

  final ConfigDao _configDao;

  Future<String?> loadSelectedProjectId() {
    return _configDao.readValue(
      GraniteLakeDatabaseService.selectedProjectConfigKey,
    );
  }

  Future<void> saveSelectedProjectId(String? projectId) {
    return _configDao.writeValue(
      GraniteLakeDatabaseService.selectedProjectConfigKey,
      projectId,
    );
  }

  /// Last synced Trade3 hierarchy (JSON), kept so targets can be picked
  /// while offline. Null when nothing has been cached.
  Future<String?> loadTrade3HierarchyCache() {
    return _configDao.readValue(
      GraniteLakeDatabaseService.trade3HierarchyConfigKey,
    );
  }

  Future<void> saveTrade3HierarchyCache(String? json) {
    return _configDao.writeValue(
      GraniteLakeDatabaseService.trade3HierarchyConfigKey,
      json,
    );
  }

  Future<String?> loadTrade3Target() {
    return _configDao.readValue(
      GraniteLakeDatabaseService.trade3TargetConfigKey,
    );
  }

  /// Null when Trade3 has not said.
  Future<bool?> loadTrade3CanDeposit() async {
    final raw = await _configDao.readValue(
      GraniteLakeDatabaseService.trade3CanDepositConfigKey,
    );
    return raw == null || raw.isEmpty ? null : raw == 'true';
  }

  Future<void> saveTrade3CanDeposit(bool? value) {
    return _configDao.writeValue(
      GraniteLakeDatabaseService.trade3CanDepositConfigKey,
      value?.toString(),
    );
  }

  Future<void> saveTrade3Target(String? json) {
    return _configDao.writeValue(
      GraniteLakeDatabaseService.trade3TargetConfigKey,
      json,
    );
  }

  Future<PhotoAttestationContractConfig?>
  loadPhotoAttestationContractConfig() async {
    final raw = await _configDao.readValue(
      GraniteLakeDatabaseService.photoAttestationContractConfigKey,
    );
    if (raw == null || raw.isEmpty) {
      return null;
    }
    return PhotoAttestationContractConfig.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
  }

  Future<void> savePhotoAttestationContractConfig(
    PhotoAttestationContractConfig config,
  ) {
    return _configDao.writeValue(
      GraniteLakeDatabaseService.photoAttestationContractConfigKey,
      jsonEncode(config.toJson()),
    );
  }

  Future<PhotoAttestationClaimRecord?> loadPhotoAttestationClaim() async {
    final raw = await _configDao.readValue(
      GraniteLakeDatabaseService.photoAttestationClaimConfigKey,
    );
    if (raw == null || raw.isEmpty) {
      return null;
    }
    return PhotoAttestationClaimRecord.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
  }

  Future<void> savePhotoAttestationClaim(PhotoAttestationClaimRecord claim) {
    return _configDao.writeValue(
      GraniteLakeDatabaseService.photoAttestationClaimConfigKey,
      jsonEncode(claim.toJson()),
    );
  }

  Future<void> clearPhotoAttestationClaim() {
    return _configDao.writeValue(
      GraniteLakeDatabaseService.photoAttestationClaimConfigKey,
      null,
    );
  }

  Future<PhotoAttestationContractConfig>
  syncPhotoAttestationContractConfig() async {
    final defaultConfig = PhotoAttestationContractConfig(
      rpcUrl: AppConstants.defaultSuiRpcUrl,
      packageId: AppConstants.defaultPhotoAttestationPackageId,
      registryId: AppConstants.defaultPhotoAttestationRegistryId,
      moduleName: AppConstants.defaultPhotoAttestationModule,
      updatedAt: DateTime.now().toUtc(),
    );

    final stored = await loadPhotoAttestationContractConfig();
    if (stored == null) {
      await savePhotoAttestationContractConfig(defaultConfig);
      return defaultConfig;
    }

    if (_shouldUpdatePhotoAttestationContractConfig(stored, defaultConfig)) {
      final updatedConfig = stored.copyWith(
        rpcUrl: defaultConfig.rpcUrl,
        packageId: defaultConfig.packageId,
        registryId: defaultConfig.registryId,
        moduleName: defaultConfig.moduleName,
        updatedAt: defaultConfig.updatedAt,
      );
      await savePhotoAttestationContractConfig(updatedConfig);
      return updatedConfig;
    }

    return stored;
  }

  bool _shouldUpdatePhotoAttestationContractConfig(
    PhotoAttestationContractConfig current,
    PhotoAttestationContractConfig expected,
  ) {
    return current.rpcUrl != expected.rpcUrl ||
        current.packageId != expected.packageId ||
        current.registryId != expected.registryId ||
        current.moduleName != expected.moduleName;
  }

  Future<bool> loadOfflineCaptureForced() async {
    final raw = await _configDao.readValue(
      GraniteLakeDatabaseService.offlineCaptureForcedConfigKey,
    );
    return raw == 'true';
  }

  Future<void> saveOfflineCaptureForced(bool value) {
    return _configDao.writeValue(
      GraniteLakeDatabaseService.offlineCaptureForcedConfigKey,
      value ? 'true' : 'false',
    );
  }

  Future<bool> loadGpsCaptureForcedNull() async {
    final raw = await _configDao.readValue(
      GraniteLakeDatabaseService.gpsCaptureForcedNullConfigKey,
    );
    return raw == 'true';
  }

  Future<void> saveGpsCaptureForcedNull(bool value) {
    return _configDao.writeValue(
      GraniteLakeDatabaseService.gpsCaptureForcedNullConfigKey,
      value ? 'true' : 'false',
    );
  }

  Future<void> clear() {
    return _configDao.deleteAll();
  }
}
