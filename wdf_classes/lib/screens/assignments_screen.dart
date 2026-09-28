import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api.dart';
import '../format.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets.dart';
import 'assignment_form.dart';

/// Learner's status on an assignment, as a coloured chip.
StatusChip learnerStatus(Submission? s, DateTime due) {
  if (s?.marked == true) return StatusChip('Marked ${s!.percent}%', color: StatusChip.green);
  if (s?.submitted == true) return StatusChip(s!.late ? 'Submitted late' : 'Submitted', color: s.late ? StatusChip.amber : StatusChip.blue);
  if (DateTime.now().isAfter(due)) return const StatusChip('Overdue', color: StatusChip.red);
  if (s?.extended == true) return const StatusChip('Extended', color: StatusChip.amber);
  return const StatusChip('To do', color: StatusChip.grey);
}

class AssignmentsScreen extends StatefulWidget {
  const AssignmentsScreen({super.key});

  @override
  State<AssignmentsScreen> createState() => _AssignmentsScreenState();
}

class _AssignmentsScreenState extends State<AssignmentsScreen> {
  List<Assignment>? _items;
  String? _error;
  late final StreamSubscription<String> _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = live.changes.where((t) => t == 'assignments').listen((_) => _load());
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final items = await auth.api.assignments();
      items.sort((a, b) => a.myDue.compareTo(b.myDue));
      if (mounted) {
        setState(() {
          _items = items;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final teacher = auth.user!.isTeacher;
    final items = _items ?? [];
    final groups = <(String, List<Assignment>)>[];
    if (teacher) {
      groups
        ..add(('Open', items.where((a) => a.dueAt.isAfter(DateTime.now())).toList()))
        ..add(('Past deadline', items.where((a) => !a.dueAt.isAfter(DateTime.now())).toList().reversed.toList()));
    } else {
      final todo = items.where((a) => !(a.mine?.submitted ?? false)).toList();
      groups
        ..add(('To do', todo.where((a) => a.myDue.isAfter(DateTime.now())).toList()))
        ..add(('Overdue', todo.where((a) => !a.myDue.isAfter(DateTime.now())).toList()))
        ..add(('Waiting for marks', items.where((a) => a.mine?.submitted == true && a.mine?.marked != true).toList()))
        ..add(('Marked', items.where((a) => a.mine?.marked == true).toList()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Assignments'), titleSpacing: S.lg),
      floatingActionButton: teacher
          ? FloatingActionButton.extended(
              onPressed: () async {
                if (await showAssignmentForm(context) == true) _load();
              },
              backgroundColor: C.primary,
              foregroundColor: Colors.white,
              extendedPadding: const EdgeInsets.symmetric(horizontal: 28),
              icon: const Icon(Icons.add_rounded, size: 30),
              label: const Text('New assignment', style: T.button),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _load,
        color: C.primary,
        child: _items == null
            ? (_error == null
                ? const Center(child: CircularProgressIndicator(color: C.primary))
                : ListView(children: [const SizedBox(height: 120), EmptyState(icon: Icons.wifi_off_rounded, text: _error!, action: ('Try again', _load))]))
            : items.isEmpty
                ? ListView(children: [
                    const SizedBox(height: 120),
                    EmptyState(
                      icon: Icons.assignment_outlined,
                      text: teacher ? 'No assignments yet. Create the first one.' : 'No assignments yet. They\'ll appear here when your teacher posts them.',
                    ),
                  ])
                : ListView(padding: const EdgeInsets.fromLTRB(S.lg, 0, S.lg, 120), children: [
                    for (final (title, list) in groups)
                      if (list.isNotEmpty)
                        PageWidth(
                          max: 1100,
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            SectionTitle(title, count: list.length),
                            LayoutBuilder(builder: (context, c) {
                              final cols = c.maxWidth > 760 ? 2 : 1;
                              final w = (c.maxWidth - S.base * (cols - 1)) / cols;
                              return Wrap(spacing: S.base, runSpacing: S.base, children: [
                                for (final a in list) SizedBox(width: w, child: _AssignmentCard(a, teacher: teacher, onBack: _load)),
                              ]);
                            }),
                          ]),
                        ),
                  ]),
      ),
    );
  }
}

class _AssignmentCard extends StatelessWidget {
  const _AssignmentCard(this.a, {required this.teacher, required this.onBack});
  final Assignment a;
  final bool teacher;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final due = a.myDue;
    final soon = !teacher && a.mine?.submitted != true && due.difference(DateTime.now()) < const Duration(hours: 48);
    return Material(
      color: C.canvas,
      borderRadius: BorderRadius.circular(R.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(R.md),
        onTap: () async {
          await context.push('/assignments/${a.id}');
          onBack();
        },
        child: Container(
          padding: const EdgeInsets.all(S.lg),
          decoration: BoxDecoration(border: Border.all(color: C.hairline), borderRadius: BorderRadius.circular(R.md)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(a.subjectName.toUpperCase(), style: T.badge.copyWith(color: C.primary))),
              if (!teacher) learnerStatus(a.mine, due),
            ]),
            const SizedBox(height: S.sm),
            Text(a.title, style: T.cardTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: S.sm),
            Row(children: [
              Icon(Icons.schedule_rounded, size: 22, color: soon ? C.primary : C.muted),
              const SizedBox(width: S.sm),
              Expanded(
                child: Text(
                  a.mine?.submitted == true ? 'Deadline ${when(due)}' : '${dueLabel(due)} · ${when(due)}',
                  style: T.meta.copyWith(color: soon ? C.primary : C.muted, fontWeight: soon ? FontWeight.w600 : FontWeight.w400),
                ),
              ),
            ]),
            if (teacher) ...[
              const SizedBox(height: S.md),
              ClipRRect(
                borderRadius: BorderRadius.circular(R.full),
                child: LinearProgressIndicator(
                  value: a.learnerCount == 0 ? 0 : a.submittedCount / a.learnerCount,
                  minHeight: 10,
                  backgroundColor: C.surfaceStrong,
                  color: C.primary,
                ),
              ),
              const SizedBox(height: S.sm),
              Text('${a.submittedCount} of ${a.learnerCount} submitted · ${a.markedCount} marked', style: T.meta),
            ],
          ]),
        ),
      ),
    );
  }
}
