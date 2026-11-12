// Напоминания: расчёт того, что показать сейчас, что запланировать и что отменить.
// Чистая логика без плагинов — её проверяют тесты.
import 'dart:convert';

import 'repo.dart';

class Reminder {
  final String key; // стабильный ключ: меняется вместе с временем напоминания
  final String taskId;
  final String title;
  final String body;
  final int at;
  final bool isDeadline;
  final String date; // для напоминаний по дедлайну — день дедлайна
  const Reminder(this.key, this.taskId, this.title, this.body, this.at, {this.isDeadline = false, this.date = ''});

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
  for (final t in r.tasks.values) {
    if (t.deleted || t.done || t.assigneeId != r.me) continue;
    if (t.reminderAt > 0) {
      out.add(Reminder('r:${t.id}:${t.reminderAt}', t.id, t.title, 'Напоминание', t.reminderAt));
    }
    if (t.deadline.isNotEmpty) {
      final at = r.momentOf(t.deadline, r.deadlineTime);
      // свою задачу, созданную уже после времени напоминаний, не объявляем тут же
      if (t.creatorId == r.me && t.createdAt > at) continue;
      out.add(Reminder('d:${t.id}:${t.deadline}:${r.deadlineTime}', t.id, t.title, 'Срок сегодня', at, isDeadline: true, date: t.deadline));
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
    if (p.fired.containsKey(r.key)) continue;
    if (r.at > now) {
      if (canSchedule) {
        p.scheduled[r.key] = r.at;
        if (scheduled[r.key] != r.at) p.schedule.add(r);
      }
      continue;
    }
    // время уже наступило
    p.fired[r.key] = r.at;
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
