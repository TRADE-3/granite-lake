import '../../services/gl_session_service.dart' show Trade3Profile;
import '../dao/employee_dao.dart';

class EmployeeDataController {
  EmployeeDataController(this._employeeDao);

  final EmployeeDao _employeeDao;

  Future<Map<String, dynamic>?> loadPrimaryEmployee() async {
    final row = await _employeeDao.fetchPrimaryEmployee();
    if (row == null) {
      return null;
    }
    return _toAppShape(row);
  }

  Future<void> seedDefaultEmployee() async {
    if (await _employeeDao.count() > 0) {
      return;
    }

    final now = DateTime.now().toUtc().toIso8601String();
    await _employeeDao.upsert(<String, dynamic>{
      'employee_id': 'EMP-0001',
      'full_name': 'John Doe',
      'role': 'Senior Inspector',
      'tenant_name': 'Global Audit Corp',
      'company_domain': '',
      'initials': 'JD',
      'is_placeholder': 1,
      'created_at': now,
      'updated_at': now,
    });
  }

  /// Stores a registration. [tenantName] is the registry domain the account
  /// attests under; [companyDomain] is the domain used to reach the server.
  Future<void> saveClaimedEmployee({
    required String employeeId,
    required String companyDomain,
    required String tenantName,
    required String walletAddress,
    required Trade3Profile profile,
    bool walletRestored = false,
  }) async {
    final normalizedEmployeeId = employeeId.trim();
    final existing = await _employeeDao.fetchPrimaryEmployee();
    final now = DateTime.now().toUtc().toIso8601String();
    final createdAt = existing?['created_at'] as String? ?? now;

    await _employeeDao.deleteAll();
    await _employeeDao.upsert(<String, dynamic>{
      'employee_id': normalizedEmployeeId,
      'tenant_name': tenantName.trim(),
      'company_domain': companyDomain.trim(),
      'initials': _initialsForEmployeeId(normalizedEmployeeId),
      'is_placeholder': 0,
      'created_at': createdAt,
      'updated_at': now,
      'wallet_address': walletAddress,
      ..._profileColumns(profile),
      // Kept across a relink: restoring is offered once per wallet.
      'wallet_restored': walletRestored ? 1 : existing?['wallet_restored'] ?? 0,
      'files_restored': existing?['files_restored'] ?? 0,
    });
  }

  Future<void> markWalletRestored() => _setFlag('wallet_restored');

  Future<void> markFilesRestored() => _setFlag('files_restored');

  Future<void> _setFlag(String column) async {
    final existing = await _employeeDao.fetchPrimaryEmployee();
    if (existing == null) {
      return;
    }
    await _employeeDao.upsert(<String, dynamic>{
      ...existing,
      column: 1,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Applies a newer Trade3 profile, only for the account already stored.
  /// Returns false if it belongs to someone else.
  Future<bool> updateTrade3Profile(Trade3Profile profile) async {
    final existing = await _employeeDao.fetchPrimaryEmployee();
    if (existing == null || existing['trade3_user_id'] != profile.userId) {
      return false;
    }
    await _employeeDao.upsert(<String, dynamic>{
      ...existing,
      ..._profileColumns(profile),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
    return true;
  }

  Map<String, dynamic> _profileColumns(Trade3Profile profile) {
    return <String, dynamic>{
      'full_name': profile.name,
      'role': profile.role,
      'email': profile.email,
      'trade3_user_id': profile.userId,
      'company_name': profile.companyName,
      'trade3_company_id': profile.companyId,
      'position': profile.position,
    };
  }

  Future<void> clear() {
    return _employeeDao.deleteAll();
  }

  Future<void> updateWalletAddress(String walletAddress) {
    return _employeeDao.updateWalletAddress(walletAddress);
  }

  Map<String, dynamic> _toAppShape(Map<String, dynamic> row) {
    return <String, dynamic>{
      'employeeId': row['employee_id'],
      'fullName': row['full_name'],
      'role': row['role'],
      'tenantName': row['tenant_name'],
      'companyDomain': row['company_domain'],
      'initials': row['initials'],
      'createdAt': row['created_at'],
      'updatedAt': row['updated_at'],
      'isPlaceholder': (row['is_placeholder'] as int? ?? 0) == 1,
      'walletAddress': row['wallet_address'] as String? ?? '',
      'email': row['email'] as String? ?? '',
      'trade3UserId': row['trade3_user_id'] as String? ?? '',
      'companyName': row['company_name'] as String? ?? '',
      'position': row['position'] as String? ?? '',
      'walletRestored': (row['wallet_restored'] as int? ?? 0) == 1,
      'filesRestored': (row['files_restored'] as int? ?? 0) == 1,
    };
  }

  String _initialsForEmployeeId(String employeeId) {
    final cleaned = employeeId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    if (cleaned.length >= 2) {
      return cleaned.substring(0, 2).toUpperCase();
    }
    if (cleaned.length == 1) {
      return '${cleaned.toUpperCase()}X';
    }
    return 'OP';
  }
}
