import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Backend base URL. Dev: `tool/dev_server.dart`. Prod: the WDF Tracker.
/// Override with `--dart-define=API_URL=https://...`.
const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'http://localhost:8787');

/// Server paths (photos, files) → absolute URLs.
String? absolute(String? path) => path == null ? null : '$apiUrl$path';

DateTime _date(Object? v) => DateTime.parse(v as String).toLocal();
DateTime? _dateOrNull(Object? v) => v == null ? null : _date(v);

enum Role { teacher, learner, graduate }

class User {
  User({required this.id, required this.name, required this.role, this.photo});
  final String id, name;
  final Role role;
  final String? photo;

  bool get isTeacher => role == Role.teacher;
  bool get isGraduate => role == Role.graduate;
  bool get isLearner => role == Role.learner;
  String get roleLabel => switch (role) { Role.teacher => 'Teacher', Role.graduate => 'Graduate · Head of Curriculum', Role.learner => 'Learner' };
  String? get photoUrl => absolute(photo);

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: j['id'] as String,
        name: j['name'] as String,
        role: Role.values.firstWhere((r) => r.name == j['role'], orElse: () => Role.learner),
        photo: j['photo'] as String?,
      );
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'role': role.name, 'photo': photo};
}

class Subject {
  Subject({required this.id, required this.name, required this.teacherName, required this.learners});
  final String id, name, teacherName;
  final List<User> learners;

  factory Subject.fromJson(Map<String, dynamic> j) => Subject(
        id: j['id'] as String,
        name: j['name'] as String,
        teacherName: (j['teacherName'] as String?) ?? '',
        learners: [for (final l in (j['learners'] as List?) ?? []) User.fromJson(l as Map<String, dynamic>)],
      );
}

/// A learner on the graduate's church roster, with their class login.
class Student {
  Student({
    required this.user,
    required this.cell,
    required this.modules,
    required this.skill,
    required this.enrolled,
    required this.subjectIds,
    required this.formSubjectIds,
    this.username,
    this.password,
    this.lastLoginAt,
  });
  final User user;
  final String cell;
  final List<String> modules, subjectIds, formSubjectIds;
  final String? skill, username, password;
  final bool enrolled;
  final DateTime? lastLoginAt;

  factory Student.fromJson(Map<String, dynamic> j) => Student(
        user: User.fromJson(j),
        cell: (j['cell'] as String?) ?? '',
        modules: ((j['modules'] as List?) ?? []).cast<String>(),
        skill: j['skill'] as String?,
        enrolled: j['enrolled'] == true,
        subjectIds: ((j['subjectIds'] as List?) ?? []).cast<String>(),
        formSubjectIds: ((j['formSubjectIds'] as List?) ?? []).cast<String>(),
        username: j['username'] as String?,
        password: j['password'] as String?,
        lastLoginAt: _dateOrNull(j['lastLoginAt']),
      );
}

class ClassSession {
  ClassSession({
    required this.id,
    required this.subjectId,
    required this.subjectName,
    required this.title,
    required this.description,
    required this.teacherId,
    required this.teacherName,
    required this.startsAt,
    required this.minutes,
  });
  final String id, subjectId, subjectName, title, description, teacherId, teacherName;
  final DateTime startsAt;
  final int minutes;

  DateTime get endsAt => startsAt.add(Duration(minutes: minutes));

  /// Doors open 15 minutes before start.
  bool get canJoin {
    final now = DateTime.now();
    return now.isAfter(startsAt.subtract(const Duration(minutes: 15))) && now.isBefore(endsAt);
  }

  bool get isLive {
    final now = DateTime.now();
    return now.isAfter(startsAt) && now.isBefore(endsAt);
  }

  bool get isOver => DateTime.now().isAfter(endsAt);

  factory ClassSession.fromJson(Map<String, dynamic> j) => ClassSession(
        id: j['id'] as String,
        subjectId: (j['subjectId'] as String?) ?? '',
        subjectName: (j['subjectName'] as String?) ?? '',
        title: j['title'] as String,
        description: (j['description'] as String?) ?? '',
        teacherId: j['teacherId'] as String,
        teacherName: j['teacherName'] as String,
        startsAt: _date(j['startsAt']),
        minutes: j['minutes'] as int,
      );
}

/// One learner's position on an assignment (their deadline + submission, if any).
class Submission {
  Submission({
    required this.learner,
    required this.dueAt,
    required this.extended,
    this.fileName,
    this.fileUrl,
    this.submittedAt,
    this.late = false,
    this.percent,
    this.feedback,
  });
  final User learner;
  final DateTime dueAt;
  final bool extended, late;
  final String? fileName, fileUrl, feedback;
  final DateTime? submittedAt;
  final int? percent;

  bool get submitted => submittedAt != null;
  bool get marked => percent != null;
  bool get overdue => !submitted && DateTime.now().isAfter(dueAt);

  factory Submission.fromJson(Map<String, dynamic> j) => Submission(
        learner: User.fromJson(j['learner'] as Map<String, dynamic>),
        dueAt: _date(j['dueAt']),
        extended: j['extended'] == true,
        fileName: j['fileName'] as String?,
        fileUrl: absolute(j['fileUrl'] as String?),
        submittedAt: _dateOrNull(j['submittedAt']),
        late: j['late'] == true,
        percent: j['percent'] as int?,
        feedback: j['feedback'] as String?,
      );
}

class Assignment {
  Assignment({
    required this.id,
    required this.subjectId,
    required this.subjectName,
    required this.title,
    required this.instructions,
    required this.dueAt,
    this.briefName,
    this.briefUrl,
    this.learnerCount = 0,
    this.submittedCount = 0,
    this.markedCount = 0,
    this.mine,
    this.submissions = const [],
  });
  final String id, subjectId, subjectName, title, instructions;
  final DateTime dueAt;
  final String? briefName, briefUrl;
  final int learnerCount, submittedCount, markedCount;

  /// Learner view: my deadline (incl. extension) and submission.
  final Submission? mine;

  /// Teacher detail view: every enrolled learner.
  final List<Submission> submissions;

  /// The deadline that applies to whoever is looking.
  DateTime get myDue => mine?.dueAt ?? dueAt;

  factory Assignment.fromJson(Map<String, dynamic> j) => Assignment(
        id: j['id'] as String,
        subjectId: j['subjectId'] as String,
        subjectName: j['subjectName'] as String,
        title: j['title'] as String,
        instructions: (j['instructions'] as String?) ?? '',
        dueAt: _date(j['dueAt']),
        briefName: j['briefName'] as String?,
        briefUrl: absolute(j['briefUrl'] as String?),
        learnerCount: (j['learnerCount'] as int?) ?? 0,
        submittedCount: (j['submittedCount'] as int?) ?? 0,
        markedCount: (j['markedCount'] as int?) ?? 0,
        mine: j['mine'] == null ? null : Submission.fromJson(j['mine'] as Map<String, dynamic>),
        submissions: [for (final s in (j['submissions'] as List?) ?? []) Submission.fromJson(s as Map<String, dynamic>)],
      );
}

class AppNotification {
  AppNotification({required this.id, required this.title, required this.body, required this.link, required this.createdAt, required this.read});
  final String id, title, body, link;
  final DateTime createdAt;
  bool read;

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        id: j['id'] as String,
        title: j['title'] as String,
        body: (j['body'] as String?) ?? '',
        link: (j['link'] as String?) ?? '/',
        createdAt: _date(j['createdAt']),
        read: j['read'] == true,
      );
}

class JoinInfo {
  JoinInfo(this.url, this.token);
  final String url, token;
}

class ApiException implements Exception {
  ApiException(this.message, [this.status = 0]);
  final String message;
  final int status;
  @override
  String toString() => message;
}

class Api {
  Api(this.token);
  final String? token;
  static final _client = http.Client();

  /// Called when the server rejects our token (e.g. signed out elsewhere).
  static void Function()? onUnauthorized;

  Future<dynamic> _send(String method, String path, {Object? body, Uint8List? bytes, String? fileName}) async {
    final req = http.Request(method, Uri.parse('$apiUrl/api/classes$path'));
    if (token != null) req.headers['authorization'] = 'Bearer $token';
    if (bytes != null) {
      req.headers['content-type'] = 'application/octet-stream';
      if (fileName != null) req.headers['x-filename'] = Uri.encodeComponent(fileName);
      req.bodyBytes = bytes;
    } else {
      req.headers['content-type'] = 'application/json';
      if (body != null) req.body = jsonEncode(body);
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req).timeout(Duration(seconds: bytes != null ? 120 : 15)));
    } catch (_) {
      throw ApiException('Can\'t reach the server. Check your connection.');
    }
    final data = res.body.isEmpty ? null : jsonDecode(res.body);
    if (res.statusCode == 401 && token != null) onUnauthorized?.call();
    if (res.statusCode >= 400) {
      throw ApiException(
          data is Map && data['error'] is String ? data['error'] as String : 'Something went wrong (${res.statusCode}).', res.statusCode);
    }
    return data;
  }

  // ---- auth / profile
  Future<(String, User)> login(String email, String password) async {
    final j = await _send('POST', '/auth/login', body: {'email': email, 'password': password}) as Map<String, dynamic>;
    return (j['token'] as String, User.fromJson(j['user'] as Map<String, dynamic>));
  }

  Future<User> me() async => User.fromJson(await _send('GET', '/me') as Map<String, dynamic>);

  Future<User> uploadPhoto(Uint8List jpeg) async =>
      User.fromJson(await _send('POST', '/me/photo', bytes: jpeg, fileName: 'photo.jpg') as Map<String, dynamic>);

  Future<List<Subject>> subjects() async =>
      [for (final s in await _send('GET', '/subjects') as List) Subject.fromJson(s as Map<String, dynamic>)];

  // ---- classes
  Future<List<ClassSession>> sessions() async {
    final list = await _send('GET', '/sessions') as List;
    return list.map((e) => ClassSession.fromJson(e as Map<String, dynamic>)).toList()..sort((a, b) => a.startsAt.compareTo(b.startsAt));
  }

  Future<ClassSession> session(String id) async => ClassSession.fromJson(await _send('GET', '/sessions/$id') as Map<String, dynamic>);

  Future<void> createSession({
    required String subjectId,
    required String title,
    required String description,
    required DateTime startsAt,
    required int minutes,
    int repeatWeeks = 0,
  }) =>
      _send('POST', '/sessions', body: {
        'subjectId': subjectId,
        'title': title,
        'description': description,
        'startsAt': startsAt.toUtc().toIso8601String(),
        'minutes': minutes,
        'repeatWeeks': repeatWeeks,
      });

  Future<void> updateSession(String id, {required String title, required String description, required DateTime startsAt, required int minutes}) =>
      _send('PUT', '/sessions/$id', body: {
        'title': title,
        'description': description,
        'startsAt': startsAt.toUtc().toIso8601String(),
        'minutes': minutes,
      });

  Future<void> deleteSession(String id) => _send('DELETE', '/sessions/$id');

  Future<List<User>> attendance(String id) async =>
      [for (final u in await _send('GET', '/sessions/$id/attendance') as List) User.fromJson(u as Map<String, dynamic>)];

  Future<JoinInfo> join(String id) async {
    final j = await _send('POST', '/sessions/$id/join') as Map<String, dynamic>;
    return JoinInfo(j['url'] as String, j['token'] as String);
  }

  // ---- assignments
  Future<List<Assignment>> assignments() async =>
      [for (final a in await _send('GET', '/assignments') as List) Assignment.fromJson(a as Map<String, dynamic>)];

  Future<Assignment> assignment(String id) async => Assignment.fromJson(await _send('GET', '/assignments/$id') as Map<String, dynamic>);

  /// Creates, attaches the optional brief, then publishes (notifies learners).
  Future<void> createAssignment({
    required String subjectId,
    required String title,
    required String instructions,
    required DateTime dueAt,
    (String, Uint8List)? brief,
  }) async {
    final a = await _send('POST', '/assignments', body: {
      'subjectId': subjectId,
      'title': title,
      'instructions': instructions,
      'dueAt': dueAt.toUtc().toIso8601String(),
    }) as Map<String, dynamic>;
    final id = a['id'] as String;
    if (brief != null) await _send('POST', '/assignments/$id/brief', bytes: brief.$2, fileName: brief.$1);
    await _send('POST', '/assignments/$id/publish');
  }

  Future<void> updateAssignment(String id, {required String title, required String instructions, (String, Uint8List)? brief}) async {
    await _send('PUT', '/assignments/$id', body: {'title': title, 'instructions': instructions});
    if (brief != null) await _send('POST', '/assignments/$id/brief', bytes: brief.$2, fileName: brief.$1);
  }

  Future<void> deleteAssignment(String id) => _send('DELETE', '/assignments/$id');

  Future<void> submit(String id, String fileName, Uint8List bytes) =>
      _send('POST', '/assignments/$id/submit', bytes: bytes, fileName: fileName);

  /// Whole subject when [learnerId] is null, otherwise just that learner.
  Future<void> extend(String id, DateTime dueAt, {String? learnerId}) =>
      _send('POST', '/assignments/$id/extend', body: {'dueAt': dueAt.toUtc().toIso8601String(), 'learnerId': learnerId});

  Future<void> mark(String id, {required String learnerId, required int percent, required String feedback}) =>
      _send('POST', '/assignments/$id/mark', body: {'learnerId': learnerId, 'percent': percent, 'feedback': feedback});

  // ---- graduate: enrolment
  Future<List<Student>> students() async =>
      [for (final s in await _send('GET', '/students') as List) Student.fromJson(s as Map<String, dynamic>)];

  /// Enrols into [subjectIds] (empty = unenrol). Creates the learner's login the first time.
  Future<Student> enrol(String learnerId, List<String> subjectIds) async =>
      Student.fromJson(await _send('POST', '/students/$learnerId/enrol', body: {'subjectIds': subjectIds}) as Map<String, dynamic>);

  Future<int> enrolAll() async => ((await _send('POST', '/students/enrol-all') as Map)['enrolled'] as int?) ?? 0;

  Future<Student> resetPassword(String learnerId) async =>
      Student.fromJson(await _send('POST', '/students/$learnerId/reset-password') as Map<String, dynamic>);

  // ---- notifications
  Future<List<AppNotification>> notifications() async =>
      [for (final n in await _send('GET', '/notifications') as List) AppNotification.fromJson(n as Map<String, dynamic>)];

  Future<void> markRead([List<String>? ids]) => _send('POST', '/notifications/read', body: {'ids': ids});
}
