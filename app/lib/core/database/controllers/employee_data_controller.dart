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

  Future<void> saveClaimedEmployee({
    required String employeeId,
    required String companyDomain,
  }) async {
    final normalizedEmployeeId = employeeId.trim();
    final normalizedDomain = companyDomain.trim();
    final existing = await _employeeDao.fetchPrimaryEmployee();
    final now = DateTime.now().toUtc().toIso8601String();
    final createdAt = existing?['created_at'] as String? ?? now;
    final fullName = existing?['full_name'] as String? ?? 'Field Operator';
    final role = existing?['role'] as String? ?? 'Inspector';

    await _employeeDao.deleteAll();
    await _employeeDao.upsert(<String, dynamic>{
      'employee_id': normalizedEmployeeId,
      'full_name': fullName,
      'role': role,
      'tenant_name': normalizedDomain,
      'company_domain': normalizedDomain,
      'initials': _initialsForEmployeeId(normalizedEmployeeId),
      'is_placeholder': 0,
      'created_at': createdAt,
      'updated_at': now,
    });
  }

  Future<void> clear() {
    return _employeeDao.deleteAll();
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
