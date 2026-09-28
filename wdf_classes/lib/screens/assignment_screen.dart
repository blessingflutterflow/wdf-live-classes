import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../api.dart';
import '../format.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets.dart';
import 'assignment_form.dart';
import 'assignments_screen.dart';

class AssignmentScreen extends StatefulWidget {
  const AssignmentScreen({super.key, required this.id});
  final String id;

  @override
  State<AssignmentScreen> createState() => _AssignmentScreenState();
}

class _AssignmentScreenState extends State<AssignmentScreen> {
  Assignment? _a;
  String? _error;
  String? _selected; // teacher: learner being marked
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
      final a = await auth.api.assignment(widget.id);
      if (mounted) {
        setState(() {
          _a = a;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _delete() async {
    final ok = await confirm(context, 'Delete this assignment?', 'All submissions and marks for "${_a!.title}" will be removed.', 'Delete');
    if (!ok) return;
    try {
      await auth.api.deleteAssignment(_a!.id);
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
  }

  Future<void> _extendAll() async {
    final d = await pickDeadline(context, 'New deadline for everyone', _a!.dueAt.add(const Duration(days: 2)));
    if (d == null) return;
    try {
      await auth.api.extend(_a!.id, d);
      if (mounted) toast(context, 'Deadline moved to ${when(d)}. Learners have been notified.');
      _load();
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = _a;
    final teacher = auth.user!.isTeacher;
    return Scaffold(
      appBar: AppBar(
        title: Text(a?.subjectName ?? ''),
        actions: [
          if (teacher && a != null)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded, size: 28),
              onSelected: (v) async {
                if (v == 'edit' && await showAssignmentForm(context, a) == true) _load();
                if (v == 'extend') _extendAll();
                if (v == 'delete') _delete();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit', style: TextStyle(fontSize: 18))),
                PopupMenuItem(value: 'extend', child: Text('Extend deadline for everyone', style: TextStyle(fontSize: 18))),
                PopupMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(fontSize: 18))),
              ],
            ),
          const SizedBox(width: S.sm),
        ],
      ),
      body: a == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator(color: C.primary)
                  : EmptyState(icon: Icons.error_outline_rounded, text: _error!, action: ('Try again', _load)),
            )
          : teacher
              ? _teacherBody(a)
              : ListView(padding: const EdgeInsets.all(S.lg), children: [
                  PageWidth(
                    max: 760,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      _Header(a, due: a.myDue),
                      const SizedBox(height: S.xl),
                      _LearnerWork(a, onChanged: _load),
                    ]),
                  ),
                ]),
    );
  }

  Widget _teacherBody(Assignment a) => LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= 1000;
        final selected = a.submissions.where((s) => s.learner.id == _selected).firstOrNull;
        final list = _SubmissionList(
          a,
          selected: wide ? _selected : null,
          onTap: (s) {
            if (wide) {
              setState(() => _selected = s.learner.id);
            } else {
              showModalBottomSheet<void>(
                context: context,
                useRootNavigator: true, // above the bottom tab bar
                isScrollControlled: true,
                builder: (sheet) => Padding(
                  padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheet).bottom),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(S.lg, 0, S.lg, S.lg),
                    child: _MarkPanel(a, s, onDone: () {
                      Navigator.pop(sheet); // the sheet, not the page underneath
                      _load();
                    }),
                  ),
                ),
              );
            }
          },
        );
        final header = Padding(padding: const EdgeInsets.fromLTRB(S.lg, S.lg, S.lg, 0), child: _Header(a, due: a.dueAt));
        if (!wide) return ListView(children: [header, list, const SizedBox(height: S.xl)]);
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 480, child: ListView(children: [header, list, const SizedBox(height: S.xl)])),
          const VerticalDivider(width: 1),
          Expanded(
            child: selected == null
                ? const EmptyState(icon: Icons.rate_review_outlined, text: 'Choose a learner on the left to see their work and mark it.')
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(S.xl),
                    child: PageWidth(
                      max: 720,
                      child: _MarkPanel(a, selected, key: ValueKey(selected.learner.id), onDone: _load),
                    ),
                  ),
          ),
        ]);
      });
}

class _Header extends StatelessWidget {
  const _Header(this.a, {required this.due});
  final Assignment a;
  final DateTime due;

  @override
  Widget build(BuildContext context) {
    final overdue = DateTime.now().isAfter(due) && a.mine?.submitted != true;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(a.title, style: T.display),
      const SizedBox(height: S.md),
      Row(children: [
        Icon(Icons.schedule_rounded, size: 26, color: overdue ? C.primary : C.ink),
        const SizedBox(width: S.sm),
        Expanded(
          child: Text(
            'Deadline ${when(due)}${a.mine?.extended == true ? ' (extended for you)' : ''}',
            style: T.body.copyWith(fontWeight: FontWeight.w600, color: overdue ? C.primary : C.ink),
          ),
        ),
      ]),
      if (a.mine?.submitted != true) ...[
        const SizedBox(height: S.xs),
        Padding(padding: const EdgeInsets.only(left: 34), child: Text(dueLabel(due), style: T.meta.copyWith(color: overdue ? C.primary : C.muted))),
      ],
      if (a.instructions.isNotEmpty) ...[
        const SizedBox(height: S.lg),
        Text(a.instructions, style: T.body),
      ],
      if (a.briefName != null) ...[
        const SizedBox(height: S.lg),
        FileTile(name: a.briefName!, url: a.briefUrl),
      ],
    ]);
  }
}

// ---------------------------------------------------------------- learner

class _LearnerWork extends StatefulWidget {
  const _LearnerWork(this.a, {required this.onChanged});
  final Assignment a;
  final VoidCallback onChanged;

  @override
  State<_LearnerWork> createState() => _LearnerWorkState();
}

class _LearnerWorkState extends State<_LearnerWork> {
  bool _uploading = false;

  Future<void> _upload() async {
    final f = await pickDocument(context);
    if (f == null) return;
    setState(() => _uploading = true);
    try {
      await auth.api.submit(widget.a.id, f.$1, Uint8List.fromList(f.$2));
      if (mounted) toast(context, 'Submitted! Your teacher has been notified.');
      widget.onChanged();
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
    if (mounted) setState(() => _uploading = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.a.mine!;
    final pastDue = DateTime.now().isAfter(s.dueAt);
    return Container(
      padding: const EdgeInsets.all(S.lg),
      decoration: BoxDecoration(border: Border.all(color: C.hairline), borderRadius: BorderRadius.circular(R.md), boxShadow: kShadow, color: C.canvas),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Expanded(child: Text('Your work', style: T.title)),
          learnerStatus(s, s.dueAt),
        ]),
        if (s.marked) ...[
          const SizedBox(height: S.lg),
          Center(
            child: Text('${s.percent}%',
                style: TextStyle(fontSize: 72, fontWeight: FontWeight.w700, height: 1.1, letterSpacing: -1, color: _gradeColor(s.percent!))),
          ),
          if ((s.feedback ?? '').isNotEmpty) ...[
            const SizedBox(height: S.base),
            Container(
              padding: const EdgeInsets.all(S.base),
              decoration: BoxDecoration(color: C.surfaceSoft, borderRadius: BorderRadius.circular(R.sm)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Teacher\'s feedback', style: T.label),
                const SizedBox(height: S.xs),
                Text(s.feedback!, style: T.body),
              ]),
            ),
          ],
        ],
        if (s.submitted) ...[
          const SizedBox(height: S.lg),
          FileTile(name: s.fileName ?? 'Your file', url: s.fileUrl),
          const SizedBox(height: S.sm),
          Text('Submitted ${when(s.submittedAt!)}${s.late ? ' · LATE' : ''}', style: T.meta.copyWith(color: s.late ? StatusChip.amber : C.muted)),
        ],
        if (!s.marked) ...[
          const SizedBox(height: S.lg),
          if (pastDue && !s.submitted)
            Padding(
              padding: const EdgeInsets.only(bottom: S.md),
              child: Text('Your deadline has passed. You can still submit, but it will be marked late.',
                  style: T.body.copyWith(color: C.primary, fontWeight: FontWeight.w600)),
            ),
          FilledButton.icon(
            onPressed: _uploading ? null : _upload,
            icon: _uploading
                ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white))
                : const Icon(Icons.upload_file_rounded, size: 28),
            label: Text(_uploading ? 'Uploading…' : s.submitted ? 'Replace file' : 'Upload PDF or Word'),
          ),
          if (!s.submitted) ...[
            const SizedBox(height: S.sm),
            Text('PDF, DOC or DOCX, up to 20 MB', style: T.label.copyWith(fontSize: 15), textAlign: TextAlign.center),
          ],
        ],
      ]),
    );
  }
}

Color _gradeColor(int p) => p >= 70 ? StatusChip.green : p >= 50 ? StatusChip.amber : StatusChip.red;

// ---------------------------------------------------------------- teacher

StatusChip _teacherStatus(Submission s) {
  if (s.marked) return StatusChip('${s.percent}%', color: _gradeColor(s.percent!));
  if (s.submitted) return StatusChip(s.late ? 'Late' : 'Submitted', color: s.late ? StatusChip.amber : StatusChip.blue);
  if (s.overdue) return const StatusChip('Missing', color: StatusChip.red);
  if (s.extended) return StatusChip('Ext. ${dayLabel(s.dueAt)}', color: StatusChip.amber);
  return const StatusChip('Not yet', color: StatusChip.grey);
}

class _SubmissionList extends StatelessWidget {
  const _SubmissionList(this.a, {required this.onTap, this.selected});
  final Assignment a;
  final ValueChanged<Submission> onTap;
  final String? selected;

  @override
  Widget build(BuildContext context) {
    final subs = [...a.submissions]..sort((x, y) {
        int rank(Submission s) => s.submitted && !s.marked ? 0 : s.submitted ? 2 : 1;
        return rank(x).compareTo(rank(y));
      });
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(S.lg, S.xl, S.lg, S.sm),
        child: Text('Learners (${a.submissions.where((s) => s.submitted).length}/${a.submissions.length} submitted)', style: T.title),
      ),
      for (final s in subs)
        Material(
          color: s.learner.id == selected ? C.primary.withValues(alpha: .08) : Colors.transparent,
          child: InkWell(
            onTap: () => onTap(s),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: S.lg, vertical: S.md),
              child: Row(children: [
                Avatar(name: s.learner.name, url: s.learner.photoUrl, radius: 28),
                const SizedBox(width: S.base),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.learner.name, style: T.cardTitle.copyWith(fontSize: 19)),
                    Text(
                      s.submitted ? 'Submitted ${when(s.submittedAt!)}' : 'Due ${when(s.dueAt)}',
                      style: T.meta.copyWith(fontSize: 15),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ]),
                ),
                const SizedBox(width: S.sm),
                _teacherStatus(s),
              ]),
            ),
          ),
        ),
    ]);
  }
}

class _MarkPanel extends StatefulWidget {
  const _MarkPanel(this.a, this.s, {super.key, required this.onDone});
  final Assignment a;
  final Submission s;
  final VoidCallback onDone;

  @override
  State<_MarkPanel> createState() => _MarkPanelState();
}

class _MarkPanelState extends State<_MarkPanel> {
  late final _percent = TextEditingController(text: widget.s.percent?.toString());
  late final _feedback = TextEditingController(text: widget.s.feedback);
  bool _busy = false;

  Future<void> _mark() async {
    final p = int.tryParse(_percent.text.trim());
    if (p == null || p < 0 || p > 100) return toast(context, 'Enter a mark from 0 to 100%.');
    setState(() => _busy = true);
    try {
      await auth.api.mark(widget.a.id, learnerId: widget.s.learner.id, percent: p, feedback: _feedback.text.trim());
      if (mounted) toast(context, '${widget.s.learner.name.split(' ').first} got $p%. They\'ve been notified.');
      widget.onDone();
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _extend() async {
    final d = await pickDeadline(context, 'New deadline for ${widget.s.learner.name.split(' ').first}',
        (widget.s.dueAt.isAfter(DateTime.now()) ? widget.s.dueAt : DateTime.now()).add(const Duration(days: 2)));
    if (d == null) return;
    try {
      await auth.api.extend(widget.a.id, d, learnerId: widget.s.learner.id);
      if (mounted) toast(context, 'Extended to ${when(d)}. ${widget.s.learner.name.split(' ').first} has been notified.');
      widget.onDone();
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Avatar(name: s.learner.name, url: s.learner.photoUrl, radius: 44),
        const SizedBox(width: S.base),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.learner.name, style: T.title),
            const SizedBox(height: S.xs),
            _teacherStatus(s),
          ]),
        ),
      ]),
      const SizedBox(height: S.lg),
      Text('Deadline for this learner: ${when(s.dueAt)}${s.extended ? ' (extended)' : ''}', style: T.body),
      if (!s.marked) ...[
        const SizedBox(height: S.sm),
        OutlinedButton.icon(onPressed: _extend, icon: const Icon(Icons.more_time_rounded, size: 26), label: const Text('Give an extension')),
      ],
      const SizedBox(height: S.lg),
      if (!s.submitted)
        Container(
          padding: const EdgeInsets.all(S.lg),
          decoration: BoxDecoration(color: C.surfaceSoft, borderRadius: BorderRadius.circular(R.sm)),
          child: Text(s.overdue ? 'Nothing submitted and the deadline has passed.' : 'Nothing submitted yet.', style: T.body),
        )
      else ...[
        FileTile(name: s.fileName ?? 'Submission', url: s.fileUrl),
        const SizedBox(height: S.sm),
        Text('Submitted ${when(s.submittedAt!)}${s.late ? ' · LATE' : ''}', style: T.meta.copyWith(color: s.late ? StatusChip.amber : C.muted)),
        const SizedBox(height: S.xl),
        const Text('Mark', style: T.title),
        const SizedBox(height: S.md),
        SizedBox(
          width: 200,
          child: TextField(
            controller: _percent,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
            style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w700, color: C.ink),
            decoration: const InputDecoration(labelText: 'Mark', suffixText: '%', suffixStyle: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: C.ink)),
          ),
        ),
        const SizedBox(height: S.base),
        TextField(
          controller: _feedback,
          minLines: 3,
          maxLines: 8,
          textCapitalization: TextCapitalization.sentences,
          style: const TextStyle(fontSize: 18, color: C.ink),
          decoration: const InputDecoration(labelText: 'Feedback for the learner', alignLabelWithHint: true),
        ),
        const SizedBox(height: S.lg),
        FilledButton(onPressed: _busy ? null : _mark, child: Text(_busy ? 'Saving…' : s.marked ? 'Update mark' : 'Return to learner')),
      ],
    ]);
  }
}

// ---------------------------------------------------------------- dialogs

Future<bool> confirm(BuildContext context, String title, String body, String action) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title, style: T.title),
        content: Text(body, style: T.body),
        actionsPadding: const EdgeInsets.all(S.lg),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(action)),
        ],
      ),
    ) ==
    true;

Future<DateTime?> pickDeadline(BuildContext context, String title, DateTime initial) => showDialog<DateTime>(
      context: context,
      builder: (c) {
        var value = initial;
        return StatefulBuilder(
          builder: (c, set) => AlertDialog(
            title: Text(title, style: T.title),
            content: SizedBox(width: 460, child: DateTimeFields(value: value, onChanged: (d) => set(() => value = d))),
            actionsPadding: const EdgeInsets.all(S.lg),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(c, value), child: const Text('Extend')),
            ],
          ),
        );
      },
    );
