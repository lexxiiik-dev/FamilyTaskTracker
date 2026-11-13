// Напоминания: расчёт того, что показать сейчас, что запланировать и что отменить.
// Чистая логика без плагинов — её проверяют тесты.
import 'dart:convert';

import 'model.dart';
import 'repo.dart';

class Reminder {
  final String key; // стабильный ключ: меняется вместе с временем напоминания
  final String taskId;
  final String title;
  final String body;
  final int at;
  final bool isDeadline;
  final String date; // для напоминаний по дедлайну — день дедлайна
  /// Общее утреннее уведомление о задачах дня: [group] — его отметка «показано»,
  /// [covers] — ключи напоминаний отдельных задач, которые оно заменяет.
  final String group;
  final List<String> covers;
  const Reminder(this.key, this.taskId, this.title, this.body, this.at, {this.isDeadline = false, this.date = '', this.group = '', this.covers = const []});

  /// Числовой идентификатор для системного уведомления.
  int get nid {
    var h = 0x811c9dc5;
    for (final c in utf8.encode(key)) {
      h = ((h ^ c) * 0x01000193) & 0x7fffffff;
    }
    return h;
  }
}

/// Все напоминания текущего пользователя: уведомления приходят только исполнителю.
List<Reminder> collectReminders(Repo r) {
  final out = <Reminder>[];
  final byDay = <String, List<Ent>>{};
  for (final t in r.tasks.values) {
    if (t.deleted || t.done || t.assigneeId != r.me) continue;
    for (final p in t.plans) {
      if (!p.notify) continue;
      if (p.timed) {
        // пункт со временем: уведомление за заданное время до начала
        final start = r.momentOf(p.date, fmtMin(p.from));
        final at = start - p.before * 60000;
        final body = p.before <= 0 ? 'Начало в ${fmtMin(p.from)}' : 'В ${fmtMin(p.from)} (${beforeLabel(p.before).replaceFirst('за ', 'через ')})';
        out.add(Reminder('p:${t.id}:${p.id}:$at', t.id, t.title, body, at));
        continue;
      }
      // пункт без времени: в стандартное время уведомлений, общим уведомлением за день
      final at = r.momentOf(p.date, r.deadlineTime);
      // свою задачу, созданную уже после времени уведомлений, не объявляем тут же
      if (t.creatorId == r.me && t.createdAt > at) continue;
      final day = byDay[p.date] ??= [];
      if (!day.contains(t)) day.add(t);
    }
  }
  // Задачи без времени на один день объявляются одним общим уведомлением в назначенное время.
  // Задача, пришедшая уже после него (поручили позже), объявляется отдельно.
  final fired = decodeMap(r.kv['fired']);
  for (final e in byDay.entries) {
    final date = e.key, at = r.momentOf(date, r.deadlineTime);
    final all = e.value..sort((a, b) => a.createdAt != b.createdAt ? a.createdAt.compareTo(b.createdAt) : a.id.compareTo(b.id));
    String one(Ent t) => 'd:${t.id}:$date:${r.deadlineTime}';
    final group = 'day:$date:${r.deadlineTime}';
    if (fired.containsKey(group)) {
      for (final t in all) {
        out.add(Reminder(one(t), t.id, t.title, 'Задача на сегодня', at, isDeadline: true, date: date));
      }
      continue;
    }
    // уже объявленные по отдельности (до появления общего уведомления) повторно не объявляются
    final list = [
      for (final t in all)
        if (!fired.containsKey(one(t))) t
    ];
    if (list.isEmpty) continue;
    // состав задач входит в ключ: изменился список — запланированное уведомление пересоздаётся
    final ids = [for (final t in list) t.id]..sort();
    final key = '$group#${Reminder(ids.join(','), '', '', '', 0).nid.toRadixString(16)}';
    final covers = [for (final t in list) one(t)];
    if (list.length == 1) {
      out.add(Reminder(key, list.first.id, list.first.title, 'Задача на сегодня', at, isDeadline: true, date: date, group: group, covers: covers));
    } else {
      final lines = [for (final t in list.take(12)) '• ${t.title.isEmpty ? 'Без названия' : t.title}', if (list.length > 12) '… и ещё ${list.length - 12}'];
      out.add(Reminder(key, '', 'Задачи на сегодня: ${list.length}', lines.join('\n'), at, isDeadline: true, date: date, group: group, covers: covers));
    }
  }
  return out;
}

class ReminderPlan {
  final List<Reminder> showNow = [];
  final List<Reminder> schedule = [];
  final List<int> cancel = [];
  Map<String, int> fired = {};
  Map<String, int> scheduled = {};
}

const _lateWindow = 48 * 3600 * 1000;

/// [fired] — уже показанные (ключ -> время), [scheduled] — переданные системе на будущее (Android).
/// [baseline] — момент входа на устройстве: более старые напоминания не показываются.
/// [canSchedule] — система умеет показывать уведомление сама в назначенное время.
ReminderPlan planReminders({
  required List<Reminder> reminders,
  required Map<String, int> fired,
  required Map<String, int> scheduled,
  required int now,
  required int baseline,
  required String today,
  required bool canSchedule,
}) {
  final p = ReminderPlan();
  p.fired = {...fired}..removeWhere((_, at) => now - at > 40 * 86400000);
  final keys = {for (final r in reminders) r.key};
  // задачу изменили, закрыли или удалили — запланированное системой уведомление отменяется
  for (final e in scheduled.entries) {
    if (!keys.contains(e.key) && e.value > now) p.cancel.add(_nid(e.key));
  }
  for (final r in reminders) {
    if (p.fired.containsKey(r.key) || (r.group.isNotEmpty && p.fired.containsKey(r.group))) continue;
    if (r.at > now) {
      if (canSchedule) {
        p.scheduled[r.key] = r.at;
        if (scheduled[r.key] != r.at) p.schedule.add(r);
      }
      continue;
    }
    // время уже наступило
    p.fired[r.key] = r.at;
    if (r.group.isNotEmpty) p.fired[r.group] = r.at;
    for (final k in r.covers) {
      p.fired[k] = r.at;
    }
    if (scheduled[r.key] == r.at) continue; // это уведомление показала сама система
    if (r.at < baseline) continue;
    // задача пришла с опозданием: напоминание срабатывает сразу
    final fresh = r.isDeadline ? r.date == today : now - r.at <= _lateWindow;
    if (fresh) p.showNow.add(r);
  }
  return p;
}

int _nid(String key) => Reminder(key, '', '', '', 0).nid;

Map<String, int> decodeMap(String? s) {
  if (s == null || s.isEmpty) return {};
  try {
    return (jsonDecode(s) as Map).map((k, v) => MapEntry(k as String, (v as num).toInt()));
  } catch (_) {
    return {};
  }
}

/// Применить план к хранилищу устройства и вернуть его (показ и планирование делает платформа).
Future<ReminderPlan> processReminders(Repo r, {required bool canSchedule}) async {
  final now = r.clock();
  final plan = planReminders(
    reminders: collectReminders(r),
    fired: decodeMap(r.kv['fired']),
    scheduled: decodeMap(r.kv['scheduled']),
    now: now,
    baseline: int.tryParse(r.kv['notify_from'] ?? '') ?? now,
    today: r.today,
    canSchedule: canSchedule,
  );
  await r.setKv('fired', jsonEncode(plan.fired));
  await r.setKv('scheduled', jsonEncode(plan.scheduled));
  return plan;
}
