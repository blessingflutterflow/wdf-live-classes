import sys
root = '/root/church_App/demo_app/lib/'

# ---- 1. api_client.dart: one call to WDF Classes
p = root + 'services/api_client.dart'; s = open(p, encoding='utf-8').read()
anchor = "  Future<ApiResult> listStudents(String token) async => _authGet('/api/graduate/students', token);\n"
assert anchor in s, 'api anchor'
if 'classesStudents' not in s:
    s = s.replace(anchor, anchor + '''
  /// WDF CLASSES (learn.wdf.church, 28 Sep 2026) — each student's class enrolment and class login,
  /// for the Head of Curriculum. Sent with the graduate's own session: WDF Classes checks it against
  /// /api/graduate/me, so there is no second login. Enrolling happens on WDF Classes itself.
  static const String classesUrl = String.fromEnvironment('CLASSES_URL', defaultValue: 'https://learn.wdf.church');
  Future<ApiResult> classesStudents(String token) async {
    try {
      final res = await http.get(Uri.parse('$classesUrl/api/classes/tracker/students'),
          headers: {'Authorization': 'Bearer $token'}).timeout(const Duration(seconds: 12));
      final data = res.body.isNotEmpty ? jsonDecode(res.body) as Map<String, dynamic> : <String, dynamic>{};
      if (res.statusCode >= 200 && res.statusCode < 300) return ApiResult.ok(data);
      return ApiResult.error((data['error'] as String?) ?? 'WDF Classes is unavailable.');
    } catch (_) {
      return ApiResult.error('Could not reach WDF Classes.');
    }
  }
''')
    open(p, 'w', encoding='utf-8').write(s)

# ---- 2. monarch_console_screen.dart: the WDF Classes box on each student card
p = root + 'screens/graduate/monarch_console_screen.dart'; s = open(p, encoding='utf-8').read()
if '_classesBox' in s:
    print('already patched'); sys.exit(0)

def rep(old, new):
    global s
    assert s.count(old) == 1, 'anchor not unique: ' + old[:60]
    s = s.replace(old, new)

rep("import 'package:flutter/material.dart';\n", "import 'package:flutter/material.dart';\nimport 'package:flutter/services.dart';\n")
rep("  List<Map<String, dynamic>> _students = [];\n", '''  List<Map<String, dynamic>> _students = [];
  // WDF CLASSES — keyed 'm_<memberId>' (or 'e_<enrolmentId>'); empty if WDF Classes can't be reached,
  // in which case the cards simply show no class box.
  Map<String, Map<String, dynamic>> _classes = {};
  String _classesUrl = ApiClient.classesUrl;
''')
rep("    final signups = await ApiClient.instance.listSignups(token);\n",
    "    final classesFuture = ApiClient.instance.classesStudents(token); // in parallel with the rest\n    final signups = await ApiClient.instance.listSignups(token);\n")
rep("    final handovers = await ApiClient.instance.graduateHandovers(token);\n",
    "    final handovers = await ApiClient.instance.graduateHandovers(token);\n    final classes = await classesFuture;\n")
rep("        _congregationChurch = handovers.data['churchName'] as String?;\n      }\n",
    '''        _congregationChurch = handovers.data['churchName'] as String?;
      }
      if (classes.success) {
        _classes = {
          for (final e in (classes.data['students'] as List? ?? const []))
            '${(e as Map)['key']}': e.cast<String, dynamic>(),
        };
        _classesUrl = (classes.data['classesUrl'] as String?) ?? _classesUrl;
      }
''')
rep("          ),\n        ],\n      ]),\n    );\n  }\n\n  Widget _empty(",
    "          ),\n        ],\n\n        _classesBox(s),\n      ]),\n    );\n  }\n\n" + '''  // ⚠️ WDF CLASSES, ON THE CARD (Nosipho, 28 Sep 2026: graduates enrol learners on WDF Classes and must
  // see their details here too). Enrolled or not, the class login the graduate hands over, and whether
  // the learner has ever signed in. Read from learn.wdf.church; enrolling itself happens there.
  Widget _classesBox(Map<String, dynamic> s) {
    final memberId = '${s['memberId'] ?? ''}';
    final c = _classes[memberId.isNotEmpty ? 'm_$memberId' : 'e_${s['id']}'];
    if (c == null) return const SizedBox.shrink();
    const brand = Color(0xFFE0284A);
    final enrolled = c['enrolled'] == true;
    final last = DateTime.tryParse('${c['lastLoginAt'] ?? ''}')?.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return Container(
      margin: const EdgeInsets.only(top: Insets.sm),
      padding: const EdgeInsets.all(Insets.sm),
      decoration: BoxDecoration(
        color: brand.withValues(alpha: 0.05),
        borderRadius: Corners.rSm,
        border: Border.all(color: brand.withValues(alpha: 0.35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.videocam_outlined, size: 15, color: brand),
          const SizedBox(width: Insets.xs),
          Expanded(child: Text('WDF Classes', style: AppText.bodySmStrong.copyWith(color: brand))),
          Text(
            !enrolled ? 'Not enrolled' : last == null ? 'Never signed in' : 'Active',
            style: AppText.caption.copyWith(
                fontWeight: FontWeight.w700,
                color: !enrolled ? Colors.amber.shade800 : last == null ? brand : Colors.green.shade700),
          ),
        ]),
        const SizedBox(height: 2),
        if (!enrolled)
          Text('Enrol them on WDF Classes to give them a class login.',
              style: AppText.caption.copyWith(color: AppColors.bodyMid))
        else ...[
          _loginRow('Username', '${c['username'] ?? ''}'),
          _loginRow('Password', '${c['password'] ?? ''}'),
          Text(
            last == null
                ? 'Has not signed in yet — make sure they got their login.'
                : 'Last signed in ${last.day}/${last.month} at ${two(last.hour)}:${two(last.minute)}',
            style: AppText.caption.copyWith(color: AppColors.bodyMid),
          ),
        ],
        const SizedBox(height: Insets.xs),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => html.window.open(_classesUrl, '_blank'),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: Text(enrolled ? 'Open WDF Classes' : 'Enrol on WDF Classes'),
            style: OutlinedButton.styleFrom(foregroundColor: brand),
          ),
        ),
      ]),
    );
  }

  Widget _loginRow(String label, String value) => Row(children: [
        Text('$label: ', style: AppText.caption.copyWith(color: AppColors.bodyMid)),
        SelectableText(value, style: AppText.bodySmStrong),
        IconButton(
          tooltip: 'Copy $label',
          visualDensity: VisualDensity.compact,
          iconSize: 16,
          onPressed: () {
            Clipboard.setData(ClipboardData(text: value));
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label copied')));
          },
          icon: const Icon(Icons.copy_outlined),
        ),
      ]);

  Widget _empty(''')
open(p, 'w', encoding='utf-8').write(s)
print('patched')
