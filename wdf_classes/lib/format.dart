const _days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

String dayLabel(DateTime d) {
  final today = DateTime.now();
  final a = DateTime(d.year, d.month, d.day), b = DateTime(today.year, today.month, today.day);
  final diff = a.difference(b).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  if (diff == -1) return 'Yesterday';
  return '${_days[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]}';
}

/// "Today 14:00", "Tue, 3 Oct 09:00"
String when(DateTime d) => '${dayLabel(d)} ${hm(d)}';

String duration(int minutes) =>
    minutes < 60 ? '$minutes min' : minutes % 60 == 0 ? '${minutes ~/ 60} h' : '${minutes ~/ 60} h ${minutes % 60} min';

String _span(Duration d) {
  if (d.inDays >= 1) return '${d.inDays} day${d.inDays == 1 ? '' : 's'}';
  if (d.inHours >= 1) return '${d.inHours} hour${d.inHours == 1 ? '' : 's'}';
  return '${d.inMinutes.clamp(1, 59)} min';
}

/// "Due in 3 days" / "Overdue by 2 hours"
String dueLabel(DateTime due) {
  final left = due.difference(DateTime.now());
  return left.isNegative ? 'Overdue by ${_span(-left)}' : 'Due in ${_span(left)}';
}

/// "5 min ago", "Yesterday 14:00"
String ago(DateTime d) {
  final diff = DateTime.now().difference(d);
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inHours < 1) return '${diff.inMinutes} min ago';
  if (diff.inHours < 12) return '${diff.inHours} h ago';
  return when(d);
}
