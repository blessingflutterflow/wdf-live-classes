import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api.dart';
import '../format.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets.dart';
import 'class_form.dart';

class TimetableScreen extends StatefulWidget {
  const TimetableScreen({super.key});

  @override
  State<TimetableScreen> createState() => _TimetableScreenState();
}

class _TimetableScreenState extends State<TimetableScreen> {
  List<ClassSession>? _sessions;
  String? _error;
  Timer? _tick;
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    // Keeps "Live now" / "Join" states current and picks up teacher changes.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => _load());
    _sub = live.changes.where((t) => t == 'sessions').listen((_) => _load());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await auth.api.sessions();
      if (mounted) {
        setState(() {
          _sessions = s;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _edit([ClassSession? s]) async {
    if (await showClassForm(context, s) == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final user = auth.user!;
    final sessions = _sessions?.where((s) => !s.isOver).toList();
    final liveNow = sessions?.where((s) => s.isLive).toList() ?? [];
    final byDay = <String, List<ClassSession>>{};
    for (final s in sessions ?? <ClassSession>[]) {
      if (!s.isLive) byDay.putIfAbsent(dayLabel(s.startsAt), () => []).add(s);
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: S.lg,
        title: const Text('WDF Classes'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: S.lg),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => context.go('/profile'),
              child: Avatar(name: user.name, url: user.photoUrl, color: user.isTeacher ? C.primary : C.ink),
            ),
          ),
        ],
        bottom: const PreferredSize(preferredSize: Size.fromHeight(1), child: Divider()),
      ),
      floatingActionButton: user.isTeacher
          ? FloatingActionButton.extended(
              onPressed: _edit,
              backgroundColor: C.primary,
              foregroundColor: Colors.white,
              extendedPadding: const EdgeInsets.symmetric(horizontal: 28),
              icon: const Icon(Icons.add_rounded, size: 30),
              label: const Text('New class', style: T.button),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _load,
        color: C.primary,
        child: CustomScrollView(slivers: [
          SliverToBoxAdapter(
            child: PageWidth(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(S.lg, S.xl, S.lg, S.sm),
                child: Text(user.isTeacher ? 'Your timetable' : 'Hi ${user.name.split(' ').first}, here are your classes',
                    style: T.display),
              ),
            ),
          ),
          if (_sessions == null && _error == null)
            const SliverFillRemaining(child: Center(child: CircularProgressIndicator(color: C.primary)))
          else if (_sessions == null)
            SliverFillRemaining(child: EmptyState(icon: Icons.wifi_off_rounded, text: _error!, action: ('Try again', _load)))
          else if (sessions!.isEmpty)
            SliverFillRemaining(
              child: EmptyState(
                icon: Icons.event_available_rounded,
                text: user.isTeacher ? 'No classes yet. Create your first one.' : 'No classes scheduled yet.',
                action: user.isTeacher ? ('New class', _edit) : null,
              ),
            )
          else ...[
            if (liveNow.isNotEmpty) ..._section('Live now', liveNow),
            for (final e in byDay.entries) ..._section(e.key, e.value),
            const SliverToBoxAdapter(child: SizedBox(height: 120)),
          ],
        ]),
      ),
    );
  }

  List<Widget> _section(String title, List<ClassSession> items) => [
        SliverToBoxAdapter(
          child: PageWidth(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(S.lg, S.xl, S.lg, S.base),
              child: Text(title, style: T.title),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: PageWidth(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: S.lg),
              child: LayoutBuilder(builder: (context, c) {
                final cols = c.maxWidth > 1100 ? 3 : c.maxWidth > 680 ? 2 : 1;
                final w = (c.maxWidth - S.lg * (cols - 1)) / cols;
                return Wrap(spacing: S.lg, runSpacing: S.lg, children: [
                  for (final s in items) SizedBox(width: w, child: _ClassCard(s, onTap: () => _open(s))),
                ]);
              }),
            ),
          ),
        ),
      ];

  void _open(ClassSession s) => showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true, // above the bottom tab bar
        isScrollControlled: true,
        constraints: const BoxConstraints(maxWidth: 640),
        builder: (_) => _ClassSheet(s, onEdit: () => _edit(s), onChanged: _load),
      );
}

/// Photo-style cover: a soft colour plate per class, big icon, status pill.
class _Cover extends StatelessWidget {
  const _Cover(this.s, {this.height});
  final ClassSession s;
  final double? height;

  static const _tints = [
    (Color(0xFFFFE4E9), Color(0xFFFF385C)),
    (Color(0xFFE6F0FF), Color(0xFF2F6FEB)),
    (Color(0xFFE7F6EC), Color(0xFF14A44D)),
    (Color(0xFFFFF1DC), Color(0xFFE08A00)),
    (Color(0xFFF0E8FF), Color(0xFF7A3FE0)),
    (Color(0xFFE3F6F7), Color(0xFF0F9BA6)),
  ];

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = _tints[s.title.codeUnits.fold(0, (a, b) => a + b) % _tints.length];
    return ClipRRect(
      borderRadius: BorderRadius.circular(R.md),
      child: Container(
        height: height,
        color: bg,
        child: AspectRatio(
          aspectRatio: height == null ? 16 / 10 : 100,
          child: Stack(children: [
            Positioned(right: -24, bottom: -28, child: Icon(Icons.auto_stories_rounded, size: 180, color: fg.withValues(alpha: .18))),
            Center(child: Text(s.title.characters.first.toUpperCase(), style: TextStyle(fontSize: 72, fontWeight: FontWeight.w700, color: fg))),
            Positioned(
              left: S.base,
              top: S.base,
              child: s.isLive
                  ? const Pill('LIVE NOW', color: C.primary, textColor: Colors.white, dot: Colors.white)
                  : s.canJoin
                      ? const Pill('STARTING SOON', dot: C.live)
                      : Pill(hm(s.startsAt)),
            ),
          ]),
        ),
      ),
    );
  }
}

class _ClassCard extends StatelessWidget {
  const _ClassCard(this.s, {required this.onTap});
  final ClassSession s;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(R.md),
        child: Padding(
          padding: const EdgeInsets.only(bottom: S.sm),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _Cover(s),
            const SizedBox(height: S.md),
            Text(s.title, style: T.cardTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: S.xs),
            Text('${hm(s.startsAt)} – ${hm(s.endsAt)} · ${s.subjectName}', style: T.meta, maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
      );
}

class _ClassSheet extends StatelessWidget {
  const _ClassSheet(this.s, {required this.onEdit, required this.onChanged});
  final ClassSession s;
  final VoidCallback onEdit, onChanged;

  bool get _mine => s.teacherId == auth.user!.id;

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete this class?', style: T.title),
        content: Text('"${s.title}" on ${dayLabel(s.startsAt)} will be removed for everyone.', style: T.body),
        actionsPadding: const EdgeInsets.all(S.lg),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await auth.api.deleteSession(s.id);
      if (context.mounted) Navigator.pop(context);
      onChanged();
    } catch (e) {
      if (context.mounted) toast(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(S.lg, 0, S.lg, S.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _Cover(s, height: 160),
            const SizedBox(height: S.lg),
            Text(s.title, style: T.title),
            const SizedBox(height: S.md),
            _Row(Icons.schedule_rounded, '${dayLabel(s.startsAt)} · ${hm(s.startsAt)} – ${hm(s.endsAt)} (${duration(s.minutes)})'),
            _Row(Icons.menu_book_rounded, s.subjectName),
            _Row(Icons.person_rounded, s.teacherName),
            if (s.description.isNotEmpty) ...[
              const SizedBox(height: S.sm),
              Text(s.description, style: T.body),
            ],
            const SizedBox(height: S.lg),
            FilledButton.icon(
              onPressed: s.canJoin || (auth.user!.isTeacher && !s.isOver)
                  ? () {
                      Navigator.pop(context);
                      context.push('/class/${s.id}');
                    }
                  : null,
              icon: const Icon(Icons.videocam_rounded, size: 28),
              label: Text(s.canJoin ? 'Join class' : 'Opens 15 min before start'),
            ),
            if (_mine) ...[
              const SizedBox(height: S.md),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      Navigator.pop(context);
                      onEdit();
                    },
                    child: const Text('Edit'),
                  ),
                ),
                const SizedBox(width: S.md),
                Expanded(child: OutlinedButton(onPressed: () => _delete(context), child: const Text('Delete'))),
              ]),
              const SizedBox(height: S.lg),
              _Attendance(s.id),
            ],
          ]),
        ),
      );
}

class _Attendance extends StatelessWidget {
  const _Attendance(this.id);
  final String id;

  @override
  Widget build(BuildContext context) => FutureBuilder(
        future: auth.api.attendance(id),
        builder: (_, snap) {
          final people = snap.data ?? const <User>[];
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Attendance (${people.length})', style: T.cardTitle),
            const SizedBox(height: S.sm),
            if (people.isEmpty)
              Text(snap.connectionState != ConnectionState.done ? 'Loading…' : 'Nobody has joined yet.', style: T.meta)
            else
              Wrap(spacing: S.md, runSpacing: S.md, children: [
                for (final u in people)
                  Column(mainAxisSize: MainAxisSize.min, children: [
                    Avatar(name: u.name, url: u.photoUrl, radius: 30),
                    const SizedBox(height: S.xs),
                    Text(u.name.split(' ').first, style: T.label.copyWith(fontSize: 14)),
                  ]),
              ]),
          ]);
        },
      );
}

class _Row extends StatelessWidget {
  const _Row(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: S.sm),
        child: Row(children: [
          Icon(icon, size: 26, color: C.ink),
          const SizedBox(width: S.md),
          Expanded(child: Text(text, style: T.body)),
        ]),
      );
}
