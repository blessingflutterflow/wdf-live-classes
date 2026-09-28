import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'format.dart';
import 'theme.dart';

/// Profile photo, falling back to the first letter of the name.
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, this.url, this.radius = 24, this.color = const Color(0xFF444444)});
  final String name;
  final String? url;
  final double radius;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final letter = Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: TextStyle(fontSize: radius * .8, fontWeight: FontWeight.w700, color: Colors.white));
    return CircleAvatar(
      radius: radius,
      backgroundColor: color,
      foregroundImage: url == null ? null : NetworkImage(url!),
      onForegroundImageError: url == null ? null : (_, _) {},
      child: letter,
    );
  }
}

/// Big tappable field showing a value, e.g. a date or a time.
class PickerField extends StatelessWidget {
  const PickerField({super.key, required this.label, required this.value, required this.icon, required this.onTap});
  final String label, value;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(R.sm),
        child: Container(
          height: kFieldHeight + 8,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(border: Border.all(color: C.hairline), borderRadius: BorderRadius.circular(R.sm)),
          child: Row(children: [
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: T.label.copyWith(fontSize: 14)),
                Text(value, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: C.ink), overflow: TextOverflow.ellipsis),
              ]),
            ),
            Icon(icon, size: 24, color: C.ink),
          ]),
        ),
      );
}

/// Date + time fields side by side.
class DateTimeFields extends StatelessWidget {
  const DateTimeFields({super.key, required this.value, required this.onChanged, this.dateLabel = 'Date', this.timeLabel = 'Time'});
  final DateTime value;
  final ValueChanged<DateTime> onChanged;
  final String dateLabel, timeLabel;

  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(
          child: PickerField(
            label: dateLabel,
            value: dayLabel(value),
            icon: Icons.calendar_today_rounded,
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: value,
                firstDate: DateTime.now().subtract(const Duration(days: 1)),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (d != null) onChanged(DateTime(d.year, d.month, d.day, value.hour, value.minute));
            },
          ),
        ),
        const SizedBox(width: S.md),
        Expanded(
          child: PickerField(
            label: timeLabel,
            value: hm(value),
            icon: Icons.schedule_rounded,
            onTap: () async {
              final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(value));
              if (t != null) onChanged(DateTime(value.year, value.month, value.day, t.hour, t.minute));
            },
          ),
        ),
      ]);
}

/// Row of big pill choices.
class Choices<V> extends StatelessWidget {
  const Choices({super.key, required this.options, required this.selected, required this.label, required this.onSelected});
  final List<V> options;
  final V? selected;
  final String Function(V) label;
  final ValueChanged<V> onSelected;

  @override
  Widget build(BuildContext context) => Wrap(spacing: S.sm, runSpacing: S.sm, children: [
        for (final o in options)
          ChoiceChip(
            label: Text(label(o)),
            selected: o == selected,
            onSelected: (_) => onSelected(o),
            showCheckmark: false,
            labelStyle: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: o == selected ? Colors.white : C.ink),
            labelPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            selectedColor: C.ink,
            backgroundColor: C.canvas,
            side: BorderSide(color: o == selected ? C.ink : C.hairline),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.full)),
          ),
      ]);
}

/// Coloured status label: Submitted / Late / Marked 85% …
class StatusChip extends StatelessWidget {
  const StatusChip(this.text, {super.key, required this.color});
  final String text;
  final Color color;

  static const green = Color(0xFF14A44D), amber = Color(0xFFE08A00), red = C.primary, grey = C.muted, blue = Color(0xFF2F6FEB);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(R.full)),
        child: Text(text, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: color)),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(S.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 72, color: C.muted),
            const SizedBox(height: S.base),
            Text(text, style: T.body, textAlign: TextAlign.center),
            if (action != null) ...[
              const SizedBox(height: S.lg),
              FilledButton(onPressed: action!.$2, child: Text(action!.$1)),
            ],
          ]),
        ),
      );
}

/// A file row: icon + name, opens in a new tab / the phone's viewer.
class FileTile extends StatelessWidget {
  const FileTile({super.key, required this.name, required this.url});
  final String name;
  final String? url;

  @override
  Widget build(BuildContext context) {
    final pdf = name.toLowerCase().endsWith('.pdf');
    return Material(
      color: C.surfaceSoft,
      borderRadius: BorderRadius.circular(R.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(R.sm),
        onTap: url == null ? null : () => launchUrl(Uri.parse(url!), mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank'),
        child: Padding(
          padding: const EdgeInsets.all(S.base),
          child: Row(children: [
            Icon(pdf ? Icons.picture_as_pdf_rounded : Icons.description_rounded, size: 34, color: pdf ? C.primary : StatusChip.blue),
            const SizedBox(width: S.md),
            Expanded(child: Text(name, style: T.cardTitle.copyWith(fontSize: 18), maxLines: 2, overflow: TextOverflow.ellipsis)),
            if (url != null) const Icon(Icons.open_in_new_rounded, size: 24, color: C.ink),
          ]),
        ),
      ),
    );
  }
}

/// Pick a PDF or Word file. Returns (name, bytes) or null.
Future<(String, List<int>)?> pickDocument(BuildContext context) async {
  final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['pdf', 'doc', 'docx']);
  if (f == null) return null;
  if ((await f.length() ?? 0) > 20 * 1024 * 1024) {
    if (context.mounted) toast(context, 'That file is bigger than 20 MB. Try a smaller one.');
    return null;
  }
  return (f.name, await f.readAsBytes());
}

/// Section heading used on list screens.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.count});
  final String text;
  final int? count;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(0, S.xl, 0, S.base),
        child: Row(children: [
          Text(text, style: T.title),
          if (count != null) ...[
            const SizedBox(width: S.sm),
            StatusChip('$count', color: C.ink),
          ],
        ]),
      );
}
