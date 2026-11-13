// Логика клиента без сети: повторение задач, пункты планирования, напоминания, правила.
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

/// Задача с одним пунктом планирования.
Future<Ent> planned(Repo r, String title, String date, {int from = -1, int to = -1, bool notify = false, int before = 60}) async {
  final d = r.draftTask(title: title);
  await r.setPlans(d, [PlanItem(r.newPlanId(), date, from: from, to: to, notify: notify, before: before)]);
  return r.addTask(d);
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
    test('по числам месяца', () {
      final rule = {'type': 'monthdays', 'days': [5, 20]};
      expect(nextDeadline('2026-11-05', rule, '2026-11-05'), '2026-11-20');
      expect(nextDeadline('2026-11-20', rule, '2026-11-20'), '2026-12-05');
      // 31-е в месяце, где его нет, — последний день месяца
      final last = {'type': 'monthdays', 'days': [31]};
      expect(nextDeadline('2026-10-31', last, '2026-10-31'), '2026-11-30');
      expect(nextDeadline('2027-01-31', last, '2027-01-31'), '2027-02-28');
      expect(describeRecurrence(rule), 'Каждый месяц: 5, 20 числа');
    });
    test('давно просроченная задача переносится на ближайший день не раньше сегодня', () {
      expect(nextDeadline('2026-10-01', {'type': 'interval', 'n': 1, 'unit': 'week'}, '2026-11-10'), '2026-11-12');
    });

    test('закрытие регулярной задачи создаёт следующий экземпляр со сдвинутыми пунктами', () async {
      var now = DateTime.utc(2026, 11, 10, 8).millisecondsSinceEpoch;
      final r = await makeRepo(clock: () => now);
      final list = await r.createList('Дом', '');
      final d = r.draftTask(title: 'Полить цветы', listId: list.id);
      await r.setPlans(d, [
        PlanItem('a', '2026-11-10', from: 9 * 60, to: 10 * 60, notify: true, before: 30),
        const PlanItem('b', '2026-11-11'),
      ]);
      final t = await r.addTask(d);
      await r.setTaskField(t, 'description', 'все на кухне');
      await r.setTaskField(t, 'checklist', [
        {'text': 'фикус', 'done': true},
        {'text': 'кактус', 'done': false}
      ]);
      await r.setTaskField(t, 'is_important', true);
      await r.setTaskField(t, 'recurrence', {'type': 'interval', 'n': 2, 'unit': 'day'});
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
      expect([for (final p in n.plans) '${p.date} ${p.from} ${p.notify} ${p.before}'], ['2026-11-12 540 true 30', '2026-11-13 -1 false 60']);
      expect(n.title, 'Полить цветы');
      expect(n.description, 'все на кухне');
      expect(n.checklist.map((c) => c['done']), [false, false]);
      expect(n.listId, list.id);
      expect(n.important, isTrue);
      expect(n.done, isFalse);
      expect(n.recurrence, isNotNull);
      final nsub = r.children(n.id);
      expect(nsub, hasLength(1));
      expect(nsub.single.done, isFalse, reason: 'подзадачи копируются открытыми');

      // закрытая задача теряет повторение и пункты на следующие дни; сегодняшний пункт остаётся
      expect(t.recurrence, isNull);
      expect(t.plans.map((p) => p.id), ['a']);
      expect(r.tasksOf(secToday).map((x) => x.id), contains(t.id));

      // переоткрыли и закрыли снова — дубликата нет
      await r.setDone(t, false);
      await r.setDone(t, true);
      expect(r.tasks.values.where((x) => x.parentId.isEmpty), hasLength(2));
    });

    test('регулярная задача без пунктов: следующий экземпляр получает пункт без времени', () async {
      final now = DateTime.utc(2026, 11, 10, 8).millisecondsSinceEpoch;
      final r = await makeRepo(clock: () => now);
      final t = await r.addTask(r.draftTask(title: 'x'));
      await r.setTaskField(t, 'recurrence', {'type': 'daily'});
      await r.setDone(t, true);
      final n = r.tasks.values.firstWhere((x) => x.id != t.id);
      expect(n.plans.map((p) => '${p.date} ${p.timed}'), ['2026-11-11 false']);
    });
  });

  group('пункты планирования', () {
    test('«Сегодня» — задачи с пунктом на сегодня; кнопка добавляет пункт без времени', () async {
      final now = DateTime.utc(2026, 11, 10, 8).millisecondsSinceEpoch; // 12:00 по Саратову
      final r = await makeRepo(clock: () => now);
      await planned(r, 'сегодня', '2026-11-10', from: 600, to: 660);
      await planned(r, 'завтра', '2026-11-11');
      final add = await r.addTask(r.draftTask(title: 'кнопкой'));
      expect(r.plannedToday(add), isFalse);
      await r.addToday(add);
      expect(r.plannedToday(add), isTrue);
      expect(add.plans.single.timed, isFalse);
      await r.addToday(add);
      expect(add.plans, hasLength(1), reason: 'на сегодня уже есть пункт');
      await r.addTask(r.draftTask(title: 'быстрая в «Сегодня»', inToday: true));
      final foreign = await planned(r, 'чужая', '2026-11-10');
      await r.setTaskField(foreign, 'assignee_id', 'other');

      expect(r.tasksOf(secToday).map((t) => t.title).toSet(), {'сегодня', 'кнопкой', 'быстрая в «Сегодня»', 'чужая'});
      expect(r.tasksOf(secSchedule).map((t) => t.title).toSet(), {'сегодня', 'завтра', 'кнопкой', 'быстрая в «Сегодня»', 'чужая'});
      await r.setSetting('home_list', 'planned');
      expect(r.homeSection, secSchedule, reason: 'раздел «Запланировано» убран');
      await r.setSetting('view_mode', 'mine');
      expect(r.tasksOf(secToday).map((t) => t.title), isNot(contains('чужая')));
      expect(r.search('ЗАВТ').single.title, 'завтра');
    });

    test('несколько пунктов в разные дни и в один день', () async {
      final now = DateTime.utc(2026, 11, 10, 8).millisecondsSinceEpoch;
      final r = await makeRepo(clock: () => now);
      final d = r.draftTask(title: 'x');
      await r.setPlans(d, [
        const PlanItem('c', '2026-11-14', from: 16 * 60, to: 16 * 60 + 30),
        const PlanItem('a', '2026-11-14', from: 14 * 60, to: 15 * 60),
        const PlanItem('b', '2026-11-17'),
      ]);
      final t = await r.addTask(d);
      expect(t.plans.map((p) => p.id), ['a', 'c', 'b']);
      expect(r.nextPlan(t)!.id, 'a');
      await r.putPlan(t, t.plans.first.copyWith(date: '2026-11-20'));
      expect(t.plans.map((p) => '${p.id}:${p.date}'), ['c:2026-11-14', 'b:2026-11-17', 'a:2026-11-20']);
      await r.removePlan(t, 'b');
      expect(t.plans.map((p) => p.id), ['c', 'a']);
    });

    test('прошёл день, задача не закрыта и дальше пунктов нет — пункт без времени на новый день', () async {
      var now = DateTime.utc(2026, 11, 10, 8).millisecondsSinceEpoch; // вторник
      final r = await makeRepo(clock: () => now);
      final stuck = await planned(r, 'не успел', '2026-11-10', from: 600, to: 660);
      final ahead = await planned(r, 'есть дальше', '2026-11-10');
      await r.putPlan(ahead, const PlanItem('later', '2026-11-12'));
      final closed = await planned(r, 'закрыта', '2026-11-10');
      await r.setDone(closed, true);

      now = DateTime.utc(2026, 11, 10, 20, 30).millisecondsSinceEpoch; // 00:30 следующего дня по Саратову
      expect(r.overdue(stuck), isTrue);
      await r.dailyMaintenance();
      expect(stuck.plans.map((p) => '${p.date} ${p.timed}'), ['2026-11-10 true', '2026-11-11 false']);
      expect(r.overdue(stuck), isFalse);
      expect(ahead.plans, hasLength(2), reason: 'пункт на будущее уже есть');
      expect(closed.plans, hasLength(1), reason: 'закрытая задача не переносится');
      expect(r.tasksOf(secToday).map((t) => t.title).toList(), ['не успел']);
      // повторно ничего не добавляется
      await r.dailyMaintenance();
      expect(stuck.plans, hasLength(2));
    });

    test('закрытие убирает пункты на следующие дни', () async {
      final now = DateTime.utc(2026, 11, 10, 8).millisecondsSinceEpoch;
      final r = await makeRepo(clock: () => now);
      final t = await planned(r, 'x', '2026-11-09');
      await r.putPlan(t, const PlanItem('today', '2026-11-10'));
      await r.putPlan(t, const PlanItem('later', '2026-11-15', from: 60, to: 120));
      await r.setDone(t, true);
      expect(t.plans.map((p) => p.date), ['2026-11-09', '2026-11-10']);
    });

    test('поля прежних версий переводятся в пункты один раз', () async {
      final now = DateTime.utc(2026, 11, 10, 8).millisecondsSinceEpoch; // 12:00 по Саратову
      final r = await makeRepo(clock: () => now);
      final old = Ent('task', 'old-task-00001', creatorId: 'me', createdAt: now - 1000, f: {
        'title': 'старая',
        'assignee_id': 'me',
        'deadline': '2026-11-12',
        'reminder_at': DateTime.utc(2026, 11, 11, 10).millisecondsSinceEpoch, // 14:00 по Саратову
        'in_today': true,
      }, t: {
        'deadline': now - 900,
        'reminder_at': now - 900,
        'in_today': now - 900,
      });
      await r.mergeServer('task', [old.toJson()]);
      final t = r.tasks['old-task-00001']!;
      await r.dailyMaintenance();
      expect([for (final p in t.plans) '${p.date} ${p.timed ? fmtMin(p.from) : '-'} ${p.notify}'],
          ['2026-11-10 - false', '2026-11-11 14:00 true', '2026-11-12 - true']);
      // удалили пункт — при следующем обслуживании он не возвращается
      await r.removePlan(t, t.plans.last.id);
      await r.dailyMaintenance();
      expect(t.plans, hasLength(2));
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

    test('цвет списка', () async {
      final r = await makeRepo();
      final l = await r.createList('Чтение', '', color: '#2F6FB5');
      expect(l.color, '#2F6FB5');
      await r.setListColor(l, '#C0392B');
      expect(l.color, '#C0392B');
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

    test('старые напоминания (до входа на устройстве, вчерашний день) не показываются', () {
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

    test('уведомление пункта со временем — за заданное время; у копии своя настройка', () async {
      final r = await makeRepo(clock: () => now);
      // 14 число 14:00, за час; копия на 17 число 17:00 — за два часа
      final t = await planned(r, 'встреча', '2026-11-14', from: 14 * 60, to: 15 * 60, notify: true, before: 60);
      final copy = t.plans.single.copyWith(id: r.newPlanId(), date: '2026-11-17', from: 17 * 60, to: 18 * 60);
      await r.putPlan(t, copy);
      await r.putPlan(t, copy.copyWith(before: 120));
      final at = {for (final x in collectReminders(r)) x.at};
      expect(at, {r.momentOf('2026-11-14', '13:00'), r.momentOf('2026-11-17', '15:00')});
      // пункт без уведомления не напоминает
      await r.putPlan(t, t.plans.first.copyWith(notify: false));
      expect(collectReminders(r).map((x) => x.at), [r.momentOf('2026-11-17', '15:00')]);
    });

    test('уведомления приходят только исполнителю', () async {
      final r = await makeRepo(clock: () => now);
      await planned(r, 'моя', '2026-11-11', from: 600, to: 660, notify: true);
      final his = await planned(r, 'чужая', '2026-11-11', from: 600, to: 660, notify: true);
      await r.setTaskField(his, 'assignee_id', 'other');
      expect(collectReminders(r).map((x) => x.title), ['моя']);
    });

    test('задачи без времени на сегодня объявляются одним общим уведомлением', () async {
      var t0 = DateTime.utc(2026, 11, 10, 3).millisecondsSinceEpoch; // 07:00 (UTC+4), напоминания в 09:00
      final r = await makeRepo(clock: () => t0);
      await r.setKv('notify_from', '$t0');
      for (final title in ['Почта', 'Отчёт', 'Корм']) {
        await planned(r, title, '2026-11-10', notify: true);
        t0 += 1000;
      }
      await planned(r, 'Без уведомления', '2026-11-10');
      await planned(r, 'Завтрашняя', '2026-11-11', notify: true);
      // Android: до 09:00 планируется одно уведомление на сегодня (и одно на завтра)
      var plan = await processReminders(r, canSchedule: true);
      expect(plan.schedule.map((x) => x.title).toList()..sort(), ['Завтрашняя', 'Задачи на сегодня: 3']);
      expect(plan.schedule.firstWhere((x) => x.title.startsWith('Задачи')).body, '• Почта\n• Отчёт\n• Корм');
      // Windows: в 09:05 показывается одно уведомление, повторно — нет
      await r.setKv('scheduled', null);
      t0 = DateTime.utc(2026, 11, 10, 5, 5).millisecondsSinceEpoch;
      plan = await processReminders(r, canSchedule: false);
      expect(plan.showNow.map((x) => x.title), ['Задачи на сегодня: 3']);
      expect((await processReminders(r, canSchedule: false)).showNow, isEmpty);
      // закрыли одну задачу — общее уведомление заново не приходит
      await r.setDone(r.tasks.values.firstWhere((t) => t.title == 'Почта'), true);
      expect((await processReminders(r, canSchedule: false)).showNow, isEmpty);
      // задача, которую поручили уже после утреннего уведомления, объявляется отдельно
      final late = Ent('task', 'late-task-0001', creatorId: 'other', createdAt: t0);
      late.f.addAll({
        'title': 'Срочное от другого',
        'assignee_id': 'me',
        'plans': [const PlanItem('x1', '2026-11-10', notify: true).toJson()],
      });
      await r.mergeServer('task', [late.toJson()]);
      plan = await processReminders(r, canSchedule: false);
      expect(plan.showNow.map((x) => x.title), ['Срочное от другого']);
      expect((await processReminders(r, canSchedule: false)).showNow, isEmpty);
    });

    test('одна задача на день — обычное уведомление с её названием', () async {
      var t0 = DateTime.utc(2026, 11, 10, 3).millisecondsSinceEpoch;
      final r = await makeRepo(clock: () => t0);
      await r.setKv('notify_from', '$t0');
      final t = await planned(r, 'Одна', '2026-11-10', notify: true);
      t0 = DateTime.utc(2026, 11, 10, 5, 5).millisecondsSinceEpoch;
      final plan = await processReminders(r, canSchedule: false);
      expect(plan.showNow.single.title, 'Одна');
      expect(plan.showNow.single.taskId, t.id);
    });
  });
}
