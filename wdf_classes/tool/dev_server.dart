// Stand-in for the WDF Tracker "classes" API — same endpoints and JSON the
// Tracker must implement (see docs/API.md). Issues real LiveKit tokens.
//
//   dart run tool/dev_server.dart          (reads ../.env.livekit)
//
// Demo logins (password "classes" or $DEV_PASSWORD): teacher@wdf.test, learner@wdf.test, learner2@wdf.test
// Deleting the data file re-seeds the demo (subjects, classes, assignments).
//
// Optional env: PORT, BIND, ENV_FILE, DATA_FILE, UPLOAD_DIR, DEV_PASSWORD,
// WEB_DIR (also serve the built web app from this folder, same origin as the API).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

final cfg = Platform.environment;
final port = int.parse(cfg['PORT'] ?? '8787');
final password = cfg['DEV_PASSWORD'] ?? 'classes';
final webDir = cfg['WEB_DIR'];
final dataFile = File(cfg['DATA_FILE'] ?? 'tool/dev_data.json');
final uploadDir = cfg['UPLOAD_DIR'] ?? 'tool/uploads';

/// The WDF Tracker (app.wdf.church). When set, graduates sign in with their
/// Tracker login and their students come from the Tracker. Nothing is written back.
final trackerUrl = cfg['TRACKER_URL'];
const maxUpload = 20 * 1024 * 1024;

/// Users live in the data file: learners are created (with a username +
/// password) when their graduate enrols them.
List<Map<String, dynamic>> get allUsers => table('users');
Map<String, dynamic>? userById(Object? id) => allUsers.where((u) => u['id'] == id).firstOrNull;
Map<String, dynamic>? userByLogin(String login) {
  final l = login.toLowerCase().trim();
  return allUsers.where((u) => u['email'] == l || u['username'] == l).firstOrNull;
}

/// The 4 compulsory modules + the skills on the bursary form, one subject each.
const compulsory = ['Job Readiness', 'Financial Literacy', 'Business Management', 'Learners & Driver\'s Licence']; // Tracker spelling
const skills = [
  'Baking & Catering', 'Hairdressing & Beauty', 'Construction Management', 'Home Based Care', 'Retail Management',
  'Music / Dance / Art', 'Soccer / Netball', // the full bursary-form skill list
];

/// Everything persisted, in one JSON file.
late Map<String, dynamic> db;
List<Map<String, dynamic>> table(String name) => (db[name] as List).cast<Map<String, dynamic>>();
Map<String, dynamic> map(String name) => db[name] as Map<String, dynamic>;

late final String lkUrl, lkKey, lkSecret;
final sockets = <String, Set<WebSocket>>{}; // userId -> live connections

String newId() => '${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(1000)}';
String now() => DateTime.now().toUtc().toIso8601String();
DateTime at(Object? iso) => DateTime.parse(iso as String);

void main() async {
  final env = {
    for (final l in File(cfg['ENV_FILE'] ?? '../.env.livekit').readAsLinesSync())
      if (l.contains('=') && !l.startsWith('#')) l.substring(0, l.indexOf('=')): l.substring(l.indexOf('=') + 1),
  };
  lkUrl = env['LIVEKIT_URL']!;
  lkKey = env['LIVEKIT_API_KEY']!;
  lkSecret = env['LIVEKIT_API_SECRET']!;
  // (JSON round-trip so seeded collections are plain, growable dynamic maps/lists.)
  db = jsonDecode(dataFile.existsSync() ? dataFile.readAsStringSync() : jsonEncode(seed())) as Map<String, dynamic>;
  ensureSubjects([...compulsory, ...skills]); // every module/skill is available for hand-added learners
  save();

  Timer.periodic(const Duration(seconds: 30), (_) => reminders());
  final server = await HttpServer.bind(cfg['BIND'] ?? '0.0.0.0', port)..autoCompress = true;
  // ignore: avoid_print
  print('API on http://localhost:$port  ->  LiveKit $lkUrl${webDir != null ? '  (serving $webDir)' : ''}');
  // Every request runs concurrently: one slow phone (a big download on weak data, a stalled upload)
  // must never hold up anyone else's sign-in.
  await for (final req in server) {
    unawaited(serve(req));
  }
}

Future<void> serve(HttpRequest req) async {
  // A connection that stops moving is dropped instead of hanging forever.
  req.response.deadline = const Duration(minutes: 3);
  try {
    if (webDir != null && !req.uri.path.startsWith('/api/')) {
      await serveStatic(req);
    } else {
      await handle(req);
    }
  } catch (e) {
    try {
      send(req, 500, {'error': '$e'});
    } catch (_) {} // response already started / connection gone
  }
}

void save() => dataFile.writeAsStringSync(jsonEncode(db));

// ---------------------------------------------------------------- demo seed

Map<String, dynamic> seed() {
  final n = DateTime.now().toUtc();
  String iso(Duration d) => n.add(d).toIso8601String();
  final tomorrow9 = DateTime(n.year, n.month, n.day + 1, 7).toIso8601String(); // 09:00 SAST
  return {
    'tokens': <String, dynamic>{},
    'photos': <String, dynamic>{},
    'sent': <String, dynamic>{},
    'attendance': <String, dynamic>{},
    'extensions': <String, dynamic>{
      'a2': {'l2': iso(const Duration(days: 2))}, // Sipho got an extension
    },
    'notifications': <Map<String, dynamic>>[],
    'churches': [
      {'id': 'ch1', 'name': 'Grace Tabernacle Church'},
    ],
    'users': [
      {'id': 't1', 'name': 'Teacher Thandi', 'role': 'teacher', 'email': 'teacher@wdf.test'},
      {'id': 'g1', 'name': 'Nomsa Sithole', 'role': 'graduate', 'email': 'graduate@wdf.test', 'churchId': 'ch1'},
      // Enrolled demo learners (also sign in with their old demo emails).
      _learner('l1', 'Lerato Mokoena', '0821234567', 'Baking & Catering', enrolled: true, email: 'learner@wdf.test', username: 'lerato4821', pass: '582931'),
      _learner('l2', 'Sipho Dlamini', '0739876543', 'Construction Management', enrolled: true, email: 'learner2@wdf.test', username: 'sipho7310', pass: '904152'),
      // The graduate's church roster, waiting to be enrolled.
      _learner('l3', 'Thabo Nkosi', '0712345678', 'Baking & Catering'),
      _learner('l4', 'Naledi Khumalo', '0834567890', 'Hairdressing & Beauty'),
      _learner('l5', 'Kagiso Molefe', '0765432109', 'Construction Management'),
      _learner('l6', 'Zanele Dube', '0791122334', 'Home Based Care'),
      _learner('l7', 'Bongani Zulu', '0615566778', 'Retail Management'),
      _learner('l8', 'Palesa Ndlovu', '0829988776', 'Baking & Catering'),
    ],
    'subjects': [
      {'id': 's1', 'name': 'Job Readiness', 'teacherId': 't1', 'learnerIds': ['l1', 'l2']},
      {'id': 's2', 'name': 'Financial Literacy', 'teacherId': 't1', 'learnerIds': ['l1']},
      {'id': 's3', 'name': 'Business Management', 'teacherId': 't1', 'learnerIds': <String>[]},
      {'id': 's4', 'name': 'Learners & Driver\'s Licence', 'teacherId': 't1', 'learnerIds': <String>[]},
      for (var i = 0; i < skills.length; i++) {'id': 's${i + 5}', 'name': skills[i], 'teacherId': 't1', 'learnerIds': <String>[]},
    ],
    'sessions': [
      {'id': 'c1', 'subjectId': 's1', 'title': 'Job Readiness - CVs that get interviews', 'description': 'Live demo class.', 'teacherId': 't1', 'startsAt': iso(const Duration(minutes: -10)), 'minutes': 240},
      for (var w = 0; w < 4; w++)
        {'id': 'c2$w', 'subjectId': 's2', 'title': 'Financial Literacy - Budgeting', 'description': 'Weekly budgeting session.', 'teacherId': 't1', 'startsAt': DateTime.parse(tomorrow9).add(Duration(days: 7 * w)).toIso8601String(), 'minutes': 60},
    ],
    'assignments': [
      {'id': 'a1', 'subjectId': 's1', 'title': 'Write your CV', 'instructions': 'Write a one-page CV using the template from class. Upload it as PDF or Word.', 'dueAt': iso(const Duration(days: 3)), 'createdAt': iso(const Duration(days: -1))},
      {'id': 'a2', 'subjectId': 's1', 'title': 'Interview reflection', 'instructions': 'In one page, reflect on the mock interview: what went well and what you would do differently.', 'dueAt': iso(const Duration(days: -1)), 'createdAt': iso(const Duration(days: -5))},
      {'id': 'a3', 'subjectId': 's2', 'title': 'Monthly budget plan', 'instructions': 'Draw up a monthly budget for your household using the 50/30/20 rule.', 'dueAt': iso(const Duration(hours: 20)), 'createdAt': iso(const Duration(days: -2))},
    ],
    'submissions': [
      {'id': 'sub1', 'assignmentId': 'a2', 'learnerId': 'l1', 'file': storeFile('submissions', 'r.pdf', demoPdf('Interview reflection - Lerato Mokoena')), 'fileName': 'Interview reflection - Lerato.pdf', 'submittedAt': iso(const Duration(days: -2)), 'late': false, 'percent': 85, 'feedback': 'Clear and honest reflection. Work on giving specific examples.', 'markedAt': iso(const Duration(hours: -20))},
    ],
  };
}

/// A learner as captured on the bursary form: all 4 compulsory modules + one skill.
Map<String, dynamic> _learner(String id, String name, String cell, String skill,
        {bool enrolled = false, String? email, String? username, String? pass}) =>
    {
      'id': id,
      'name': name,
      'role': 'learner',
      'churchId': 'ch1',
      'cell': cell,
      'modules': compulsory,
      'skill': skill,
      'enrolled': enrolled,
      'email': ?email,
      'username': ?username,
      'password': ?pass,
    };

/// Easy to type, unique: first name + 4 digits, e.g. "thabo4821".
String newUsername(String name) {
  final first = name.split(' ').first.toLowerCase().replaceAll(RegExp('[^a-z]'), '');
  while (true) {
    final u = '${first.isEmpty ? 'learner' : first}${1000 + Random.secure().nextInt(9000)}';
    if (userByLogin(u) == null) return u;
  }
}

/// 6 digits — quick on a phone keypad.
String newPassword() => '${100000 + Random.secure().nextInt(900000)}';

/// A tiny one-page PDF so seeded submissions open like real ones.
Uint8List demoPdf(String text) {
  final stream = 'BT /F1 20 Tf 60 760 Td ($text) Tj ET';
  final objs = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
    '<< /Length ${stream.length} >>\nstream\n$stream\nendstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objs.length; i++) {
    offsets.add(out.length);
    out.write('${i + 1} 0 obj\n${objs[i]}\nendobj\n');
  }
  final xref = out.length;
  out.write('xref\n0 ${objs.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    out.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write('trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return Uint8List.fromList(latin1.encode(out.toString()));
}

// ---------------------------------------------------------------- helpers

void send(HttpRequest req, int status, Object? body) {
  req.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(body == null ? '' : jsonEncode(body))
    ..close();
}

Map<String, dynamic>? byId(String t, String id) => table(t).where((r) => r['id'] == id).firstOrNull;

/// Signed, expiring file links so files open in a browser tab / phone viewer
/// without an auth header.
String fileUrl(String key, {Duration ttl = const Duration(hours: 2)}) {
  final exp = DateTime.now().add(ttl).millisecondsSinceEpoch ~/ 1000;
  return '/api/classes/files/$key?exp=$exp&sig=${_sig('$key:$exp')}';
}

String _sig(String s) => Hmac(sha256, utf8.encode('files:$lkSecret')).convert(utf8.encode(s)).toString().substring(0, 32);

Map<String, dynamic> userJson(Map<String, dynamic> u) => {
      'id': u['id'],
      'name': u['name'],
      'role': u['role'],
      'company': ?u['company'], // graduates: MONARCH | WDF
      'photo': map('photos')[u['id']] == null ? null : fileUrl(map('photos')[u['id']] as String, ttl: const Duration(days: 365)),
    };

Map<String, dynamic>? subjectOf(Map<String, dynamic> row) => byId('subjects', row['subjectId'] as String);

bool inSubject(Map<String, dynamic> user, Map<String, dynamic>? s) =>
    s != null && (s['teacherId'] == user['id'] || (s['learnerIds'] as List).contains(user['id']));

List<String> learnersOf(Map<String, dynamic> s) => (s['learnerIds'] as List).cast<String>();

Future<Uint8List> readBody(HttpRequest req) async {
  final b = BytesBuilder(copy: false);
  // Give up on an upload that stops sending (phone lost signal) rather than waiting forever.
  await for (final chunk in req.timeout(const Duration(seconds: 60))) {
    b.add(chunk);
    if (b.length > maxUpload) throw const HttpException('File is larger than 20 MB.');
  }
  return b.takeBytes();
}

String storeFile(String kind, String name, Uint8List bytes) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : 'bin';
  final key = '$kind/${newId()}.$ext';
  File('$uploadDir/$key')
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);
  return key;
}

// ---------------------------------------------------------------- real-time

void push(Iterable<String> userIds, Map<String, dynamic> msg) {
  final data = jsonEncode(msg);
  for (final id in userIds) {
    for (final ws in sockets[id] ?? <WebSocket>{}) {
      ws.add(data);
    }
  }
}

/// Stores a notification per user and delivers it instantly to open apps.
void notify(Iterable<String> userIds, String title, String body, String link, String topic) {
  for (final id in userIds.toSet()) {
    final n = {'id': newId(), 'userId': id, 'title': title, 'body': body, 'link': link, 'createdAt': now(), 'read': false};
    table('notifications').add(n);
    push([id], {'type': 'notification', 'topic': topic, 'notification': n});
  }
  save();
}

/// Tells open apps to refresh a list (no notification shown).
void changed(Iterable<String> userIds, String topic) => push(userIds.toSet(), {'type': 'changed', 'topic': topic});

void reminders() {
  final n = DateTime.now().toUtc();
  final sent = map('sent');
  for (final s in table('sessions')) {
    final mins = at(s['startsAt']).difference(n).inMinutes;
    final key = 'class:${s['id']}:${s['startsAt']}';
    if (mins >= 0 && mins <= 15 && sent[key] == null) {
      sent[key] = true;
      final sub = subjectOf(s);
      if (sub != null) {
        notify([...learnersOf(sub), sub['teacherId'] as String], 'Class starts in ${mins < 1 ? '1' : mins} min',
            s['title'] as String, '/class/${s['id']}', 'sessions');
      }
    }
  }
  for (final a in table('assignments')) {
    final sub = subjectOf(a);
    if (sub == null) continue;
    for (final l in learnersOf(sub)) {
      final left = dueFor(a, l).difference(n);
      final key = 'due:${a['id']}:$l:${dueFor(a, l).toIso8601String()}';
      if (left > Duration.zero && left <= const Duration(hours: 24) && submissionOf(a['id'] as String, l) == null && sent[key] == null) {
        sent[key] = true;
        notify([l], 'Due in ${left.inHours < 1 ? 'under an hour' : '${left.inHours} hours'}', a['title'] as String,
            '/assignments/${a['id']}', 'assignments');
      }
    }
  }
  save();
}

// ---------------------------------------------------------------- assignments

DateTime dueFor(Map<String, dynamic> a, String learnerId) {
  final ext = (map('extensions')[a['id']] as Map?)?[learnerId];
  return at(ext ?? a['dueAt']);
}

Map<String, dynamic>? submissionOf(String assignmentId, String learnerId) =>
    table('submissions').where((s) => s['assignmentId'] == assignmentId && s['learnerId'] == learnerId).firstOrNull;

Map<String, dynamic> submissionJson(Map<String, dynamic> a, String learnerId) {
  final s = submissionOf(a['id'] as String, learnerId);
  final ext = (map('extensions')[a['id']] as Map?)?[learnerId];
  return {
    'learner': userJson(userById(learnerId)!),
    'dueAt': dueFor(a, learnerId).toIso8601String(),
    'extended': ext != null,
    if (s != null) ...{
      'fileName': s['fileName'],
      'fileUrl': s['file'] == null ? null : fileUrl(s['file'] as String),
      'submittedAt': s['submittedAt'],
      'late': s['late'],
      'percent': s['percent'],
      'feedback': s['feedback'],
      'markedAt': s['markedAt'],
    },
  };
}

Map<String, dynamic> assignmentJson(Map<String, dynamic> a, Map<String, dynamic> user, {bool detail = false}) {
  final sub = subjectOf(a)!;
  final teacher = sub['teacherId'] == user['id'];
  final learners = learnersOf(sub);
  final subs = table('submissions').where((s) => s['assignmentId'] == a['id']).toList();
  return {
    'id': a['id'],
    'subjectId': sub['id'],
    'subjectName': sub['name'],
    'title': a['title'],
    'instructions': a['instructions'],
    'dueAt': a['dueAt'],
    'briefName': a['briefName'],
    'briefUrl': a['brief'] == null ? null : fileUrl(a['brief'] as String),
    if (teacher) ...{
      'learnerCount': learners.length,
      'submittedCount': subs.length,
      'markedCount': subs.where((s) => s['percent'] != null).length,
      if (detail) 'submissions': [for (final l in learners) submissionJson(a, l)],
    } else
      'mine': submissionJson(a, user['id'] as String),
  };
}

// ---------------------------------------------------------------- WDF Tracker (read-only)

Future<(int, dynamic)> tracker(String method, String path, {String? token, Object? body}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.openUrl(method, Uri.parse('$trackerUrl$path'));
    req.headers.contentType = ContentType.json;
    if (token != null) req.headers.set('authorization', 'Bearer $token');
    if (body != null) req.write(jsonEncode(body));
    final res = await req.close().timeout(const Duration(seconds: 20));
    final text = await utf8.decodeStream(res);
    return (res.statusCode, text.isEmpty ? null : jsonDecode(text));
  } finally {
    client.close();
  }
}

/// Graduate signs in with their app.wdf.church login. Returns the local
/// graduate user, or an error message.
Future<(Map<String, dynamic>?, String?)> trackerGraduateLogin(String identifier, String pw) async {
  final (status, login) = await tracker('POST', '/api/graduate/login', body: {'identifier': identifier, 'password': pw});
  if (status != 200 || login is! Map || login['token'] == null) return (null, null);
  final token = login['token'] as String;
  final (_, meRaw) = await tracker('GET', '/api/graduate/me', token: token);
  final me = (meRaw is Map && meRaw['graduate'] is Map ? meRaw['graduate'] : meRaw) as Map? ?? const {};
  // /api/graduate/me calls the accepted company `company` (null until chosen).
  // Any graduate may sign in — Monarch or WDF, approved or still waiting — except rejected ones.
  // Only accepted Monarch graduates get their roster from the Tracker; everyone can add learners.
  final company = me['company'] ?? me['acceptedCompany'];
  if (me['status'] == 'REJECTED') {
    return (null, 'Your graduate application was not approved, so you can\'t sign in to WDF Classes.');
  }
  final id = 'grad_${login['graduateId']}';
  final u = userById(id) ?? (<String, dynamic>{'id': id, 'role': 'graduate'}..also(allUsers.add));
  u
    ..['name'] = login['name'] ?? me['name'] ?? 'Graduate'
    ..['company'] = company
    ..['status'] = me['status']
    ..['churchId'] = trackerChurchKey(me)
    ..['churchName'] = me['churchName']
    ..['trackerToken'] = token;
  return (u, null);
}

/// /api/graduate/me gives the church's name (no id) — graduates of the same church share it.
String trackerChurchKey(Map me) => 'tr_${me['churchId'] ?? me['churchName'] ?? me['id']}';

/// Refreshes a Tracker graduate's roster from their Students list on app.wdf.church.
/// Keeps each learner's WDF Classes state (enrolment, login, sign-ins).
Future<String?> syncRoster(Map<String, dynamic> grad) async {
  final (status, data) = await tracker('GET', '/api/graduate/students', token: grad['trackerToken'] as String?);
  if (status == 401) return 'Please sign in again.';
  if (status != 200 || data is! Map) return (data is Map ? data['error'] as String? : null) ?? 'Couldn\'t load your students from the WDF system.';
  for (final s in (data['students'] as List? ?? const []).cast<Map>()) {
    final id = s['memberId'] != null ? 'm_${s['memberId']}' : 'e_${s['id']}';
    final modules = ((s['modules'] as List?) ?? const []).map((e) => '$e').toList();
    final skill = s['skill'] as String?;
    ensureSubjects([...modules, ?skill]);
    final u = userById(id) ?? (<String, dynamic>{'id': id, 'role': 'learner'}..also(allUsers.add));
    u
      ..['name'] = s['name']
      ..['churchId'] = grad['churchId']
      ..['cell'] = s['contact'] ?? ''
      ..['modules'] = modules
      ..['skill'] = skill;
  }
  save();
  return null;
}

/// Every module/skill on a form becomes a subject (taught by the demo teacher for now).
void ensureSubjects(Iterable<String> names) {
  for (final n in names.where((n) => n.trim().isNotEmpty)) {
    if (table('subjects').any((s) => s['name'] == n)) continue;
    table('subjects').add({'id': 'sub_${n.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '_')}', 'name': n, 'teacherId': 't1', 'learnerIds': []});
  }
}

extension<T> on T {
  T also(void Function(T) f) {
    f(this);
    return this;
  }
}

// ---------------------------------------------------------------- graduates & enrolment

List<String> graduatesOf(Map<String, dynamic> learner) =>
    [for (final g in allUsers) if (g['role'] == 'graduate' && g['churchId'] == learner['churchId']) g['id'] as String];

/// The graduate hears when their learners sign in — first time always, then
/// at most once a day per learner so a busy class doesn't flood them.
void learnerSignedIn(Map<String, dynamic> u) {
  final first = u['lastLoginAt'] == null;
  final today = now().substring(0, 10);
  u['lastLoginAt'] = now();
  if (first || u['loginNotifiedOn'] != today) {
    u['loginNotifiedOn'] = today;
    notify(graduatesOf(u), first ? '${u['name']} signed in for the first time' : '${u['name']} signed in', 'WDF Classes', '/students', 'students');
  } else {
    changed(graduatesOf(u), 'students');
  }
}

/// Subjects pre-ticked from the learner's bursary form (modules + chosen skill).
List<String> formSubjectIds(Map<String, dynamic> u) => [
      for (final s in table('subjects'))
        if (((u['modules'] as List?) ?? const []).contains(s['name']) || u['skill'] == s['name']) s['id'] as String,
    ];

void enrol(Map<String, dynamic> u, List<String> subjectIds) {
  for (final s in table('subjects')) {
    final ids = s['learnerIds'] as List;
    ids.remove(u['id']);
    if (subjectIds.contains(s['id'])) ids.add(u['id']);
  }
  u['enrolled'] = subjectIds.isNotEmpty;
  u['username'] ??= newUsername(u['name'] as String);
  u['password'] ??= newPassword();
}

Map<String, dynamic> studentJson(Map<String, dynamic> u) => {
      ...userJson(u),
      'cell': u['cell'],
      'modules': u['modules'] ?? const [],
      'skill': u['skill'],
      'enrolled': u['enrolled'] == true,
      'username': u['username'],
      'password': u['password'],
      'lastLoginAt': u['lastLoginAt'],
      'subjectIds': [for (final s in table('subjects')) if (learnersOf(s).contains(u['id'])) s['id']],
      'formSubjectIds': formSubjectIds(u),
    };

// ---------------------------------------------------------------- routes

Future<void> handle(HttpRequest req) async {
  req.response.headers
    ..set('access-control-allow-origin', '*')
    ..set('access-control-allow-headers', 'authorization, content-type, x-filename')
    ..set('access-control-allow-methods', 'GET, POST, PUT, DELETE, OPTIONS');
  if (req.method == 'OPTIONS') return send(req, 204, null);

  final path = req.uri.path.replaceFirst('/api/classes', '');
  final seg = path.split('/').where((s) => s.isNotEmpty).toList();
  final m = req.method;

  // Signed file download (no auth header — links open in a new tab / viewer).
  if (m == 'GET' && seg.isNotEmpty && seg[0] == 'files') {
    final key = seg.skip(1).join('/');
    final exp = int.tryParse(req.uri.queryParameters['exp'] ?? '') ?? 0;
    final f = File('$uploadDir/$key');
    if (exp * 1000 < DateTime.now().millisecondsSinceEpoch || req.uri.queryParameters['sig'] != _sig('$key:$exp') || !f.existsSync()) {
      return send(req, 404, {'error': 'This link has expired. Go back and open the file again.'});
    }
    final ext = key.split('.').last;
    req.response.headers
      ..set('content-type', _types[ext] ?? 'application/octet-stream')
      ..set('cache-control', 'private, max-age=86400');
    await req.response.addStream(f.openRead());
    return req.response.close();
  }

  final isUpload = req.headers.contentType?.mimeType == 'application/octet-stream';
  final body = m == 'GET' || isUpload ? const {} : (jsonDecode(await utf8.decodeStream(req).then((s) => s.isEmpty ? '{}' : s)) as Map);

  if (m == 'POST' && path == '/auth/login') {
    final login = (body['email'] as String? ?? '').toLowerCase().trim();
    var u = userByLogin(login);
    // Not a WDF Classes account → maybe a graduate signing in with their app.wdf.church login.
    if (u == null && trackerUrl != null) {
      final (Map<String, dynamic>?, String?) r;
      try {
        r = await trackerGraduateLogin((body['email'] as String? ?? '').trim(), body['password'] as String? ?? '');
      } catch (_) {
        return send(req, 503, {'error': 'Can\'t reach the WDF system right now. Try again in a minute.'});
      }
      final (g, err) = r;
      if (err != null) return send(req, 403, {'error': err});
      if (g != null) {
        final t = base64Url.encode(List.generate(24, (_) => Random.secure().nextInt(256)));
        map('tokens')[t] = g['id'];
        save();
        return send(req, 200, {'token': t, 'user': userJson(g)});
      }
    }
    // Username → the learner's own password; demo emails → the shared demo password.
    final expected = u != null && u['username'] == login ? u['password'] : password;
    if (u == null || body['password'] != expected) return send(req, 401, {'error': 'Wrong username or password.'});
    if (u['role'] == 'learner' && u['enrolled'] != true) {
      return send(req, 403, {'error': 'You\'re not enrolled yet. Ask your graduate to enrol you.'});
    }
    final t = base64Url.encode(List.generate(24, (_) => Random.secure().nextInt(256)));
    map('tokens')[t] = u['id'];
    if (u['role'] == 'learner') learnerSignedIn(u);
    save();
    return send(req, 200, {'token': t, 'user': userJson(u)});
  }

  // app.wdf.church (the church app) shows each student's WDF Classes status on the graduate's
  // Students tab. It calls this with the graduate's own app.wdf.church session — no second login.
  if (m == 'GET' && path == '/tracker/students' && trackerUrl != null) {
    final trackerToken = req.headers.value('authorization')?.replaceFirst('Bearer ', '');
    if (trackerToken == null) return send(req, 401, {'error': 'Not logged in.'});
    final (status, meRaw) = await tracker('GET', '/api/graduate/me', token: trackerToken);
    final me = (meRaw is Map && meRaw['graduate'] is Map ? meRaw['graduate'] : meRaw) as Map? ?? const {};
    if (status != 200 || me['id'] == null) return send(req, 401, {'error': 'Not logged in.'});
    final id = 'grad_${me['id']}';
    final g = userById(id) ?? (<String, dynamic>{'id': id, 'role': 'graduate'}..also(allUsers.add));
    g
      ..['name'] = me['name'] ?? g['name'] ?? 'Graduate'
      ..['churchId'] = trackerChurchKey(me)
      ..['trackerToken'] = trackerToken;
    final err = await syncRoster(g);
    if (err != null) return send(req, 403, {'error': err});
    return send(req, 200, {
      'classesUrl': cfg['PUBLIC_URL'] ?? 'https://learn.wdf.church',
      'students': [
        for (final u in allUsers)
          if (u['role'] == 'learner' && u['churchId'] == g['churchId'])
            {
              'key': u['id'],
              'enrolled': u['enrolled'] == true,
              'username': u['username'],
              'password': u['password'],
              'lastLoginAt': u['lastLoginAt'],
            },
      ],
    });
  }

  final token = req.headers.value('authorization')?.replaceFirst('Bearer ', '') ?? req.uri.queryParameters['token'];
  final user = userById(map('tokens')[token]);
  if (user == null) return send(req, 401, {'error': 'Please sign in again.'});
  final uid = user['id'] as String;
  final teacher = user['role'] == 'teacher';

  // Live connection: notifications + "refresh" events.
  if (path == '/ws' && WebSocketTransformer.isUpgradeRequest(req)) {
    final ws = await WebSocketTransformer.upgrade(req);
    ws.pingInterval = const Duration(seconds: 25);
    (sockets[uid] ??= {}).add(ws);
    ws.listen((_) {}, onDone: () => sockets[uid]?.remove(ws));
    return;
  }

  // ---- me
  if (m == 'GET' && path == '/me') return send(req, 200, userJson(user));
  if (m == 'POST' && path == '/me/photo') {
    final bytes = await readBody(req);
    if (bytes.length < 1000) return send(req, 400, {'error': 'That photo looks empty. Try again.'});
    map('photos')[uid] = storeFile('photos', 'photo.jpg', bytes);
    save();
    return send(req, 200, userJson(user));
  }

  // ---- subjects
  if (m == 'GET' && path == '/subjects') {
    return send(req, 200, [
      for (final s in table('subjects'))
        // Graduates see every subject — they choose which ones to enrol learners into.
        if (inSubject(user, s) || user['role'] == 'graduate')
          {
            'id': s['id'],
            'name': s['name'],
            'teacherName': userById(s['teacherId'])?['name'],
            if (s['teacherId'] == uid) 'learners': [for (final l in learnersOf(s)) userJson(userById(l)!)],
          },
    ]);
  }

  // ---- graduate: their church's learners (enrol, see logins, reset passwords)
  if (seg.isNotEmpty && seg[0] == 'students') {
    if (user['role'] != 'graduate') return send(req, 403, {'error': 'Only graduates manage students.'});
    // Accepted Monarch graduates: pull their current students from the WDF Tracker first. Everyone
    // else (WDF, not yet approved) works from their church's list as last loaded, and can add learners.
    final canSync = user['trackerToken'] != null && user['company'] == 'MONARCH' && user['status'] == 'ACCEPTED';
    if (m == 'GET' && seg.length == 1 && canSync) {
      final err = await syncRoster(user);
      if (err != null) return send(req, err.startsWith('Please sign in') ? 401 : 502, {'error': err});
    }
    final roster = [for (final u in allUsers) if (u['role'] == 'learner' && u['churchId'] == user['churchId']) u];
    if (m == 'GET' && seg.length == 1) return send(req, 200, [for (final u in roster) studentJson(u)]);
    // Add a learner by hand (not in the WDF system) and enrol them straight away.
    if (m == 'POST' && seg.length == 1) {
      final name = (body['name'] as String? ?? '').trim().replaceAll(RegExp(r'\s+'), ' ');
      final cell = (body['cell'] as String? ?? '').replaceAll(RegExp('[^0-9]'), '');
      final skill = (body['skill'] as String?)?.trim();
      final modules = ((body['modules'] as List?) ?? compulsory).map((e) => '$e').toList();
      if (name.split(' ').length < 2) return send(req, 400, {'error': 'Enter the learner\'s name and surname.'});
      if (!RegExp(r'^0[6-8]\d{8}$').hasMatch(cell)) return send(req, 400, {'error': 'Enter a valid 10-digit cell number, e.g. 0821234567.'});
      final dup = roster.where((u) => u['cell'] == cell).firstOrNull;
      if (dup != null) return send(req, 409, {'error': '${dup['name']} already has this cell number at your church.'});
      ensureSubjects([...modules, ?skill]);
      final u = <String, dynamic>{
        'id': 'x_${newId()}',
        'role': 'learner',
        'name': name,
        'churchId': user['churchId'],
        'cell': cell,
        'modules': modules,
        'skill': skill,
        'addedBy': uid, // added in WDF Classes — not in the WDF Tracker
      };
      allUsers.add(u);
      enrol(u, formSubjectIds(u));
      save();
      changed(graduatesOf(u), 'students');
      return send(req, 201, studentJson(u));
    }
    if (m == 'POST' && path == '/students/enrol-all') {
      final waiting = roster.where((u) => u['enrolled'] != true).toList();
      for (final u in waiting) {
        enrol(u, formSubjectIds(u));
      }
      save();
      changed([uid], 'students');
      return send(req, 200, {'enrolled': waiting.length});
    }
    final u = roster.where((x) => seg.length > 1 && x['id'] == seg[1]).firstOrNull;
    if (u == null) return send(req, 404, {'error': 'That learner is not at your church.'});
    final action = seg.length == 3 ? seg[2] : null;
    if (m == 'POST' && action == 'enrol') {
      enrol(u, ((body['subjectIds'] as List?) ?? formSubjectIds(u)).cast<String>());
      save();
      return send(req, 200, studentJson(u));
    }
    if (m == 'POST' && action == 'reset-password') {
      u['password'] = newPassword();
      map('tokens').removeWhere((_, id) => id == u['id']); // signs them out everywhere
      save();
      return send(req, 200, studentJson(u));
    }
  }

  // ---- notifications
  if (m == 'GET' && path == '/notifications') {
    final mine = table('notifications').where((n) => n['userId'] == uid).toList().reversed.take(100).toList();
    return send(req, 200, mine);
  }
  if (m == 'POST' && path == '/notifications/read') {
    final ids = (body['ids'] as List?)?.cast<String>();
    for (final n in table('notifications')) {
      if (n['userId'] == uid && (ids == null || ids.contains(n['id']))) n['read'] = true;
    }
    save();
    return send(req, 200, {'ok': true});
  }

  // ---- sessions (classes)
  Map<String, dynamic> sessionJson(Map<String, dynamic> s) =>
      {...s, 'subjectName': subjectOf(s)?['name'] ?? '', 'teacherName': userById(s['teacherId'])?['name'] ?? ''};

  if (m == 'GET' && path == '/sessions') {
    final since = DateTime.now().toUtc().subtract(const Duration(hours: 24));
    return send(req, 200, [
      for (final s in table('sessions'))
        if (at(s['startsAt']).isAfter(since) && inSubject(user, subjectOf(s))) sessionJson(s),
    ]);
  }
  if (m == 'POST' && path == '/sessions') {
    final sub = byId('subjects', body['subjectId'] as String? ?? '');
    if (!teacher || sub?['teacherId'] != uid) return send(req, 403, {'error': 'Choose one of your subjects.'});
    final start = at(body['startsAt']);
    final weeks = body['repeatWeeks'] as int? ?? 0;
    for (var w = 0; w <= weeks; w++) {
      table('sessions').add({
        'id': newId(),
        'subjectId': sub!['id'],
        'title': body['title'],
        'description': body['description'] ?? '',
        'teacherId': uid,
        'startsAt': start.add(Duration(days: 7 * w)).toUtc().toIso8601String(),
        'minutes': body['minutes'],
      });
    }
    notify(learnersOf(sub!), 'New class: ${body['title']}', '${sub['name']}${weeks > 0 ? ' · every week' : ''}', '/', 'sessions');
    return send(req, 201, {'ok': true});
  }
  if (seg.length >= 2 && seg[0] == 'sessions') {
    final s = byId('sessions', seg[1]);
    if (s == null || !inSubject(user, subjectOf(s))) return send(req, 404, {'error': 'That class no longer exists.'});
    final owner = s['teacherId'] == uid;
    final action = seg.length == 3 ? seg[2] : null;
    final learners = learnersOf(subjectOf(s)!);

    if (m == 'GET' && action == null) return send(req, 200, sessionJson(s));
    if (m == 'PUT' && action == null) {
      if (!owner) return send(req, 403, {'error': 'Only this class\'s teacher can edit it.'});
      final moved = s['startsAt'] != at(body['startsAt']).toUtc().toIso8601String();
      s
        ..['title'] = body['title']
        ..['description'] = body['description'] ?? ''
        ..['startsAt'] = at(body['startsAt']).toUtc().toIso8601String()
        ..['minutes'] = body['minutes'];
      save();
      if (moved) {
        notify(learners, 'Class moved: ${s['title']}', 'Check the new time on your timetable.', '/', 'sessions');
      } else {
        changed(learners, 'sessions');
      }
      return send(req, 200, sessionJson(s));
    }
    if (m == 'DELETE' && action == null) {
      if (!owner) return send(req, 403, {'error': 'Only this class\'s teacher can delete it.'});
      table('sessions').remove(s);
      notify(learners, 'Class cancelled: ${s['title']}', 'This class has been removed from your timetable.', '/', 'sessions');
      return send(req, 200, {'ok': true});
    }
    if (m == 'GET' && action == 'attendance') {
      if (!owner) return send(req, 403, {'error': 'Teachers only.'});
      return send(req, 200, [
        for (final id in ((map('attendance')[s['id']] as Map?) ?? {}).keys)
          if (userById(id) != null) userJson(userById(id)!),
      ]);
    }
    if (m == 'POST' && action == 'join') {
      final start = at(s['startsAt']);
      final end = start.add(Duration(minutes: s['minutes'] as int));
      final n = DateTime.now().toUtc();
      final open = n.isAfter(start.subtract(const Duration(minutes: 15))) && n.isBefore(end);
      if (!owner && !open) return send(req, 403, {'error': 'This class opens 15 minutes before it starts.'});
      if (!owner) ((map('attendance')[s['id'] as String] ??= <String, dynamic>{}) as Map)[uid] = now();
      save();
      return send(req, 200, {'url': lkUrl, 'token': liveKitToken(user, 'class-${s['id']}', admin: owner)});
    }
  }

  // ---- assignments
  if (m == 'GET' && path == '/assignments') {
    return send(req, 200, [
      for (final a in table('assignments'))
        if (inSubject(user, subjectOf(a))) assignmentJson(a, user),
    ]);
  }
  if (m == 'POST' && path == '/assignments') {
    final sub = byId('subjects', body['subjectId'] as String? ?? '');
    if (!teacher || sub?['teacherId'] != uid) return send(req, 403, {'error': 'Choose one of your subjects.'});
    final a = {
      'id': newId(),
      'subjectId': sub!['id'],
      'title': body['title'],
      'instructions': body['instructions'] ?? '',
      'dueAt': at(body['dueAt']).toUtc().toIso8601String(),
      'createdAt': now(),
    };
    table('assignments').add(a);
    save();
    return send(req, 201, assignmentJson(a, user));
  }
  if (seg.length >= 2 && seg[0] == 'assignments') {
    final a = byId('assignments', seg[1]);
    final sub = a == null ? null : subjectOf(a);
    if (a == null || !inSubject(user, sub)) return send(req, 404, {'error': 'That assignment no longer exists.'});
    final owner = sub!['teacherId'] == uid;
    final action = seg.length == 3 ? seg[2] : null;
    final learners = learnersOf(sub);
    final link = '/assignments/${a['id']}';
    if (!owner && m != 'GET' && action != 'submit') return send(req, 403, {'error': 'Only the subject teacher can do that.'});

    if (m == 'GET' && action == null) return send(req, 200, assignmentJson(a, user, detail: true));
    if (m == 'PUT' && action == null) {
      a
        ..['title'] = body['title']
        ..['instructions'] = body['instructions'] ?? '';
      save();
      changed(learners, 'assignments');
      return send(req, 200, assignmentJson(a, user));
    }
    if (m == 'DELETE' && action == null) {
      table('assignments').remove(a);
      table('submissions').removeWhere((s) => s['assignmentId'] == a['id']);
      save();
      changed(learners, 'assignments');
      return send(req, 200, {'ok': true});
    }
    // Teacher attaches the brief, then publishes (so learners are notified once, with the file ready).
    if (m == 'POST' && action == 'brief') {
      final name = Uri.decodeComponent(req.headers.value('x-filename') ?? 'brief.pdf');
      a
        ..['brief'] = storeFile('briefs', name, await readBody(req))
        ..['briefName'] = name;
      save();
      return send(req, 200, assignmentJson(a, user));
    }
    if (m == 'POST' && action == 'publish') {
      notify(learners, 'New assignment: ${a['title']}', '${sub['name']} · due ${_day(at(a['dueAt']))}', link, 'assignments');
      return send(req, 200, {'ok': true});
    }
    if (m == 'POST' && action == 'extend') {
      final due = at(body['dueAt']).toUtc().toIso8601String();
      final learnerId = body['learnerId'] as String?;
      if (learnerId == null) {
        a['dueAt'] = due;
        (map('extensions')[a['id'] as String] as Map?)?.clear();
        notify(learners, 'Deadline extended: ${a['title']}', 'New deadline: ${_day(at(due))}', link, 'assignments');
      } else {
        ((map('extensions')[a['id'] as String] ??= <String, dynamic>{}) as Map)[learnerId] = due;
        notify([learnerId], 'You got an extension: ${a['title']}', 'Your new deadline: ${_day(at(due))}', link, 'assignments');
      }
      save();
      return send(req, 200, assignmentJson(a, user, detail: true));
    }
    if (m == 'POST' && action == 'submit') {
      if (teacher) return send(req, 403, {'error': 'Only learners submit assignments.'});
      final name = Uri.decodeComponent(req.headers.value('x-filename') ?? 'submission.pdf');
      final ext = name.split('.').last.toLowerCase();
      if (!['pdf', 'doc', 'docx'].contains(ext)) return send(req, 400, {'error': 'Upload a PDF or Word document.'});
      final bytes = await readBody(req);
      final late = DateTime.now().toUtc().isAfter(dueFor(a, uid));
      table('submissions').removeWhere((s) => s['assignmentId'] == a['id'] && s['learnerId'] == uid);
      table('submissions').add({
        'id': newId(),
        'assignmentId': a['id'],
        'learnerId': uid,
        'file': storeFile('submissions', name, bytes),
        'fileName': name,
        'submittedAt': now(),
        'late': late,
      });
      notify([sub['teacherId'] as String], '${user['name']} submitted${late ? ' LATE' : ''}', a['title'] as String, link, 'assignments');
      return send(req, 200, assignmentJson(a, user));
    }
    if (m == 'POST' && action == 'mark') {
      final s = submissionOf(a['id'] as String, body['learnerId'] as String? ?? '');
      final p = body['percent'];
      if (s == null) return send(req, 400, {'error': 'Nothing submitted yet.'});
      if (p is! int || p < 0 || p > 100) return send(req, 400, {'error': 'Enter a mark from 0 to 100%.'});
      s
        ..['percent'] = p
        ..['feedback'] = body['feedback'] ?? ''
        ..['markedAt'] = now();
      notify([s['learnerId'] as String], 'Marked: ${a['title']}', 'You got $p%', link, 'assignments');
      return send(req, 200, assignmentJson(a, user, detail: true));
    }
  }
  send(req, 404, {'error': 'Not found'});
}

String _day(DateTime d) {
  final l = d.toLocal();
  const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${l.day} ${mo[l.month - 1]} ${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

// ---------------------------------------------------------------- static web

const _types = {
  'html': 'text/html; charset=utf-8',
  'js': 'text/javascript',
  'mjs': 'text/javascript',
  'wasm': 'application/wasm',
  'json': 'application/json',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'ico': 'image/x-icon',
  'ttf': 'font/ttf',
  'otf': 'font/otf',
  'css': 'text/css',
  'pdf': 'application/pdf',
  'doc': 'application/msword',
  'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'apk': 'application/vnd.android.package-archive',
};

/// Built Flutter web app. Unknown paths fall back to index.html; ETags let
/// returning visitors revalidate with a cheap 304 instead of re-downloading.
Future<void> serveStatic(HttpRequest req) async {
  final rel = Uri.decodeComponent(req.uri.path).replaceAll('..', '');
  var file = File('$webDir${rel == '/' ? '/index.html' : rel}');
  if (!file.existsSync()) file = File('$webDir/index.html');
  final stat = file.statSync();
  final etag = '"${stat.modified.millisecondsSinceEpoch}-${stat.size}"';
  final res = req.response
    ..headers.set('etag', etag)
    ..headers.set('cache-control', 'no-cache')
    ..headers.set('content-type', _types[file.path.split('.').last] ?? 'application/octet-stream');
  if (req.headers.value('if-none-match') == etag) {
    res.statusCode = 304;
    return res.close();
  }
  await res.addStream(file.openRead());
  await res.close();
}

/// LiveKit access token (HS256 JWT). The class's own teacher gets roomAdmin
/// for that room only — used to mute / remove learners.
String liveKitToken(Map<String, dynamic> user, String room, {required bool admin}) {
  String b64(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  final n = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final photo = userJson(user)['photo'];
  final head = b64({'alg': 'HS256', 'typ': 'JWT'});
  final claims = b64({
    'iss': lkKey,
    'sub': user['id'],
    'name': user['name'],
    'nbf': n - 10,
    'exp': n + 6 * 3600,
    'attributes': {'role': user['role'], 'photo': ?photo},
    'video': {
      'room': room,
      'roomJoin': true,
      'canPublish': true,
      'canSubscribe': true,
      'canPublishData': true,
      'canUpdateOwnMetadata': true,
      if (admin) 'roomAdmin': true,
    },
  });
  final sig = base64Url.encode(Hmac(sha256, utf8.encode(lkSecret)).convert(utf8.encode('$head.$claims')).bytes).replaceAll('=', '');
  return '$head.$claims.$sig';
}
