// Логика клиента без сети: повторение задач, напоминания, правила.
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:todo_app/core/model.dart';
import 'package:todo_app/core/reminders.dart';
import 'package:todo_app/core/repo.dart';
import 'package:todo_app/core/storage.dart';

Future<Repo> makeRepo({int Function()? clock}) async {
  final r = Repo(MemoryStorage(), clock: clock);
  await r.load();
  await r.setKv('user_id', 'me');
  await r.setUsers(const [User('me', 'Я'), User('other', 'Другой')]);
  r.global = {'tz': 'Europe/Samara'}; // UTC+4: даты в тестах не зависят от пояса компьютера
  return r;
}

void main() {
  tzdata.initializeTimeZones();

  group('повторение', () {
    test('каждый день', () => expect(nextDeadline('2026-11-10', {'type': 'daily'}, '2026-11-10'), '2026-11-11'));
    test('по дням недели', () {
      // 10.11.2026 — вторник; пн/ср/пт
      final rule = {'type': 'weekly', 'days': [1, 3, 5]};
      expect(nextDeadline('2026-11-10', rule, '2026-11-10'), '2026-11-11');
      expect(nextDeadline('2026-11-13', rule, '2026-11-10'), '2026-11-16');
    });
    test('каждые N дней, недель, месяцев', () {
      expect(nextDeadline('2026-11-10', {'type': 'interval', 'n': 3, 'unit': 'day'}, '2026-11-10'), '2026-11-13');
      expect(nextDeadline('2026-11-10', {'type': 'interval', 'n': 2, 'unit': 'week'}, '2026-11-10'), '2026-11-24');
      expect(nextDeadline('2026-01-31', {'type': 'interval', 'n': 1, 'unit': 'month'}, '2026-01-31'), '2026-02-28');
      expect(nextDeadline('2026-11-30', {'type': 'interval', 'n': 3, 'unit': 'month'}, '2026-11-30'), '2027-02-28');
    });
    test('ежегодно', () => expect(nextDeadline('2024-02-29', {'type': 'yearly'}, '2024-02-29'), '2025-02-28'));
    test('давно просроченная задача переносится на ближайший день не раньше сегодня', () {
      expect(nextDeadline('2026-10-01', {'type': 'interval', 'n': 1, 'unit': 'week'}, '2026-11-10'), '2026-11-12');
    });

    test('закрытие регулярной задачи создаёт следующий экземпляр', () async {
      var now = DateTime.utc(2026, 11, 10, 8).millisecondsSinceEpoch;
      final r = await makeRepo(clock: () => now);
      final list = await r.createList('Дом', '');
      final t = await r.addTask(r.draftTask(title: 'Полить цветы', listId: list.id, deadline: '2026-11-10'));
      await r.setTaskField(t, 'description', 'все на кухне');
      await r.setTaskField(t, 'checklist', [
        {'text': 'фикус', 'done': true},
        {'text': 'кактус', 'done': false}
      ]);
      await r.setTaskField(t, 'is_important', true);
      await r.setTaskField(t, 'in_today', true);
      await r.setTaskField(t, 'recurrence', {'type': 'interval', 'n': 2, 'unit': 'day'});
      final rem = DateTime.utc(2026, 11, 10, 6).millisecondsSinceEpoch;
      await r.setTaskField(t, 'reminder_at', rem);
      final sub = await r.addTask(r.draftTask(title: 'Набрать воды', parentId: t.id));

      // основную задачу нельзя закрыть, пока открыта подзадача
      expect(r.closeBlocker(t), isNotNull);
      await r.setDone(t, true);
      expect(t.done, isFalse);

      await r.setDone(sub, true);
      now += 60000;
      await r.setDone(t, true);
      expect(t.done, isTrue);

      final next = r.tasks.values.where((x) => x.id != t.id && x.parentId.isEmpty).toList();
      expect(next, hasLength(1));
      final n = next.single;
      expect(n.id, isNot(t.id));
      expect(n.deadline, '2026-11-12');
      expect(n.title, 'Полить цветы');
      expect(n.description, 'все на кухне');
      expect(n.checklist.map((c) => c['done']), [false, false]);
      expect(n.listId, list.id);
      expect(n.assigneeId, 'me');
      expect(n.important, isTrue);
      expect(n.inToday, isFalse);
      expect(n.done, isFalse);
      expect(n.reminderAt, rem + 2 * 86400000, reason: 'напоминание сдвигается вместе с дедлайном');
      expect(n.recurrence, isNotNull);
      final nsub = r.children(n.id);
      expect(nsub, hasLength(1));
      expect(nsub.single.title, 'Набрать воды');
      expect(nsub.single.done, isFalse, reason: 'подзадачи копируются открытыми');

      // закрытая задача теряет срок и повторение; в «Сегодня» она остаётся до конца дня
      expect(t.deadline, '');
      expect(t.recurrence, isNull);
      expect(t.inToday, isTrue);

      // переоткрыли и закрыли снова — дубликата нет
      await r.setDone(t, false);
      await r.setDone(t, true);
      expect(r.tasks.values.where((x) => x.parentId.isEmpty), hasLength(2));
    });

    test('закрытие снимает срок; задача со сроком на сегодня остаётся в «Сегодня» до конца дня', () async {
      final now = DateTime.utc(2026, 11, 10, 8).millisecondsSinceEpoch;
      final r = await makeRepo(clock: () => now);
      final t = await r.addTask(r.draftTask(title: 'сегодня', deadline: '2026-11-10'));
      final later = await r.addTask(r.draftTask(title: 'через неделю', deadline: '2026-11-17'));
      await r.setDone(t, true);
      await r.setDone(later, true);
      expect([t.deadline, later.deadline], ['', '']);
      expect(r.tasksOf(secToday).map((x) => x.title).toList(), ['сегодня'], reason: 'закрытая сегодняшняя видна в «Сегодня», недельная туда не попадает');
      // переоткрытая — как новая: срока нет
      await r.setDone(later, false);
      expect(later.deadline, '');
    });

    test('срок нельзя поставить на прошедший день', () async {
      final now = DateTime.utc(2026, 11, 10, 8).millisecondsSinceEpoch;
      final r = await makeRepo(clock: () => now);
      final t = await r.addTask(r.draftTask(title: 'x', deadline: '2026-11-12'));
      await r.setTaskField(t, 'deadline', '2026-11-09');
      expect(t.deadline, '2026-11-12');
      await r.setTaskField(t, 'deadline', '2026-11-10');
      expect(t.deadline, '2026-11-10');
    });

    test('без дедлайна повторение сбрасывается', () async {
      final r = await makeRepo();
      final t = await r.addTask(r.draftTask(title: 'x', deadline: '2026-11-10'));
      await r.setTaskField(t, 'recurrence', {'type': 'daily'});
      await r.setTaskField(t, 'deadline', '');
      expect(t.recurrence, isNull);
    });
  });

  group('правила задач', () {
    test('список с исполнителем назначает исполнителя', () async {
      final r = await makeRepo();
      final l = await r.createList('Для другого', 'other');
      final quick = await r.addTask(r.draftTask(title: 'быстрая', listId: l.id));
      expect(quick.assigneeId, 'other');
      final t = await r.addTask(r.draftTask(title: 'моя'));
      await r.setTaskField(t, 'list_id', l.id);
      expect(t.assigneeId, 'other');
      expect(r.privateAllowed(l.id), isFalse);
      expect(r.privateAllowed(''), isTrue);
    });

    test('приватная задача: исполнитель — автор, подзадача наследует приватность и список', () async {
      final r = await makeRepo();
      final l = await r.createList('Мой', '');
      final p = await r.addTask(r.draftTask(title: 'секрет', private: true, listId: l.id));
      expect(p.assigneeId, 'me');
      final s = await r.addTask(r.draftTask(title: 'под', parentId: p.id));
      expect(s.isPrivate, isTrue);
      expect(s.listId, l.id);
    });

    test('«Сегодняшний день», «Запланировано» и режимы отображения', () async {
      final now = DateTime.utc(2026, 11, 10, 8).millisecondsSinceEpoch; // 12:00 (UTC+4)
      final r = await makeRepo(clock: () => now);
      await r.addTask(r.draftTask(title: 'просрочена', deadline: '2026-11-08'));
      await r.addTask(r.draftTask(title: 'сегодня', deadline: '2026-11-10'));
      await r.addTask(r.draftTask(title: 'завтра', deadline: '2026-11-11'));
      await r.addTask(r.draftTask(title: 'вручную', inToday: true));
      final rem = await r.addTask(r.draftTask(title: 'напоминание'));
      await r.setTaskField(rem, 'reminder_at', now + 3600000);
      final foreign = await r.addTask(r.draftTask(title: 'чужая'));
      await r.setTaskField(foreign, 'assignee_id', 'other');
      await r.setTaskField(foreign, 'in_today', true);

      expect(r.tasksOf(secToday).map((t) => t.title).toSet(), {'просрочена', 'сегодня', 'вручную', 'напоминание', 'чужая'});
      expect(r.tasksOf(secPlanned).map((t) => t.title).toSet(), {'просрочена', 'сегодня', 'завтра'});
      await r.setSetting('view_mode', 'mine');
      expect(r.tasksOf(secToday).map((t) => t.title), isNot(contains('чужая')));
      expect(r.search('ЗАВТ').single.title, 'завтра');
    });

    test('«Сегодня» по окончании дня: закрытые задачи уходят, открытые с меткой переносятся', () async {
      var now = DateTime.utc(2026, 11, 10, 8).millisecondsSinceEpoch; // вторник, 12:00 (UTC+4)
      final r = await makeRepo(clock: () => now);
      final closed = await r.addTask(r.draftTask(title: 'закрыта', inToday: true));
      final open = await r.addTask(r.draftTask(title: 'открыта', inToday: true));
      final unmarked = await r.addTask(r.draftTask(title: 'метку сняли', inToday: true));
      final closedLate = await r.addTask(r.draftTask(title: 'закрыта в 23:30', inToday: true));
      await r.setDone(closed, true);
      await r.setTaskField(unmarked, 'in_today', false);
      now = DateTime.utc(2026, 11, 10, 19, 30).millisecondsSinceEpoch; // 23:30 (UTC+4)
      await r.setDone(closedLate, true);
      // в тот же день закрытые задачи остаются в разделе
      expect(r.tasksOf(secToday).map((t) => t.title).toSet(), {'закрыта', 'открыта', 'закрыта в 23:30'});

      now = DateTime.utc(2026, 11, 10, 20, 30).millisecondsSinceEpoch; // 00:30 следующего дня (UTC+4)
      expect(r.tasksOf(secToday).map((t) => t.title).toList(), ['открыта']);
      await r.rollToday();
      expect([closed.inToday, open.inToday, unmarked.inToday, closedLate.inToday], [false, true, false, false]);
      // переоткрытая потом задача в «Сегодня» сама не возвращается
      await r.setDone(closed, false);
      expect(r.tasksOf(secToday).map((t) => t.title).toList(), ['открыта']);
    });
  });

  group('напоминания', () {
    const day = 86400000;
    final now = DateTime.utc(2026, 11, 10, 8).millisecondsSinceEpoch;
    Reminder rem(String key, int at, {bool deadline = false, String date = ''}) => Reminder(key, 't', 'Задача', '', at, isDeadline: deadline, date: date);

    test('будущее напоминание планируется, наступившее — показывается один раз', () {
      var p = planReminders(reminders: [rem('a', now + 1000)], fired: {}, scheduled: {}, now: now, baseline: now - day, today: '2026-11-10', canSchedule: true);
      expect(p.schedule.single.key, 'a');
      expect(p.showNow, isEmpty);
      // система показала его сама в назначенное время — повторно не показываем
      p = planReminders(reminders: [rem('a', now + 1000)], fired: p.fired, scheduled: p.scheduled, now: now + 5000, baseline: now - day, today: '2026-11-10', canSchedule: true);
      expect(p.showNow, isEmpty);
      expect(p.fired.containsKey('a'), isTrue);
    });

    test('напоминание, пришедшее с опозданием, срабатывает сразу', () {
      // задача пришла при синхронизации уже после времени напоминания
      final p = planReminders(reminders: [rem('late', now - 20 * 60000)], fired: {}, scheduled: {}, now: now, baseline: now - day, today: '2026-11-10', canSchedule: true);
      expect(p.showNow.single.key, 'late');
      // и только один раз
      final p2 = planReminders(reminders: [rem('late', now - 20 * 60000)], fired: p.fired, scheduled: p.scheduled, now: now + 60000, baseline: now - day, today: '2026-11-10', canSchedule: true);
      expect(p2.showNow, isEmpty);
    });

    test('без системного планировщика (Windows) напоминание показывается по наступлении времени', () {
      var p = planReminders(reminders: [rem('w', now + 1000)], fired: {}, scheduled: {}, now: now, baseline: now - day, today: '2026-11-10', canSchedule: false);
      expect(p.showNow, isEmpty);
      expect(p.schedule, isEmpty);
      p = planReminders(reminders: [rem('w', now + 1000)], fired: p.fired, scheduled: p.scheduled, now: now + 2000, baseline: now - day, today: '2026-11-10', canSchedule: false);
      expect(p.showNow.single.key, 'w');
    });

    test('старые напоминания (до входа на устройстве, вчерашний дедлайн) не показываются', () {
      final p = planReminders(reminders: [
        rem('before-login', now - 3 * day),
        rem('yesterday-deadline', now - day + 1000, deadline: true, date: '2026-11-09'),
        rem('today-deadline', now - 3600000, deadline: true, date: '2026-11-10'),
      ], fired: {}, scheduled: {}, now: now, baseline: now - 2 * day, today: '2026-11-10', canSchedule: true);
      expect(p.showNow.map((r) => r.key), ['today-deadline']);
    });

    test('изменённое напоминание отменяет прежнее', () {
      final p = planReminders(reminders: [rem('new', now + 9000)], fired: {}, scheduled: {'old': now + 5000}, now: now, baseline: now, today: '2026-11-10', canSchedule: true);
      expect(p.cancel, hasLength(1));
      expect(p.schedule.single.key, 'new');
    });

    test('уведомления приходят только исполнителю', () async {
      final r = await makeRepo(clock: () => now);
      final mine = await r.addTask(r.draftTask(title: 'моя'));
      await r.setTaskField(mine, 'reminder_at', now + 1000);
      final his = await r.addTask(r.draftTask(title: 'чужая'));
      await r.setTaskField(his, 'assignee_id', 'other');
      await r.setTaskField(his, 'reminder_at', now + 1000);
      await r.setTaskField(his, 'deadline', '2026-11-12');
      expect(collectReminders(r).map((x) => x.title), ['моя']);
    });
  });
}
