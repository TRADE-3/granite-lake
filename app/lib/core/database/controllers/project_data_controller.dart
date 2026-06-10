import '../dao/project_dao.dart';

class ProjectDataController {
  ProjectDataController(this._projectDao);

  final ProjectDao _projectDao;

  Future<List<Map<String, dynamic>>> loadProjects() async {
    final rows = await _projectDao.listProjects();
    return rows.map(_toAppShape).toList(growable: false);
  }

  Future<void> saveProject(Map<String, dynamic> project) {
    return _projectDao.upsert(project);
  }

  Future<void> clear() {
    return _projectDao.deleteAll();
  }

  Map<String, dynamic> _toAppShape(Map<String, dynamic> row) {
    return <String, dynamic>{
      'projectId': row['project_id'],
      'title': row['title'],
      'createdAt': row['created_at'],
    };
  }
}