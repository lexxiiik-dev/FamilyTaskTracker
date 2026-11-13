// Модель данных клиента: задачи и списки с отметками времени по каждому полю.
import 'dart:convert';

const Map<String, dynamic> taskDefaults = {
  'title': '',
  'description': '',
  'checklist': <dynamic>[],
  'parent_id': '',
  'list_id': '',
  'assignee_id': '',
  'deadline': '',
  'reminder_at': 0,
  'status': 'open',
  'is_important': false,
  'in_today': false,
  'plans': <dynamic>[],
  'recurrence': null,
  'sort_order': 0,
  'deleted': false,
};
const Map<String, dynamic> listDefaults = {'name': '', 'assignee_id': '', 'sort_order': 0, 'deleted': false, 'delete_tasks': false, 'color': ''};

/// Пункт планирования задачи: день и, если задано, время с [from] до [to] (минуты от начала дня).
/// Пункт без времени показывается пунктиром в начале дня. [notify] — уведомление: у пункта со временем
/// за [before] минут до начала, у пункта без времени — в стандартное время уведомлений.
class PlanItem {
  final String id;
  final String date;
  final int from, to;
  final bool notify;
  final int before;
  const PlanItem(this.id, this.date, {this.from = -1, this.to = -1, this.notify = false, this.before = 60});

  bool get timed => from >= 0 && to > from;

  factory PlanItem.fromJson(Map m) {
    final f = (m['from'] as num?)?.toInt() ?? -1, t = (m['to'] as num?)?.toInt() ?? -1;
    final ok = f >= 0 && t > f && t <= 1440;
    return PlanItem((m['id'] ?? '').toString(), (m['date'] ?? '').toString(),
        from: ok ? f : -1, to: ok ? t : -1, notify: m['notify'] == true, before: (m['before'] as num?)?.toInt() ?? 60);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date,
        if (timed) 'from': from,
        if (timed) 'to': to,
        if (notify) 'notify': true,
        if (notify && timed) 'before': before,
      };

  PlanItem copyWith({String? id, String? date, int? from, int? to, bool? notify, int? before}) =>
      PlanItem(id ?? this.id, date ?? this.date, from: from ?? this.from, to: to ?? this.to, notify: notify ?? this.notify, before: before ?? this.before);

  /// Пункт без времени (время снято).
  PlanItem untimed() => PlanItem(id, date, notify: notify, before: before);

  /// Порядок: по дню, в дне сначала пункты без времени, затем по началу.
  static int compare(PlanItem a, PlanItem b) {
    final c = a.date.compareTo(b.date);
    if (c != 0) return c;
    if (a.from != b.from) return a.from.compareTo(b.from);
    return a.id.compareTo(b.id);
  }
}

String fmtMin(int m) => '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';

/// «за 1 ч», «за 30 мин», «в момент начала».
String beforeLabel(int m) {
  if (m <= 0) return 'в момент начала';
  if (m % 1440 == 0) return 'за ${m ~/ 1440} дн.';
  if (m % 60 == 0) return 'за ${m ~/ 60} ч';
  if (m > 60) return 'за ${m ~/ 60} ч ${m % 60} мин';
  return 'за $m мин';
}

const beforeOptions = [0, 5, 10, 15, 30, 60, 120, 180, 1440];

Map<String, dynamic> defaultsOf(String kind) => kind == 'list' ? listDefaults : taskDefaults;

/// Задача или список. [f] — значения полей, [t] — время последней правки каждого поля (мс),
/// [d] — поля, изменённые на этом устройстве и ещё не подтверждённые сервером.
class Ent {
  final String kind;
  final String id;
  String creatorId;
  bool isPrivate;
  int createdAt;
  final Map<String, dynamic> f;
  final Map<String, int> t;
  final Set<String> d;

  Ent(this.kind, this.id, {this.creatorId = '', this.isPrivate = false, this.createdAt = 0, Map<String, dynamic>? f, Map<String, int>? t, Set<String>? d})
    : f = {...defaultsOf(kind), ...?f},
      t = t ?? {},
      d = d ?? {};

  factory Ent.fromJson(String kind, Map<String, dynamic> j) {
    final f = <String, dynamic>{};
    final src = (j['f'] as Map?) ?? const {};
    for (final k in defaultsOf(kind).keys) {
      if (src.containsKey(k)) f[k] = src[k];
    }
    if (f['checklist'] == null && kind == 'task') f['checklist'] = <dynamic>[];
    if (f['plans'] == null && kind == 'task') f['plans'] = <dynamic>[];
    return Ent(
      kind,
      j['id'] as String,
      creatorId: (j['creator_id'] ?? '') as String,
      isPrivate: j['is_private'] == true,
      createdAt: (j['created_at'] as num?)?.toInt() ?? 0,
      f: f,
      t: ((j['t'] as Map?) ?? const {}).map((k, v) => MapEntry(k as String, (v as num).toInt())),
      d: ((j['d'] as List?) ?? const []).map((e) => e as String).toSet(),
    );
  }

  Map<String, dynamic> toJson() => {'id': id, 'creator_id': creatorId, 'is_private': isPrivate, 'created_at': createdAt, 'f': f, 't': t, 'd': d.toList()};

  Ent copy() => Ent.fromJson(kind, jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>);

  String s(String k) => (f[k] ?? '') as String;
  bool b(String k) => f[k] == true;
  int n(String k) => (f[k] as num?)?.toInt() ?? 0;

  // задача
  String get title => s('title');
  String get description => s('description');
  String get parentId => s('parent_id');
  String get listId => s('list_id');
  String get assigneeId => s('assignee_id');
  String get deadline => s('deadline');
  int get reminderAt => n('reminder_at');
  bool get done => s('status') == 'done';
  bool get important => b('is_important');
  bool get inToday => b('in_today');

  /// Пункты планирования по порядку.
  List<PlanItem> get plans {
    final out = ((f['plans'] as List?) ?? const []).whereType<Map>().map(PlanItem.fromJson).where((p) => p.date.length == 10).toList();
    out.sort(PlanItem.compare);
    return out;
  }

  bool get planned => plans.isNotEmpty;
  bool get deleted => b('deleted');
  Map<String, dynamic>? get recurrence => (f['recurrence'] as Map?)?.cast<String, dynamic>();
  List<Map<String, dynamic>> get checklist => ((f['checklist'] as List?) ?? const []).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  int get completedAt => done ? (t['status'] ?? 0) : 0;
  // список
  String get name => s('name');
  String get color => s('color');
}

class User {
  final String id, name;
  final bool isAdmin, hasPassword;
  final int avatarVer;
  const User(this.id, this.name, {this.isAdmin = false, this.hasPassword = false, this.avatarVer = 0});

  factory User.fromJson(Map<String, dynamic> j) => User(
    j['id'] as String,
    (j['name'] ?? '') as String,
    isAdmin: j['is_admin'] == true,
    hasPassword: j['has_password'] == true,
    avatarVer: (j['avatar_ver'] as num?)?.toInt() ?? 0,
  );
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'is_admin': isAdmin, 'has_password': hasPassword, 'avatar_ver': avatarVer};
}

// ---- даты (дедлайн — это день без времени, строка ГГГГ-ММ-ДД) ----

String fmtDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
DateTime parseDate(String s) {
  final p = s.split('-').map(int.parse).toList();
  return DateTime.utc(p[0], p[1], p[2]);
}

String addDays(String date, int days) => fmtDate(parseDate(date).add(Duration(days: days)));
int daysBetween(String a, String b) => parseDate(b).difference(parseDate(a)).inDays;

String _addMonths(String date, int months) {
  final d = parseDate(date);
  final total = d.year * 12 + (d.month - 1) + months;
  final y = total ~/ 12, m = total % 12 + 1;
  final last = DateTime.utc(y, m + 1, 0).day;
  return fmtDate(DateTime.utc(y, m, d.day > last ? last : d.day));
}

/// Правило повторения:
///   {type: daily} | {type: weekly, days: [1..7]} (1 — понедельник)
///   {type: interval, n: N, unit: day|week|month} | {type: yearly}
///   {type: monthdays, days: [1..31]} — по числам месяца (31 в коротком месяце — последний день)
/// Возвращает следующий дедлайн после [deadline]; если он уже в прошлом — ближайший не раньше [today].
String nextDeadline(String deadline, Map<String, dynamic> rule, String today) {
  String step(String d) {
    switch (rule['type']) {
      case 'weekly':
        final days = ((rule['days'] as List?) ?? const []).map((e) => (e as num).toInt()).toSet();
        if (days.isEmpty) return addDays(d, 7);
        var x = d;
        for (var i = 0; i < 7; i++) {
          x = addDays(x, 1);
          if (days.contains(parseDate(x).weekday)) return x;
        }
        return addDays(d, 7);
      case 'interval':
        final n = ((rule['n'] as num?)?.toInt() ?? 1).clamp(1, 1000);
        switch (rule['unit']) {
          case 'week':
            return addDays(d, 7 * n);
          case 'month':
            return _addMonths(d, n);
          default:
            return addDays(d, n);
        }
      case 'yearly':
        return _addMonths(d, 12);
      case 'monthdays':
        final days = ((rule['days'] as List?) ?? const []).map((e) => (e as num).toInt()).toSet();
        if (days.isEmpty) return _addMonths(d, 1);
        var x = d;
        for (var i = 0; i < 62; i++) {
          x = addDays(x, 1);
          final p = parseDate(x);
          final last = DateTime.utc(p.year, p.month + 1, 0).day;
          // число, которого в этом месяце нет (31 в ноябре), переносится на последний день месяца
          if (days.contains(p.day) || (p.day == last && days.any((n) => n > last))) return x;
        }
        return _addMonths(d, 1);
      default:
        return addDays(d, 1);
    }
  }

  var next = step(deadline);
  for (var guard = 0; guard < 5000 && next.compareTo(today) < 0; guard++) {
    next = step(next);
  }
  return next;
}

const weekdaysShort = ['пн', 'вт', 'ср', 'чт', 'пт', 'сб', 'вс'];
const monthsGen = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'];

String describeRecurrence(Map<String, dynamic>? r) {
  if (r == null) return 'Не повторять';
  switch (r['type']) {
    case 'daily':
      return 'Каждый день';
    case 'weekly':
      final days = ((r['days'] as List?) ?? const []).map((e) => (e as num).toInt()).toList()..sort();
      return 'По дням недели: ${days.map((d) => weekdaysShort[d - 1]).join(', ')}';
    case 'interval':
      final n = (r['n'] as num?)?.toInt() ?? 1;
      final unit = {'day': 'дн.', 'week': 'нед.', 'month': 'мес.'}[r['unit']] ?? 'дн.';
      return 'Каждые $n $unit';
    case 'yearly':
      return 'Ежегодно';
    case 'monthdays':
      final days = ((r['days'] as List?) ?? const []).map((e) => (e as num).toInt()).toList()..sort();
      return 'Каждый месяц: ${days.join(', ')} числа';
  }
  return 'Повторять';
}

String humanDate(String date, String today) {
  final diff = daysBetween(today, date);
  if (diff == 0) return 'Сегодня';
  if (diff == 1) return 'Завтра';
  if (diff == -1) return 'Вчера';
  final d = parseDate(date);
  final wd = weekdaysShort[d.weekday - 1];
  final year = d.year == parseDate(today).year ? '' : ' ${d.year}';
  return '$wd, ${d.day} ${monthsGen[d.month - 1]}$year';
}
