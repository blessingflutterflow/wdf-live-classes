import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets.dart';

/// Create (or edit) an assignment. Returns true when saved.
Future<bool?> showAssignmentForm(BuildContext context, [Assignment? existing]) => showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true, // above the bottom tab bar
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 680),
      builder: (_) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: _AssignmentForm(existing),
      ),
    );

class _AssignmentForm extends StatefulWidget {
  const _AssignmentForm(this.existing);
  final Assignment? existing;

  @override
  State<_AssignmentForm> createState() => _AssignmentFormState();
}

class _AssignmentFormState extends State<_AssignmentForm> {
  late final _title = TextEditingController(text: widget.existing?.title);
  late final _instructions = TextEditingController(text: widget.existing?.instructions);
  late DateTime _due = widget.existing?.dueAt ?? _defaultDue();
  List<Subject>? _subjects;
  String? _subjectId;
  (String, Uint8List)? _brief;
  bool _busy = false;
  String? _error;

  bool get _editing => widget.existing != null;

  static DateTime _defaultDue() {
    final d = DateTime.now().add(const Duration(days: 7));
    return DateTime(d.year, d.month, d.day, 17);
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

  Future<void> _pickBrief() async {
    final f = await pickDocument(context);
    if (f != null) setState(() => _brief = (f.$1, Uint8List.fromList(f.$2)));
  }

  Future<void> _save() async {
    if (!_editing && _subjectId == null) return setState(() => _error = 'Choose a subject.');
    if (_title.text.trim().isEmpty) return setState(() => _error = 'Give the assignment a title.');
    if (!_editing && _due.isBefore(DateTime.now())) return setState(() => _error = 'The deadline must be in the future.');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_editing) {
        await auth.api.updateAssignment(widget.existing!.id, title: _title.text.trim(), instructions: _instructions.text.trim(), brief: _brief);
      } else {
        await auth.api.createAssignment(
          subjectId: _subjectId!,
          title: _title.text.trim(),
          instructions: _instructions.text.trim(),
          dueAt: _due,
          brief: _brief,
        );
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
            Text(_editing ? 'Edit assignment' : 'New assignment', style: T.title),
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
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(fontSize: 19, color: C.ink),
              decoration: const InputDecoration(labelText: 'Title', hintText: 'e.g. Write your CV'),
            ),
            const SizedBox(height: S.base),
            TextField(
              controller: _instructions,
              minLines: 3,
              maxLines: 8,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(fontSize: 19, color: C.ink),
              decoration: const InputDecoration(labelText: 'Instructions', alignLabelWithHint: true),
            ),
            if (!_editing) ...[
              const SizedBox(height: S.lg),
              const Text('Deadline', style: T.label),
              const SizedBox(height: S.sm),
              DateTimeFields(value: _due, onChanged: (d) => setState(() => _due = d)),
            ],
            const SizedBox(height: S.lg),
            const Text('Brief or worksheet (optional)', style: T.label),
            const SizedBox(height: S.sm),
            if (_brief != null)
              Row(children: [
                Expanded(child: FileTile(name: _brief!.$1, url: null)),
                IconButton(onPressed: () => setState(() => _brief = null), icon: const Icon(Icons.close_rounded, size: 28)),
              ])
            else
              OutlinedButton.icon(
                onPressed: _pickBrief,
                icon: const Icon(Icons.attach_file_rounded, size: 26),
                label: Text(widget.existing?.briefName != null ? 'Replace ${widget.existing!.briefName}' : 'Attach PDF or Word file'),
              ),
            if (_error != null) ...[
              const SizedBox(height: S.md),
              Text(_error!, style: T.meta.copyWith(color: C.error)),
            ],
            const SizedBox(height: S.xl),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(_busy ? 'Saving…' : _editing ? 'Save changes' : 'Post assignment'),
            ),
          ]),
        ),
      );
}
