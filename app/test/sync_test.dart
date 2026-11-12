// Клиент против настоящего сервера (test/bin/todod.exe собирается из ../server):
// HTTPS с закреплённым ключом, первый администратор, вход, офлайн-правки, переход из локального режима.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:todo_app/core/model.dart';
import 'package:todo_app/core/reminders.dart';
import 'package:todo_app/core/repo.dart';
import 'package:todo_app/core/storage.dart';
import 'package:todo_app/core/sync.dart';
import 'package:todo_app/core/transport.dart';

import 'support.dart';

class Device {
  final Repo repo;
  final SyncEngine sync;
  int skew = 0; // на сколько спешат часы устройства
  Device._(this.repo, this.sync);

  static Future<Device> fresh(TestServer s) async {
    late Device d;
    final repo = Repo(MemoryStorage(), clock: () => DateTime.now().millisecondsSinceEpoch + d.skew);
    final sync = SyncEngine(repo);
    d = Device._(repo, sync);
    await repo.load();
    await repo.setKv('server_url', s.url);
    await repo.setKv('access_key', s.accessKey);
    await repo.setKv('pin', s.pin);
    return d;
  }

  static Future<Device> login(TestServer s, String uid) async {
    final d = await fresh(s);
    await d.sync.hello();
    expect(await d.sync.login(uid, uid == uA ? adminPassword : '', 'test'), isNull);
    expect(await d.sync.sync(), isTrue, reason: d.sync.lastError);
    return d;
  }

  Future<void> ok() async => expect(await sync.sync(), isTrue, reason: '${sync.state} ${sync.lastError}');
  Ent task(String title) => repo.tasks.values.firstWhere((t) => t.title == title);
  Ent? find(String title) => repo.tasks.values.where((t) => t.title == title).firstOrNull;
}

Future<void> tick([int ms = 15]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  tzdata.initializeTimeZones();
  late Directory dir;
  late TestServer s;
  var port = 18443;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('todo-test-');
    s = await TestServer.withUsers(dir, port++);
  });
  tearDown(() async {
    s.proc.kill();
    await s.proc.exitCode;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('сервер с чужим ключом отвергается (закрепление SPKI)', () async {
    final t = createTransport(ServerConfig(url: s.url, accessKey: s.accessKey, pin: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'));
    await expectLater(t.send('GET', '/v1/hello'), throwsA(anything));
    t.close();
  });

  test('офлайн-правки на двух устройствах: по каждому полю побеждает более поздняя', () async {
    final d1 = await Device.login(s, uB), d2 = await Device.login(s, uB);
    await d1.repo.addTask(d1.repo.draftTask(title: 'общая задача'));
    await d1.ok();
    await d2.ok();
    final t1 = d1.task('общая задача'), t2 = d2.task('общая задача');

    d2.skew = 3600000; // часы второго устройства спешат на час
    // офлайн: второе правит название раньше, первое — позже; описание наоборот
    await d2.repo.setTaskField(t2, 'title', 'название от второго');
    await tick();
    await d1.repo.setTaskField(t1, 'title', 'название от первого');
    await d1.repo.setTaskField(t1, 'description', 'описание от первого');
    await tick();
    await d2.repo.setTaskField(t2, 'description', 'описание от второго');
    await d2.repo.setTaskField(t2, 'is_important', true);

    // первое выходит в сеть раньше, второе позже — порядок выхода в сеть не должен влиять
    await d1.ok();
    await d2.ok();
    await d1.ok();
    for (final t in [t1, t2]) {
      expect(t.title, 'название от первого');
      expect(t.description, 'описание от второго');
      expect(t.important, isTrue);
      expect(t.d, isEmpty);
    }
  });

  test('регулярная задача, закрытая на двух устройствах офлайн, даёт один следующий экземпляр', () async {
    final d1 = await Device.login(s, uB), d2 = await Device.login(s, uB);
    final t = await d1.repo.addTask(d1.repo.draftTask(title: 'зарядка', deadline: d1.repo.today));
    await d1.repo.setTaskField(t, 'recurrence', {'type': 'daily'});
    await d1.ok();
    await d2.ok();
    await d1.repo.setDone(d1.task('зарядка'), true);
    await d2.repo.setDone(d2.repo.tasks.values.firstWhere((x) => x.title == 'зарядка' && !x.done), true);
    await d1.ok();
    await d2.ok();
    await d1.ok();
    for (final d in [d1, d2]) {
      final all = d.repo.tasks.values.where((x) => x.title == 'зарядка').toList();
      expect(all, hasLength(2), reason: 'исходная и один следующий экземпляр');
      expect(all.where((x) => !x.done).single.deadline, addDays(d.repo.today, 1));
    }
  });

  test('права: исполнитель закрывает, но не правит; чужая приватная не приходит; удаление доходит', () async {
    final b = await Device.login(s, uB), c = await Device.login(s, uC), a = await Device.login(s, uA);
    final shared = await b.repo.addTask(b.repo.draftTask(title: 'для Клары'));
    await b.repo.setTaskField(shared, 'assignee_id', uC);
    await b.repo.addTask(b.repo.draftTask(title: 'секрет Боба', private: true));
    await b.ok();
    await c.ok();
    await a.repo.setSetting('admin_mode', true);
    await a.ok();
    expect(c.find('секрет Боба'), isNull);
    expect(a.find('секрет Боба'), isNull, reason: 'даже админ в режиме администратора не получает чужие приватные');
    expect(a.find('для Клары'), isNotNull);

    final ct = c.task('для Клары');
    expect(c.repo.canEdit(ct), isFalse);
    expect(c.repo.canToggle(ct), isTrue);
    await c.repo.setTaskField(ct, 'title', 'переименовала');
    await c.repo.setDone(ct, true);
    await c.ok();
    expect(ct.title, 'для Клары', reason: 'отклонённая правка откатывается версией сервера');
    expect(ct.done, isTrue);
    await b.ok();
    expect(shared.done, isTrue);

    // админ в режиме администратора правит общую задачу
    await a.repo.setTaskField(a.task('для Клары'), 'title', 'поправил админ');
    await a.ok();
    await b.ok();
    expect(shared.title, 'поправил админ');

    // удаление автором доходит до всех
    await b.repo.deleteTask(shared);
    await b.ok();
    await c.ok();
    expect(c.find('поправил админ'), isNull);
  });

  test('списки с исполнителем и подзадачи через сервер', () async {
    final b = await Device.login(s, uB), c = await Device.login(s, uC);
    final list = await b.repo.createList('Кларе', uC);
    final t = await b.repo.addTask(b.repo.draftTask(title: 'в списке', listId: list.id));
    final sub = await b.repo.addTask(b.repo.draftTask(title: 'подзадача', parentId: t.id));
    await b.ok();
    await c.ok();
    expect(c.task('в списке').assigneeId, uC);
    expect(c.task('подзадача').listId, list.id);
    // Клара добавляет задачу в список Боба: исполнителем становится исполнитель списка
    await c.repo.addTask(c.repo.draftTask(title: 'от Клары', listId: list.id));
    // смена исполнителя списка
    await b.repo.setListAssignee(list, uB);
    await b.ok();
    await c.ok();
    await b.ok();
    expect(b.task('в списке').assigneeId, uB);
    expect(b.task('от Клары').assigneeId, uB);
    expect(c.task('от Клары').assigneeId, uB);
    // закрыть основную при открытой подзадаче нельзя
    expect(b.repo.closeBlocker(t), isNotNull);
    await b.repo.setDone(sub, true);
    await b.repo.setDone(t, true);
    await b.ok();
    await c.ok();
    expect(c.task('в списке').done, isTrue);
    // удаление списка с переносом задач в общий раздел
    await b.repo.deleteList(list, deleteTasks: false);
    await b.ok();
    await c.ok();
    expect(c.repo.lists, isEmpty);
    expect(c.task('от Клары').listId, '');
  });

  test('удалённый пользователь: устройство перестаёт синхронизироваться, данные остаются', () async {
    final b = await Device.login(s, uB), c = await Device.login(s, uC);
    await b.repo.addTask(b.repo.draftTask(title: 'личная', private: true));
    final shared = await b.repo.addTask(b.repo.draftTask(title: 'общая Боба'));
    await b.repo.setTaskField(shared, 'assignee_id', uB);
    await b.ok();
    await c.ok();
    expect((await s.admin('DELETE', '/v1/admin/users/$uB')).ok, isTrue);
    expect(await b.sync.sync(), isFalse);
    expect(b.sync.state, SyncState.detached);
    expect(b.repo.detached, isTrue);
    expect(b.find('личная'), isNotNull, reason: 'локальные данные остаются, приложение работает автономно');
    await b.repo.addTask(b.repo.draftTask(title: 'после удаления'));
    expect(b.find('после удаления'), isNotNull);
    await c.ok();
    final t = c.task('общая Боба');
    expect(t.creatorId, uA, reason: 'общие задачи переходят к админу');
    expect(t.assigneeId, uA);
    expect(c.repo.users.map((u) => u.id), isNot(contains(uB)));
  });

  test('напоминание, пришедшее с опозданием, срабатывает сразу после синхронизации', () async {
    final b = await Device.login(s, uB), c = await Device.login(s, uC);
    await c.repo.setKv('notify_from', '${c.repo.clock() - 3600000}'); // устройство вошло час назад и было офлайн
    final t = await b.repo.addTask(b.repo.draftTask(title: 'позвонить'));
    await b.repo.setTaskField(t, 'assignee_id', uC);
    await b.repo.setTaskField(t, 'reminder_at', b.repo.clock() - 10 * 60000); // время напоминания уже прошло
    await b.ok();
    expect((await processReminders(b.repo, canSchedule: true)).showNow, isEmpty, reason: 'уведомления только исполнителю');
    await c.ok();
    final plan = await processReminders(c.repo, canSchedule: true);
    expect(plan.showNow.map((r) => r.title), ['позвонить']);
    expect((await processReminders(c.repo, canSchedule: true)).showNow, isEmpty, reason: 'второй раз не показывается');
  });

  test('новый сервер: первый вошедший создаёт администратора, второй раз — нельзя', () async {
    final s2 = await TestServer.start(dir, port++);
    addTearDown(() async {
      s2.proc.kill();
      await s2.proc.exitCode;
    });
    final d = await Device.fresh(s2);
    await d.sync.hello();
    expect(d.sync.setupNeeded, isTrue);
    expect(await d.sync.setup('Аня', '1234', 'test'), isNull);
    await d.ok();
    expect(d.repo.meUser?.name, 'Аня');
    expect(d.repo.isAdmin, isTrue);
    // администратор заводит пользователя из приложения, тот входит со своим паролем
    expect(await d.sync.createUser('Петя', 'petya', false), isNull);
    final petya = d.repo.users.firstWhere((u) => u.name == 'Петя');
    expect(petya.hasPassword, isTrue);
    final p = await Device.fresh(s2);
    await p.sync.hello();
    expect(p.sync.setupNeeded, isFalse);
    expect(await p.sync.setup('Захватчик', '1234', 'test'), isNotNull);
    expect(await p.sync.login(petya.id, 'не тот', 'test'), isNotNull);
    expect(await p.sync.login(petya.id, 'petya', 'test'), isNull);
    await p.ok();
    // смена пароля администратором: устройство Пети должно войти заново
    expect(await d.sync.updateUser(petya.id, password: 'новый'), isNull);
    expect(await p.sync.sync(), isFalse);
    expect(p.sync.state, SyncState.needLogin);
  });

  test('локальный режим, затем подключение к серверу: задачи переезжают к вошедшему', () async {
    final d = await Device.fresh(s);
    await d.repo.startLocal();
    expect(d.repo.isLocal, isTrue);
    expect(await d.sync.sync(), isTrue, reason: 'без сервера синхронизация ничего не делает и не падает');
    final l = await d.repo.createList('Дом', '');
    final t = await d.repo.addTask(d.repo.draftTask(title: 'купить хлеб', listId: l.id));
    await d.repo.addTask(d.repo.draftTask(title: 'подзадача', parentId: t.id));
    final done = await d.repo.addTask(d.repo.draftTask(title: 'уже сделано'));
    await d.repo.setDone(done, true);
    await d.repo.setSetting('accent', '#123456');

    await d.sync.hello();
    expect(await d.sync.login(uB, '', 'test'), isNull);
    await d.ok();
    expect(d.repo.isLocal, isFalse);
    expect(d.task('купить хлеб').creatorId, uB);
    expect(d.task('купить хлеб').assigneeId, uB);

    // на другом устройстве Боба всё это видно
    final b2 = await Device.login(s, uB);
    expect(b2.task('купить хлеб').listId, b2.repo.lists.values.firstWhere((x) => x.name == 'Дом').id);
    expect(b2.task('подзадача').parentId, b2.task('купить хлеб').id);
    expect(b2.task('уже сделано').done, isTrue);
    expect(b2.repo.setting<String>('accent', ''), '#123456');
  });
}