import 'package:intl/intl.dart';

/// `14:05` today, `Mon 14:05` this week, `3 Oct 14:05` otherwise.
String formatMessageTime(int ts, {DateTime? now}) {
  final t = DateTime.fromMillisecondsSinceEpoch(ts);
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(t.year, t.month, t.day);
  final time = DateFormat.Hm().format(t);
  if (day == today) return time;
  if (today.difference(day).inDays < 7) return '${DateFormat.E().format(t)} $time';
  return '${DateFormat.MMMd().format(t)} $time';
}

/// Short form for the contact list: time today, otherwise the date.
String formatListTime(int ts, {DateTime? now}) {
  final t = DateTime.fromMillisecondsSinceEpoch(ts);
  final n = now ?? DateTime.now();
  if (t.year == n.year && t.month == n.month && t.day == n.day) {
    return DateFormat.Hm().format(t);
  }
  return DateFormat.MMMd().format(t);
}
