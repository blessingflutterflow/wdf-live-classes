import 'package:flutter/material.dart';

import '../api.dart';
import '../format.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets.dart';

/// Create or edit a class. Returns true when saved.
Future<bool?> showClassForm(BuildContext context, [ClassSession? existing]) => showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true, // above the bottom tab bar
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: _ClassForm(existing),
      ),
    );

class _ClassForm extends StatefulWidget {
  const _ClassForm(this.existing);
  final ClassSession? existing;

  @override
  State<_ClassForm> createState() => _ClassFormState();
}

class _ClassFormState extends State<_ClassForm> {
  late final _title = TextEditingController(text: widget.existing?.title);
  late final _description = TextEditingController(text: widget.existing?.description);
  late DateTime _start = widget.existing?.startsAt ?? _nextHour();
  late int _minutes = widget.existing?.minutes ?? 60;
  int _repeatWeeks = 0;
  List<Subject>? _subjects;
  String? _subjectId;
  bool _busy = false;
  String? _error;

  bool get _editing => widget.existing != null;

  static DateTime _nextHour() {
    final n = DateTime.now().add(const Duration(hours: 1));
    return DateTime(n.year, n.month, n.day, n.hour);
  }

  @override
  void initState() {
    super.initState();
    if (!_editing) {
      auth.api.subjects().then((s) => setState(() {
            _subjects = s;
            _subjectId = s.length == 1 ? s.first.id : null;
          }));
    }
  }

  Future<void> _save() async {
    if (!_editing && _subjectId == null) return setState(() => _error = 'Choose a subject.');
    if (_title.text.trim().isEmpty) return setState(() => _error = 'Give the class a title.');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = auth.api;
      if (_editing) {
        await api.updateSession(widget.existing!.id,
            title: _title.text.trim(), description: _description.text.trim(), startsAt: _start, minutes: _minutes);
      } else {
        await api.createSession(
            subjectId: _subjectId!,
            title: _title.text.trim(),
            description: _description.text.trim(),
            startsAt: _start,
            minutes: _minutes,
            repeatWeeks: _repeatWeeks);
      }
      if (mounted) Navigator.pop(context, true);
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
            Text(_editing ? 'Edit class' : 'New class', style: T.title),
            const SizedBox(height: S.lg),
            if (!_editing) ...[
              const Text('Subject', style: T.label),
              const SizedBox(height: S.sm),
              if (_subjects == null)
                const LinearProgressIndicator(color: C.primary)
              else
                Choices<String>(
                  options: [for (final s in _subjects!) s.id],
                  selected: _subjectId,
                  label: (id) => _subjects!.firstWhere((s) => s.id == id).name,
                  onSelected: (id) => setState(() => _subjectId = id),
                ),
              const SizedBox(height: S.lg),
            ],
            TextField(
              controller: _title,
              autofocus: false,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(fontSize: 19, color: C.ink),
              decoration: const InputDecoration(labelText: 'Title', hintText: 'e.g. Budgeting basics'),
            ),
            const SizedBox(height: S.base),
            TextField(
              controller: _description,
              minLines: 2,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(fontSize: 19, color: C.ink),
              decoration: const InputDecoration(labelText: 'What will you cover? (optional)'),
            ),
            const SizedBox(height: S.base),
            DateTimeFields(value: _start, onChanged: (d) => setState(() => _start = d), timeLabel: 'Start'),
            const SizedBox(height: S.lg),
            const Text('Length', style: T.label),
            const SizedBox(height: S.sm),
            Choices<int>(
              options: const [30, 45, 60, 90, 120],
              selected: _minutes,
              label: duration,
              onSelected: (v) => setState(() => _minutes = v),
            ),
            if (!_editing) ...[
              const SizedBox(height: S.lg),
              const Text('Repeat every week', style: T.label),
              const SizedBox(height: S.sm),
              Choices<int>(
                options: const [0, 4, 8, 12],
                selected: _repeatWeeks,
                label: (w) => w == 0 ? 'No' : 'For $w weeks',
                onSelected: (v) => setState(() => _repeatWeeks = v),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: S.md),
              Text(_error!, style: T.meta.copyWith(color: C.error)),
            ],
            const SizedBox(height: S.xl),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(_busy ? 'Saving…' : _editing ? 'Save changes' : 'Create class'),
            ),
          ]),
        ),
      );
}
