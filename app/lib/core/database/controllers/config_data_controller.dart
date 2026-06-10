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

  Future<PhotoAttestationContractConfig?> loadPhotoAttestationContractConfig()
  async {
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

  Future<void> savePhotoAttestationClaim(
    PhotoAttestationClaimRecord claim,
  ) {
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

  Future<PhotoAttestationContractConfig> syncPhotoAttestationContractConfig()
  async {
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

  Future<void> clear() {
    return _configDao.deleteAll();
  }
}
