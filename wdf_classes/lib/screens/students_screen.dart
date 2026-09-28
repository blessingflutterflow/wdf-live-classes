import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../format.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets.dart';

/// Graduate (Head of Curriculum): enrol the church's learners into classes,
/// hand out their logins, and see who has signed in.
class StudentsScreen extends StatefulWidget {
  const StudentsScreen({super.key});

  @override
  State<StudentsScreen> createState() => _StudentsScreenState();
}

enum _Filter { all, waiting, never, active }

class _StudentsScreenState extends State<StudentsScreen> {
  List<Student>? _students;
  List<Subject> _subjects = [];
  String? _error, _selected;
  var _filter = _Filter.all;
  final _search = TextEditingController();
  late final StreamSubscription<String> _sub;

  @override
  void initState() {
    super.initState();
    _load();
    auth.api.subjects().then((s) => mounted ? setState(() => _subjects = s) : null, onError: (_) {});
    // Learners signing in update the list live.
    _sub = live.changes.where((t) => t == 'students').listen((_) => _load());
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await auth.api.students();
      s.sort((a, b) => a.user.name.compareTo(b.user.name));
      if (mounted) {
        setState(() {
          _students = s;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _enrolAll(int waiting) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Enrol everyone waiting?', style: T.title),
        content: Text('$waiting learners will be enrolled in the subjects they chose on their form, and each gets a username and password.',
            style: T.body),
        actionsPadding: const EdgeInsets.all(S.lg),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text('Enrol $waiting')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final n = await auth.api.enrolAll();
      if (mounted) toast(context, '$n learners enrolled. Share their logins with them.');
      _load();
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
  }

  Future<void> _add() async {
    final added = await showModalBottomSheet<Student>(
      context: context,
      useRootNavigator: true, // above the bottom tab bar
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 680),
      builder: (sheet) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheet).bottom),
        child: _AddLearner(subjects: _subjects),
      ),
    );
    if (added == null || !mounted) return;
    await _load();
    if (!mounted) return;
    toast(context, '${added.user.name.split(' ').first} is added and enrolled. Share their login.');
    _open(_students!.firstWhere((s) => s.user.id == added.user.id, orElse: () => added), MediaQuery.sizeOf(context).width >= 1000);
  }

  void _open(Student s, bool wide) {
    if (wide) return setState(() => _selected = s.user.id);
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true, // above the bottom tab bar
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 680),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .9,
        maxChildSize: .95,
        builder: (_, scroll) => SingleChildScrollView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(S.lg, 0, S.lg, S.xl),
          child: _StudentPanel(s, subjects: _subjects, onChanged: _load),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final all = _students ?? [];
    final waiting = all.where((s) => !s.enrolled).length;
    final never = all.where((s) => s.enrolled && s.lastLoginAt == null).length;
    final active = all.where((s) => s.lastLoginAt != null).length;
    final q = _search.text.trim().toLowerCase();
    final shown = all.where((s) {
      final match = q.isEmpty || s.user.name.toLowerCase().contains(q) || s.cell.contains(q) || (s.username ?? '').contains(q);
      return match &&
          switch (_filter) {
            _Filter.all => true,
            _Filter.waiting => !s.enrolled,
            _Filter.never => s.enrolled && s.lastLoginAt == null,
            _Filter.active => s.lastLoginAt != null,
          };
    }).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Students'), titleSpacing: S.lg),
      floatingActionButton: _students == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _add,
              backgroundColor: C.primary,
              foregroundColor: Colors.white,
              extendedPadding: const EdgeInsets.symmetric(horizontal: 28),
              icon: const Icon(Icons.person_add_alt_1_rounded, size: 28),
              label: const Text('Add learner', style: T.button),
            ),
      body: _students == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator(color: C.primary)
                  : EmptyState(icon: Icons.info_outline_rounded, text: _error!, action: ('Try again', _load)),
            )
          : LayoutBuilder(builder: (context, box) {
              final wide = box.maxWidth >= 1000;
              final selected = all.where((s) => s.user.id == _selected).firstOrNull;
              final list = RefreshIndicator(
                onRefresh: _load,
                color: C.primary,
                child: ListView(padding: const EdgeInsets.only(bottom: S.xxl), children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(S.lg, S.base, S.lg, 0),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Wrap(spacing: S.md, runSpacing: S.md, children: [
                        _Stat('${all.length - waiting}', 'Enrolled', C.ink),
                        _Stat('$waiting', 'Waiting', StatusChip.amber),
                        _Stat('$never', 'Never signed in', C.primary),
                      ]),
                      if (waiting > 0) ...[
                        const SizedBox(height: S.base),
                        FilledButton.icon(
                          onPressed: () => _enrolAll(waiting),
                          icon: const Icon(Icons.how_to_reg_rounded, size: 28),
                          label: Text('Enrol all $waiting waiting'),
                        ),
                      ],
                      const SizedBox(height: S.base),
                      TextField(
                        controller: _search,
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(fontSize: 18, color: C.ink),
                        decoration: const InputDecoration(
                          hintText: 'Search name, cell or username',
                          prefixIcon: Icon(Icons.search_rounded, size: 26),
                        ),
                      ),
                      const SizedBox(height: S.md),
                      Choices<_Filter>(
                        options: _Filter.values,
                        selected: _filter,
                        label: (f) => switch (f) {
                          _Filter.all => 'All ${all.length}',
                          _Filter.waiting => 'Not enrolled $waiting',
                          _Filter.never => 'Never signed in $never',
                          _Filter.active => 'Signed in $active',
                        },
                        onSelected: (f) => setState(() => _filter = f),
                      ),
                      const SizedBox(height: S.sm),
                    ]),
                  ),
                  if (all.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(S.xl),
                      child: Text(
                          'No learners here yet.\n\nTap "Add learner" to add your learners yourself. If your church has a '
                          'Monarch graduate, their church list also appears here once they open WDF Classes.',
                          style: T.body,
                          textAlign: TextAlign.center),
                    )
                  else if (shown.isEmpty)
                    const Padding(padding: EdgeInsets.all(S.xl), child: Text('No learners match.', style: T.body, textAlign: TextAlign.center)),
                  for (final s in shown) _StudentRow(s, selected: wide && s.user.id == _selected, onTap: () => _open(s, wide)),
                ]),
              );
              if (!wide) return list;
              return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 500, child: list),
                const VerticalDivider(width: 1),
                Expanded(
                  child: selected == null
                      ? const EmptyState(icon: Icons.touch_app_outlined, text: 'Choose a learner to enrol them or see their login.')
                      : SingleChildScrollView(
                          padding: const EdgeInsets.all(S.xl),
                          child: PageWidth(
                            max: 720,
                            child: _StudentPanel(selected, key: ValueKey(selected.user.id), subjects: _subjects, onChanged: _load),
                          ),
                        ),
                ),
              ]);
            }),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.value, this.label, this.color);
  final String value, label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: S.base, vertical: S.md),
        decoration: BoxDecoration(border: Border.all(color: C.hairline), borderRadius: BorderRadius.circular(R.md)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(value, style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, height: 1.1, color: color)),
          Text(label, style: T.label.copyWith(fontSize: 15)),
        ]),
      );
}

String _signedIn(Student s) => s.lastLoginAt == null ? 'Never signed in' : 'Signed in ${ago(s.lastLoginAt!).toLowerCase()}';

StatusChip _status(Student s) => !s.enrolled
    ? const StatusChip('Not enrolled', color: StatusChip.amber)
    : s.lastLoginAt == null
        ? const StatusChip('Never signed in', color: StatusChip.red)
        : const StatusChip('Active', color: StatusChip.green);

class _StudentRow extends StatelessWidget {
  const _StudentRow(this.s, {required this.onTap, this.selected = false});
  final Student s;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) => Material(
        color: selected ? C.primary.withValues(alpha: .08) : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.lg, vertical: S.md),
            child: Row(children: [
              Avatar(name: s.user.name, url: s.user.photoUrl, radius: 28),
              const SizedBox(width: S.base),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s.user.name, style: T.cardTitle.copyWith(fontSize: 19)),
                  Text(s.enrolled ? _signedIn(s) : s.skill ?? s.cell, style: T.meta.copyWith(fontSize: 15), maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
              const SizedBox(width: S.sm),
              _status(s),
            ]),
          ),
        ),
      );
}

class _StudentPanel extends StatefulWidget {
  const _StudentPanel(this.s, {super.key, required this.subjects, required this.onChanged});
  final Student s;
  final List<Subject> subjects;
  final VoidCallback onChanged;

  @override
  State<_StudentPanel> createState() => _StudentPanelState();
}

class _StudentPanelState extends State<_StudentPanel> {
  late Student s = widget.s;
  // Not enrolled yet → pre-ticked from what they chose on their bursary form.
  late final Set<String> _picked = {...(s.enrolled ? s.subjectIds : s.formSubjectIds)};
  bool _busy = false;

  Future<void> _enrol() async {
    if (_picked.isEmpty) return toast(context, 'Tick at least one subject.');
    setState(() => _busy = true);
    try {
      final wasEnrolled = s.enrolled;
      final updated = await auth.api.enrol(s.user.id, _picked.toList());
      if (!mounted) return;
      setState(() => s = updated);
      toast(context, wasEnrolled ? 'Subjects saved.' : '${s.user.name.split(' ').first} is enrolled. Share their login below.');
      widget.onChanged();
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _reset() async {
    try {
      final updated = await auth.api.resetPassword(s.user.id);
      if (!mounted) return;
      setState(() => s = updated);
      toast(context, 'New password: ${s.password}. The old one no longer works.');
      widget.onChanged();
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
  }

  String get _message => 'Hi ${s.user.name.split(' ').first}, you are enrolled in WDF Classes.\n'
      'Open $apiUrl (or the WDF Classes app) and sign in with:\n'
      'Username: ${s.username}\nPassword: ${s.password}';

  void _whatsApp() {
    final digits = s.cell.replaceAll(RegExp('[^0-9]'), '');
    final intl = digits.startsWith('0') ? '27${digits.substring(1)}' : digits;
    launchUrl(Uri.parse('https://wa.me/$intl?text=${Uri.encodeComponent(_message)}'),
        mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank');
  }

  @override
  Widget build(BuildContext context) {
    final formNames = [...s.modules, ?s.skill];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Avatar(name: s.user.name, url: s.user.photoUrl, radius: 44),
        const SizedBox(width: S.base),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.user.name, style: T.title),
            Text(s.cell, style: T.meta),
            const SizedBox(height: S.xs),
            _status(s),
          ]),
        ),
      ]),
      if (s.enrolled) ...[
        const SizedBox(height: S.lg),
        _LoginCard(s, onShare: _whatsApp, onReset: _reset),
        const SizedBox(height: S.sm),
        Text(_signedIn(s), style: T.meta),
      ],
      const SizedBox(height: S.xl),
      Text(s.enrolled ? 'Subjects' : 'Enrol in subjects', style: T.title),
      const SizedBox(height: S.xs),
      Text('Chose on their form: ${formNames.join(', ')}', style: T.meta),
      const SizedBox(height: S.md),
      Wrap(spacing: S.sm, runSpacing: S.sm, children: [
        for (final sub in widget.subjects)
          FilterChip(
            label: Text(sub.name),
            selected: _picked.contains(sub.id),
            onSelected: (on) => setState(() => on ? _picked.add(sub.id) : _picked.remove(sub.id)),
            labelStyle: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: _picked.contains(sub.id) ? Colors.white : C.ink),
            checkmarkColor: Colors.white,
            selectedColor: C.ink,
            backgroundColor: C.canvas,
            side: BorderSide(color: _picked.contains(sub.id) ? C.ink : C.hairline),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.full)),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          ),
      ]),
      const SizedBox(height: S.lg),
      FilledButton(
        onPressed: _busy ? null : _enrol,
        child: Text(_busy ? 'Saving…' : s.enrolled ? 'Save subjects' : 'Enrol ${s.user.name.split(' ').first}'),
      ),
    ]);
  }
}

/// Username + password, big and copyable, with WhatsApp share and reset.
class _LoginCard extends StatelessWidget {
  const _LoginCard(this.s, {required this.onShare, required this.onReset});
  final Student s;
  final VoidCallback onShare, onReset;

  Widget _field(BuildContext context, String label, String value) => Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: T.label.copyWith(fontSize: 14)),
            SelectableText(value, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: C.ink, letterSpacing: .5)),
          ]),
        ),
        IconButton(
          tooltip: 'Copy $label',
          iconSize: 28,
          onPressed: () {
            Clipboard.setData(ClipboardData(text: value));
            toast(context, '$label copied');
          },
          icon: const Icon(Icons.copy_rounded),
        ),
      ]);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(S.lg),
        decoration: BoxDecoration(color: C.surfaceSoft, borderRadius: BorderRadius.circular(R.md)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Class login', style: T.cardTitle),
          const SizedBox(height: S.md),
          _field(context, 'Username', s.username ?? '—'),
          const SizedBox(height: S.sm),
          _field(context, 'Password', s.password ?? '—'),
          const SizedBox(height: S.base),
          FilledButton.icon(
            onPressed: onShare,
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1FA855)),
            icon: const Icon(Icons.send_rounded, size: 26),
            label: const Text('Send on WhatsApp'),
          ),
          const SizedBox(height: S.sm),
          OutlinedButton.icon(onPressed: onReset, icon: const Icon(Icons.lock_reset_rounded, size: 26), label: const Text('Reset password')),
        ]),
      );
}

/// The 4 modules every bursary learner takes (same names as the WDF system).
const _compulsory = ['Job Readiness', 'Financial Literacy', 'Business Management', "Learners & Driver's Licence"];

/// Graduate adds a learner by hand: name, cell, the 4 compulsory modules (pre-ticked) and one skill.
class _AddLearner extends StatefulWidget {
  const _AddLearner({required this.subjects});
  final List<Subject> subjects;

  @override
  State<_AddLearner> createState() => _AddLearnerState();
}

class _AddLearnerState extends State<_AddLearner> {
  final _name = TextEditingController();
  final _cell = TextEditingController();
  final _modules = {..._compulsory};
  String? _skill, _error;
  bool _busy = false;

  List<String> get _skills => [for (final s in widget.subjects) if (!_compulsory.contains(s.name)) s.name];

  Future<void> _save() async {
    if (_skill == null) return setState(() => _error = 'Choose the skill they want to study.');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = await auth.api.addStudent(name: _name.text, cell: _cell.text, skill: _skill!, modules: _modules.toList());
      if (mounted) Navigator.pop(context, s);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(S.lg, 0, S.lg, S.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Add a learner', style: T.title),
            const SizedBox(height: S.xs),
            const Text('They are enrolled straight away and get a username and password.', style: T.meta),
            const SizedBox(height: S.lg),
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              style: const TextStyle(fontSize: 19, color: C.ink),
              decoration: const InputDecoration(labelText: 'Name and surname'),
            ),
            const SizedBox(height: S.base),
            TextField(
              controller: _cell,
              keyboardType: TextInputType.phone,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)],
              style: const TextStyle(fontSize: 19, color: C.ink),
              decoration: const InputDecoration(labelText: 'Cell number', hintText: '0821234567'),
            ),
            const SizedBox(height: S.lg),
            const Text('Compulsory modules', style: T.label),
            const SizedBox(height: S.sm),
            Wrap(spacing: S.sm, runSpacing: S.sm, children: [
              for (final m in _compulsory)
                FilterChip(
                  label: Text(m),
                  selected: _modules.contains(m),
                  onSelected: (on) => setState(() => on ? _modules.add(m) : _modules.remove(m)),
                  labelStyle: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: _modules.contains(m) ? Colors.white : C.ink),
                  checkmarkColor: Colors.white,
                  selectedColor: C.ink,
                  backgroundColor: C.canvas,
                  side: BorderSide(color: _modules.contains(m) ? C.ink : C.hairline),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.full)),
                ),
            ]),
            const SizedBox(height: S.lg),
            const Text('Skill (choose one)', style: T.label),
            const SizedBox(height: S.sm),
            Choices<String>(options: _skills, selected: _skill, label: (s) => s, onSelected: (s) => setState(() => _skill = s)),
            if (_error != null) ...[
              const SizedBox(height: S.md),
              Text(_error!, style: T.meta.copyWith(color: C.error)),
            ],
            const SizedBox(height: S.xl),
            FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Adding…' : 'Add and enrol')),
          ]),
        ),
      );
}
