// Интерфейс: основные сценарии и снимки экрана (test/goldens/*.png, обновляются флагом --update-goldens).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:todo_app/app.dart';
import 'package:todo_app/core/model.dart';
import 'package:todo_app/core/repo.dart';
import 'package:todo_app/core/storage.dart';
import 'package:todo_app/core/sync.dart';
import 'package:todo_app/core/transport.dart';
import 'package:todo_app/main.dart';
import 'package:todo_app/platform/platform_io.dart' show widgetSnapshot;
import 'package:todo_app/platform/platform_stub.dart';
import 'package:todo_app/ui/common.dart';
import 'package:todo_app/ui/task_editor.dart';
import 'package:todo_app/ui/task_list.dart';

class _NoNet implements Transport {
  @override
  Future<Resp> send(String method, String path, {Object? body}) async => throw const SocketException('offline');
  @override
  void close() {}
}

/// Сервер-заглушка: ответы по «МЕТОД путь»; всё остальное — «нет связи». [calls] — что запрашивали.
class _Fake implements Transport {
  final Map<String, Map<String, dynamic>> answers;
  final List<String> calls;
  _Fake(this.answers, this.calls);
  @override
  Future<Resp> send(String method, String path, {Object? body}) async {
    final key = '$method ${path.split('?').first}';
    calls.add('$key ${body is Map ? jsonEncode(body) : ''}'.trim());
    final a = answers[key];
    if (a == null) throw const SocketException('offline');
    return Resp(200, utf8.encode(jsonEncode(a)));
  }

  @override
  void close() {}
}

class _WithWidget extends NoopPlatform {
  @override
  bool get hasHomeWidget => true;
}

Future<void> loadFonts() async {
  Future<ByteData> file(String p) async => ByteData.view(File(p).readAsBytesSync().buffer);
  final roboto = FontLoader('Roboto')
    ..addFont(file('fonts/roboto-regular.ttf'))
    ..addFont(file('fonts/roboto-medium.ttf'))
    ..addFont(file('fonts/roboto-bold.ttf'));
  await roboto.load();
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final icons = FontLoader('MaterialIcons')..addFont(file('$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf'));
    await icons.load();
  }
}

const me = 'me', other = 'other';
final now = DateTime.utc(2026, 11, 10, 8).millisecondsSinceEpoch; // вторник, 12:00 (UTC+4)

Future<Repo> seed() async {
  var tick = 0; // время идёт: порядок задач в списке однозначен
  final r = Repo(MemoryStorage(), clock: () => now + tick++);
  await r.load();
  await r.setKv('user_id', me);
  await r.setKv('token', 't');
  await r.setKv('server_url', 'https://example');
  await r.setUsers(const [User(me, 'Аня', isAdmin: true, hasPassword: true), User(other, 'Вера')]);
  r.global = {'tz': 'Europe/Samara'}; // UTC+4: даты в тестах не зависят от пояса компьютера
  final home = await r.createList('Дом', '');
  final hers = await r.createList('Вере', other);
  final t1 = await r.addTask(r.draftTask(title: 'Разобрать почту', inToday: true));
  await r.setTaskField(t1, 'is_important', true);
  final t2 = await r.addTask(r.draftTask(title: 'Оплатить интернет', date: '2026-11-08', listId: home.id));
  await r.setTaskField(t2, 'recurrence', {'type': 'interval', 'n': 1, 'unit': 'month'});
  final t3 = await r.addTask(r.draftTask(title: 'Подготовить отчёт'));
  await r.setPlans(t3, [const PlanItem('rep14', '2026-11-10', from: 14 * 60, to: 15 * 60, notify: true, before: 0)]);
  await r.setTaskField(t3, 'description', 'Собрать цифры за октябрь');
  await r.setTaskField(t3, 'checklist', [
    {'text': 'выгрузка', 'done': true},
    {'text': 'графики', 'done': false}
  ]);
  await r.addTask(r.draftTask(title: 'Собрать данные', parentId: t3.id));
  final s2 = await r.addTask(r.draftTask(title: 'Свести таблицу', parentId: t3.id));
  await r.setDone(s2, true);
  await r.addTask(r.draftTask(title: 'Личное: врач', private: true, date: '2026-11-12'));
  await r.addTask(r.draftTask(title: 'Купить корм коту', listId: hers.id, date: '2026-11-11'));
  final d = await r.addTask(r.draftTask(title: 'Полить цветы', inToday: true));
  await r.setDone(d, true);
  await r.dailyMaintenance(); // просроченная задача переходит на сегодня
  return r;
}

Future<void> pumpApp(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const TodoApp());
  await tester.pumpAndSettle();
}

/// Прокрутить карточку задачи до нужного блока.
Future<void> reveal(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 120, scrollable: find.descendant(of: find.byType(TaskEditor), matching: find.byType(Scrollable)).first);
  await tester.pumpAndSettle(); // прокрутка довыполняется на следующем кадре
}

Future<void> shot(WidgetTester tester, String name) =>
    expectLater(find.byType(TodoApp), matchesGoldenFile('goldens/$name.png'));

void main() {
  tzdata.initializeTimeZones();

  setUp(() async {
    await loadFonts();
    final repo = await seed();
    app = AppState(repo, SyncEngine(repo, factory: (_) => _NoNet()), NoopPlatform());
    app.section = secToday;
  });

  testWidgets('три колонки: разделы, задачи с подзадачами, карточка', (tester) async {
    await pumpApp(tester, const Size(1280, 800));
    expect(find.text('Сегодняшний день'), findsWidgets);
    expect(find.text('Разобрать почту'), findsOneWidget);
    expect(find.text('Оплатить интернет'), findsOneWidget, reason: 'просроченная задача видна в «Сегодня»');
    expect(find.text('Собрать данные'), findsOneWidget, reason: 'подзадача показана под основной');
    expect(find.text('Купить корм коту'), findsNothing);
    expect(find.text('Полить цветы'), findsOneWidget, reason: 'блок «Завершённые» по умолчанию развёрнут');
    await shot(tester, 'desktop_today');

    await tester.tap(find.text('Завершённые'));
    await tester.pumpAndSettle();
    expect(find.text('Полить цветы'), findsNothing);

    await tester.tap(find.text('Подготовить отчёт'));
    await tester.pumpAndSettle();
    expect(find.text('Задача'), findsOneWidget);
    expect(find.text('Собрать цифры за октябрь'), findsOneWidget);
    expect(find.text('Сегодня, 14:00–15:00'), findsOneWidget, reason: 'пункт планирования в карточке');
    expect(find.text('Добавить в «Сегодня»'), findsNothing, reason: 'на сегодня пункт уже есть');
    expect(find.textContaining('Тэг'), findsNothing, reason: 'тэгов в этой версии нет');
    await shot(tester, 'desktop_task');

    // основную задачу нельзя закрыть при открытой подзадаче
    final parent = app.repo.tasks.values.firstWhere((t) => t.title == 'Подготовить отчёт');
    await tester.tap(find.descendant(of: find.widgetWithText(TaskRow, 'Подготовить отчёт'), matching: find.byType(RoundCheck)));
    await tester.pump();
    expect(parent.done, isFalse);
    expect(find.text('Сначала закройте подзадачи'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 4));
  });

  testWidgets('быстрое добавление в «Сегодня» и в список с исполнителем', (tester) async {
    await pumpApp(tester, const Size(1280, 800));
    await tester.enterText(find.widgetWithText(TextField, 'Добавить задачу'), 'Новая задача');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final t = app.repo.tasks.values.firstWhere((x) => x.title == 'Новая задача');
    expect(app.repo.plannedToday(t), isTrue);
    expect(t.plans.single.timed, isFalse, reason: 'в «Сегодня» — пункт без времени');
    expect(t.assigneeId, me);
    expect(find.text('Новая задача'), findsOneWidget);

    await tester.tap(find.text('Вере'));
    await tester.pumpAndSettle();
    expect(find.text('Исполнитель: Вера'), findsOneWidget);
    expect(find.text('Купить корм коту'), findsOneWidget);
    // переключатель приватности неактивен: у списка другой исполнитель
    final lock = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.lock_open_outlined));
    expect(lock.onPressed, isNull);
    await tester.enterText(find.widgetWithText(TextField, 'Добавить задачу'), 'Для Веры');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final t2 = app.repo.tasks.values.firstWhere((x) => x.title == 'Для Веры');
    expect(t2.assigneeId, other);
    expect(t2.planned, isFalse);
    await shot(tester, 'desktop_list');
  });

  testWidgets('пункты без времени — пунктиром в начале дня; перетаскивание на шкалу и обратно; «Только свои»; поиск', (tester) async {
    await pumpApp(tester, const Size(1280, 800));
    expect(find.text('Запланировано'), findsNothing, reason: 'раздел заменён «Планированием»');
    await tester.tap(find.text('Планирование'));
    await tester.pumpAndSettle();
    // перенесённая на сегодня и сегодняшняя — в сегодняшнем дне, остальные — в своих днях
    for (final s in ['Оплатить интернет', 'Подготовить отчёт', 'Купить корм коту', 'Личное: врач']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    final x0 = tester.getCenter(find.text('вт, 10')).dx, x2 = tester.getCenter(find.text('чт, 12')).dx;
    expect((tester.getCenter(find.text('Оплатить интернет')).dx - x0).abs(), lessThan(80));
    expect((tester.getCenter(find.text('Личное: врач')).dx - x2).abs(), lessThan(80));
    await shot(tester, 'desktop_schedule_due');

    // перетащили на шкалу — пункт получает время в том дне и часе, куда его отпустили (на час)
    final doctor = app.repo.tasks.values.firstWhere((t) => t.title == 'Личное: врач');
    var from = tester.getCenter(find.text('Личное: врач'));
    var to = Offset(tester.getCenter(find.text('пт, 13')).dx, tester.getCenter(find.text('15:00')).dy + 8);
    await tester.dragFrom(from, to - from, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(doctor.plans.map((p) => '${p.date} ${fmtMin(p.from)}–${fmtMin(p.to)}'), ['2026-11-13 15:00–16:00']);

    // и обратно в зону «без времени» другого дня
    from = tester.getCenter(find.text('Личное: врач'));
    to = Offset(tester.getCenter(find.text('ср, 11')).dx, tester.getCenter(find.text('Купить корм коту')).dy);
    await tester.dragFrom(from, to - from, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(doctor.plans.map((p) => '${p.date} ${p.timed}'), ['2026-11-11 false']);

    await tester.tap(find.text('Только свои'));
    await tester.pumpAndSettle();
    expect(find.text('Купить корм коту'), findsNothing);
    expect(find.text('Вере'), findsNothing, reason: 'список чужого исполнителя скрыт');
    expect(find.text('Личное: врач'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Поиск'), 'графики');
    await tester.pumpAndSettle();
    expect(find.text('Подготовить отчёт'), findsOneWidget, reason: 'поиск по чек-листу');
    expect(find.text('Разобрать почту'), findsNothing);
  });

  testWidgets('полная форма создания и настройки', (tester) async {
    await pumpApp(tester, const Size(1280, 800));
    await tester.tap(find.byTooltip('Полная форма').first);
    await tester.pumpAndSettle();
    expect(find.text('Новая задача'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Название задачи'), 'Из полной формы');
    await tester.tap(find.text('Приватная задача'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    await shot(tester, 'desktop_new_task');
    await tester.tap(find.text('Добавить задачу').last);
    await tester.pumpAndSettle();
    final t = app.repo.tasks.values.firstWhere((x) => x.title == 'Из полной формы');
    expect(t.isPrivate, isTrue);
    expect(t.assigneeId, me);
    expect(app.repo.plannedToday(t), isTrue);

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Настройки'), findsWidgets);
    await shot(tester, 'desktop_settings');
    await tester.tap(find.text('Тёмная'));
    await tester.pumpAndSettle();
    expect(app.repo.setting<String>('theme', ''), 'dark');
    await tester.scrollUntilVisible(find.text('Режим администратора'), 200, scrollable: find.descendant(of: find.byType(Dialog), matching: find.byType(Scrollable)).first);
    expect(find.text('Режим администратора'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close).last);
    await tester.pumpAndSettle();
    await shot(tester, 'desktop_dark');
  });

  testWidgets('плюсик быстрого добавления создаёт задачу с введённым названием', (tester) async {
    await pumpApp(tester, const Size(1280, 800));
    await tester.enterText(find.widgetWithText(TextField, 'Добавить задачу'), 'Через плюсик');
    await tester.tap(find.byTooltip('Добавить задачу'));
    await tester.pumpAndSettle();
    final t = app.repo.tasks.values.firstWhere((x) => x.title == 'Через плюсик');
    expect(app.repo.plannedToday(t), isTrue);
    expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Добавить задачу')).controller!.text, '');
    // с пустым полем плюсик ничего не создаёт
    final n = app.repo.tasks.length;
    await tester.tap(find.byTooltip('Добавить задачу'));
    await tester.pumpAndSettle();
    expect(app.repo.tasks.length, n);
  });

  testWidgets('цвета выбираются палитрой', (tester) async {
    await pumpApp(tester, const Size(1280, 800));
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    for (final (label, key) in [('Акцентный цвет', 'accent'), ('Цвет подложек', 'plate'), ('Цвет окантовок', 'border')]) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('color-field')), findsOneWidget);
      // нажатие в поле палитры и на полосе оттенков меняет цвет
      await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('color-hue'))));
      await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('color-field'))));
      await tester.pumpAndSettle();
      if (label == 'Акцентный цвет') await shot(tester, 'desktop_palette');
      await tester.tap(find.text('Готово'));
      await tester.pumpAndSettle();
      expect(app.repo.setting<String>(key, ''), matches(RegExp(r'^#[0-9A-F]{6}$')), reason: label);
    }
    // «По умолчанию» возвращает исходный цвет
    await tester.tap(find.text('Цвет подложек'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('По умолчанию'));
    await tester.pumpAndSettle();
    expect(app.repo.setting<String>('plate', 'x'), '');
  });

  testWidgets('адрес сервера и ключ доступа видны только администратору', (tester) async {
    await app.repo.setKv('access_key', 'secretkey');
    await app.repo.setKv('pin', 'pinpin');
    await pumpApp(tester, const Size(1280, 800));
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Ключ доступа'), 200, scrollable: find.descendant(of: find.byType(Dialog), matching: find.byType(Scrollable)).first);
    expect(find.text('https://example'), findsWidgets);
    expect(find.text('secretkey.pinpin'), findsWidgets);
    await tester.tap(find.byIcon(Icons.close).last);
    await tester.pumpAndSettle();

    // тот же пользователь без прав администратора
    final u = app.repo.users;
    await app.repo.setUsers([const User(me, 'Аня', hasPassword: true), u.last]);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await tester.drag(find.descendant(of: find.byType(Dialog), matching: find.byType(Scrollable)).first, const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(find.text('Ключ доступа'), findsNothing);
    expect(find.textContaining('secretkey'), findsNothing);
    expect(find.textContaining('https://example'), findsNothing);
  });

  testWidgets('фоновая картинка хранится на устройстве и лежит под колонками', (tester) async {
    final im = img.Image(width: 64, height: 40);
    for (final p in im) {
      p.setRgb(40 + p.x * 3, 90 + p.y * 3, 200 - p.x * 2);
    }
    await app.repo.setLocal('bg_image', base64Encode(img.encodeJpg(im)));
    await app.repo.setLocal('bg_dim', '30');
    await pumpApp(tester, const Size(1280, 800));
    await tester.runAsync(() => precacheImage(MemoryImage(backgroundBytes(app.repo)!), tester.element(find.byType(Scaffold).first)));
    await tester.pumpAndSettle();
    expect(tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor, Colors.transparent);
    expect(app.repo.settingsDirty, isEmpty, reason: 'картинка не уходит на сервер');
    await shot(tester, 'desktop_background');
    await app.repo.setLocal('bg_image', null);
    await tester.pumpAndSettle();
    expect(tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor, isNull);
  });

  testWidgets('исполнитель списка выбирается в окне по центру экрана', (tester) async {
    await pumpApp(tester, const Size(1280, 800));
    await tester.tap(find.text('Создать список'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Название'), 'Покупки');
    await tester.tap(find.text('Без исполнителя'));
    await tester.pumpAndSettle();
    final box = tester.getRect(find.byType(SimpleDialog));
    expect(box.center.dx, closeTo(640, 1));
    expect(box.center.dy, closeTo(400, 1));
    await shot(tester, 'desktop_list_assignee');
    await tester.tap(find.text('Вера').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Создать'));
    await tester.pumpAndSettle();
    expect(app.repo.lists.values.firstWhere((l) => l.name == 'Покупки').s('assignee_id'), other);

    // повторение: единица интервала выбирается переключателем
    await tester.tap(find.text('Сегодняшний день').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Подготовить отчёт'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Повторять'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Каждые N дней, недель или месяцев'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('недель'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Готово'));
    await tester.pumpAndSettle();
    expect(app.repo.tasks.values.firstWhere((t) => t.title == 'Подготовить отчёт').recurrence, {'type': 'interval', 'n': 2, 'unit': 'week'});
  });

  testWidgets('чек-лист: круглые галочки, правка и перестановка пунктов; описание и чек-лист под названием', (tester) async {
    await pumpApp(tester, const Size(1280, 800));
    await tester.tap(find.text('Подготовить отчёт'));
    await tester.pumpAndSettle();
    Ent task() => app.repo.tasks.values.firstWhere((t) => t.title == 'Подготовить отчёт');
    List<String> texts() => [for (final c in task().checklist) '${c['text']}:${c['done']}'];
    expect(find.byType(Checkbox), findsNothing, reason: 'галочки чек-листа круглые');
    // порядок блоков: название, описание, чек-лист, остальное
    final yDesc = tester.getTopLeft(find.text('Собрать цифры за октябрь')).dy;
    final yList = tester.getTopLeft(find.text('графики')).dy;
    final yRest = tester.getTopLeft(find.text('Общая задача')).dy;
    expect(yDesc < yList && yList < yRest, isTrue);
    await shot(tester, 'desktop_checklist');

    // отметка круглой галочкой
    final row = find.ancestor(of: find.text('графики'), matching: find.byType(Row)).first;
    await tester.tap(find.descendant(of: row, matching: find.byType(RoundCheck)));
    await tester.pumpAndSettle();
    expect(texts(), ['выгрузка:true', 'графики:true']);

    // правка текста пункта
    await tester.tap(find.text('выгрузка'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'выгрузка'), 'выгрузка из базы');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(texts(), ['выгрузка из базы:true', 'графики:true']);

    // новый пункт плюсиком и перестановка перетаскиванием
    await tester.enterText(find.widgetWithText(TextField, 'Пункт чек-листа'), 'выводы');
    await tester.tap(find.byTooltip('Добавить пункт'));
    await tester.pumpAndSettle();
    expect(texts().last, 'выводы:false');
    final g = await tester.startGesture(tester.getCenter(find.byIcon(Icons.drag_indicator).last));
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(0, -9));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(texts(), ['выводы:false', 'выгрузка из базы:true', 'графики:true']);

    // стёртый текст удаляет пункт
    await tester.tap(find.text('графики'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'графики'), '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(texts(), ['выводы:false', 'выгрузка из базы:true']);
  });

  testWidgets('раздел «Важные»: задачи со звёздочкой из всех списков, новая задача сразу со звёздочкой', (tester) async {
    final hers = app.repo.lists.values.firstWhere((l) => l.name == 'Вере');
    final t = app.repo.tasks.values.firstWhere((t) => t.title == 'Купить корм коту');
    await app.repo.setTaskField(t, 'is_important', true);
    await pumpApp(tester, const Size(1280, 800));
    await tester.tap(find.text('Важные'));
    await tester.pumpAndSettle();
    expect(find.text('Разобрать почту'), findsOneWidget);
    expect(find.text('Купить корм коту'), findsOneWidget, reason: 'задача из списка «${hers.name}»');
    expect(find.text('Подготовить отчёт'), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, 'Добавить задачу'), 'Срочное');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final n = app.repo.tasks.values.firstWhere((x) => x.title == 'Срочное');
    expect(n.important, isTrue);
    expect(n.listId, '', reason: 'как в разделе «Задачи»');
    expect(n.planned, isFalse);
    expect(find.text('Срочное'), findsOneWidget);
    await shot(tester, 'desktop_important');
    // звёздочку сняли — задача ушла из раздела
    await app.repo.setTaskField(n, 'is_important', false);
    await tester.pumpAndSettle();
    expect(find.text('Срочное'), findsNothing);
    expect(app.repo.tasksOf(secTasks).any((x) => x.id == n.id), isTrue);
  });

  test('виджет: все задачи списка — свои, затем чужие, в конце закрытые; режим «Только свои» не влияет', () async {
    final r = app.repo;
    await r.setSetting('view_mode', 'mine');
    final o = await r.addTask(r.draftTask(title: 'Чужая'));
    await r.setTaskField(o, 'assignee_id', other);
    await r.setDone(r.tasks.values.firstWhere((t) => t.title == 'Разобрать почту'), true);
    final snap = widgetSnapshot(r);
    final lists = [for (final l in snap['lists'] as List) (l as Map)['name']];
    expect(lists, ['Сегодняшний день', 'Важные', 'Планирование', 'Задачи', 'Мои дела', 'Дом', 'Вере'], reason: 'список чужого исполнителя тоже доступен');
    // «Планирование» в виджете — только сегодняшний день, по времени; прежний «planned» показывает то же
    final sched = ((snap['tasks'] as Map)[secSchedule] as List).cast<Map>();
    expect([for (final x in sched) '${x['title']} | ${x['due']}'], ['Оплатить интернет | без времени', 'Подготовить отчёт | 14:00–15:00', 'Разобрать почту | без времени', 'Полить цветы | без времени'], reason: 'закрытые — в конце');
    expect((snap['tasks'] as Map)[secPlanned], sched);
    final rows = ((snap['tasks'] as Map)[secTasks] as List).cast<Map>();
    expect([for (final x in rows) x['title']], ['Личное: врач', 'Подготовить отчёт', 'Собрать данные', 'Чужая', 'Разобрать почту', 'Полить цветы']);
    expect([for (final x in rows) x['done']], [false, false, false, false, true, true]);
    expect(rows[3]['due'], 'Вера', reason: 'у чужой задачи подписан исполнитель');
    expect(rows[2]['sub'], isTrue);
    final hers = r.lists.values.firstWhere((l) => l.name == 'Вере');
    expect([for (final x in (snap['tasks'] as Map)[hers.id] as List) (x as Map)['title']], ['Купить корм коту']);
  });

  testWidgets('виджет: цвета и непрозрачность задаются в настройках на Android и хранятся на устройстве', (tester) async {
    expect(widgetSnapshot(app.repo)['style'], {'alpha': 100}, reason: 'по умолчанию цвета системные');
    app = AppState(app.repo, SyncEngine(app.repo, factory: (_) => _NoNet()), _WithWidget());
    app.section = secToday;
    {
      await pumpApp(tester, const Size(1280, 800));
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      final list = find.descendant(of: find.byType(Dialog), matching: find.byType(Scrollable)).first;
      await tester.scrollUntilVisible(find.text('Виджет'), 120, scrollable: list);
      await tester.pumpAndSettle();
      expect(find.text('Системный'), findsNWidgets(4));
      await tester.tap(find.text('Фон'));
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('color-hue'))));
      await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('color-field'))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Готово'));
      await tester.pumpAndSettle();
      expect(app.repo.kv['w_bg'], matches(RegExp(r'^#[0-9A-F]{6}$')));
      expect(find.text('Системный'), findsNWidgets(3));
      await shot(tester, 'android_widget_settings');
      await tester.tap(find.text('Как в приложении'));
      await tester.pumpAndSettle();
      await app.repo.setLocal('w_alpha', '40');
      await tester.pumpAndSettle();
      expect(widgetSnapshot(app.repo)['style'], {'bg': '#FBF9F1', 'border': '#DAD2B9', 'text': '#2B2A26', 'accent': '#3F6B4A', 'alpha': 40});
      expect(app.repo.settingsDirty, isEmpty, reason: 'оформление виджета не уходит на сервер');
      await tester.tap(find.text('Сбросить'));
      await tester.pumpAndSettle();
      expect(widgetSnapshot(app.repo)['style'], {'alpha': 100});
    }
    // у виджета своя настройка «все / только свои», не зависящая от режима приложения
    List titles() => [for (final x in (widgetSnapshot(app.repo)['tasks'] as Map)[secToday] as List) (x as Map)['title']];
    final o = await app.repo.addTask(app.repo.draftTask(title: 'Чужая', inToday: true));
    await app.repo.setTaskField(o, 'assignee_id', other);
    expect(titles(), contains('Чужая'));
    await tester.tap(find.text('Только свои').last);
    await tester.pumpAndSettle();
    expect(app.repo.kv['w_scope'], 'mine');
    expect(titles(), isNot(contains('Чужая')));
    expect(titles(), contains('Разобрать почту'));
  });

  testWidgets('в чужой задаче без права правки пустой чек-лист не показывается', (tester) async {
    // задачу создала Вера и назначила мне: закрыть могу, править — нет
    final r = app.repo;
    final t = Ent('task', 'foreign-1', creatorId: other, createdAt: now);
    t.f.addAll({'title': 'От Веры', 'assignee_id': me, 'plans': [const PlanItem('f1', '2026-11-10').toJson()]});
    final t2 = Ent('task', 'foreign-2', creatorId: other, createdAt: now);
    t2.f.addAll({
      'title': 'От Веры с пунктами',
      'assignee_id': me,
      'plans': [const PlanItem('f2', '2026-11-10').toJson()],
      'checklist': [
        {'text': 'пункт', 'done': false}
      ]
    });
    await r.mergeServer('task', [t.toJson(), t2.toJson()]);
    await pumpApp(tester, const Size(1280, 800));
    await tester.tap(find.text('От Веры'));
    await tester.pumpAndSettle();
    expect(r.canEdit(r.tasks['foreign-1']!), isFalse);
    expect(find.text('Пункт чек-листа'), findsNothing);
    expect(find.widgetWithText(TextField, 'Описание'), findsNothing, reason: 'пустое описание тоже скрыто');
    expect(find.descendant(of: find.byType(TaskEditor), matching: find.byType(ReorderableListView)), findsNothing, reason: 'пустой блок чек-листа скрыт');
    await shot(tester, 'desktop_foreign_task');
    // с пунктами чек-лист виден, но без правки
    await tester.tap(find.text('От Веры с пунктами'));
    await tester.pumpAndSettle();
    expect(find.text('пункт'), findsOneWidget);
    expect(find.byTooltip('Удалить пункт'), findsNothing);
  });

  testWidgets('порядок списков меняется перетаскиванием и сохраняется в настройках пользователя', (tester) async {
    final r = app.repo;
    await r.createList('Работа', '');
    await pumpApp(tester, const Size(1280, 800));
    List<String> names() => [for (final l in r.visibleLists) l.name];
    expect(names(), ['Дом', 'Вере', 'Работа']);
    // долгое нажатие на список открывает его настройки
    final work = r.lists.values.firstWhere((l) => l.name == 'Работа');
    await tester.longPress(find.text('Работа'));
    await tester.pumpAndSettle();
    expect(find.text('Изменить список'), findsOneWidget);
    expect(find.text('Переместить выше'), findsNothing, reason: 'порядок — только перетаскиванием');
    await tester.tapAt(const Offset(640, 20));
    await tester.pumpAndSettle();
    // перетащить «Работа» за ручку на самый верх
    final g = await tester.startGesture(tester.getCenter(find.byKey(ValueKey('list-handle:${work.id}'))));
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 12; i++) {
      await g.moveBy(const Offset(0, -10));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(names(), ['Работа', 'Дом', 'Вере']);
    expect(r.settingsDirty.contains('list_order'), isTrue, reason: 'порядок уйдёт на сервер вместе с настройками');
    expect(tester.getTopLeft(find.text('Работа')).dy < tester.getTopLeft(find.text('Дом')).dy, isTrue);
    // нажатие по-прежнему открывает список
    await tester.tap(find.text('Работа'));
    await tester.pumpAndSettle();
    expect(app.section, r.lists.values.firstWhere((l) => l.name == 'Работа').id);

    // в режиме «Только свои» скрытый список (чужого исполнителя) остаётся на своём месте
    await r.setSetting('view_mode', 'mine');
    expect(names(), ['Работа', 'Дом']);
    await r.moveList(0, 1);
    expect(names(), ['Дом', 'Работа']);
    await r.setSetting('view_mode', 'all');
    expect(names(), ['Дом', 'Работа', 'Вере']);
    // новый список встаёт в конец
    await r.createList('Новый', '');
    expect(names().last, 'Новый');
  });

  testWidgets('раздел «Мои дела»: приватные задачи из всех списков, новая задача сразу приватная', (tester) async {
    final r = app.repo;
    final home = r.lists.values.firstWhere((l) => l.name == 'Дом');
    await r.addTask(r.draftTask(title: 'Личное в списке', private: true, listId: home.id));
    await pumpApp(tester, const Size(1280, 800));
    await tester.tap(find.text('Мои дела'));
    await tester.pumpAndSettle();
    expect(find.text('Личное: врач'), findsOneWidget);
    expect(find.text('Личное в списке'), findsOneWidget, reason: 'приватная задача из списка «Дом»');
    expect(find.text('Разобрать почту'), findsNothing, reason: 'общие задачи сюда не попадают');
    // замок включён и не переключается
    final lock = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.lock));
    expect(lock.onPressed, isNull);
    await tester.enterText(find.widgetWithText(TextField, 'Добавить задачу'), 'Тайное');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final n = r.tasks.values.firstWhere((x) => x.title == 'Тайное');
    expect(n.isPrivate, isTrue);
    expect(n.assigneeId, me);
    expect(n.listId, '');
    expect(find.text('Тайное'), findsOneWidget);
    await shot(tester, 'desktop_private');
    // в полной форме приватность тоже включена сразу
    await tester.tap(find.byTooltip('Полная форма').first);
    await tester.pumpAndSettle();
    expect(app.draft!.isPrivate, isTrue);
  });

  testWidgets('раздел «Планирование»: перенос, длительность, копирование удержанием, новые пункты', (tester) async {
    final r = app.repo;
    final report = r.tasks.values.firstWhere((t) => t.title == 'Подготовить отчёт');
    String plans(Ent t) => [for (final p in t.plans) p.timed ? '${p.date} ${fmtMin(p.from)}–${fmtMin(p.to)}' : '${p.date} -'].join(', ');
    final haptics = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') haptics.add('${call.arguments}');
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await pumpApp(tester, const Size(1280, 800));
    await tester.tap(find.text('Планирование'));
    await tester.pumpAndSettle();
    expect(find.text('вт, 10'), findsOneWidget);
    expect(find.text('Подготовить отчёт'), findsOneWidget, reason: 'пункт со временем — карточкой на шкале');
    expect(find.text('14:00–15:00'), findsOneWidget);
    await shot(tester, 'desktop_schedule');

    // карточка двигается мышью: на час позже
    await tester.drag(find.text('Подготовить отчёт'), const Offset(0, 52), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(plans(report), '2026-11-10 15:00–16:00');
    // нижний край меняет длительность
    await tester.drag(find.byKey(ValueKey('grow:${report.id}:rep14')), const Offset(0, 26), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(plans(report), '2026-11-10 15:00–16:30');
    // на следующий день — перенос, а не копия
    final colW = tester.getCenter(find.text('ср, 11')).dx - tester.getCenter(find.text('вт, 10')).dx;
    await tester.drag(find.text('Подготовить отчёт'), Offset(colW, 0), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(plans(report), '2026-11-11 15:00–16:30');

    // зажали на секунду — копирование: вибрация и значок «+» у карточки; исходный пункт остаётся
    // длинный пункт (4 часа) при перетаскивании виден целиком
    await r.putPlan(report, report.plans.single.copyWith(to: 19 * 60));
    await tester.pumpAndSettle();
    haptics.clear();
    final g = await tester.startGesture(tester.getCenter(find.text('Подготовить отчёт')), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('move-badge')), findsOneWidget, reason: 'режим перетаскивания отмечен значком');
    expect(tester.getSize(find.ancestor(of: find.byKey(const ValueKey('move-badge')), matching: find.byType(IgnorePointer)).first).height, closeTo(4 * 52, 1));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('copy-badge')), findsOneWidget);
    expect(haptics, ['HapticFeedbackType.selectionClick', 'HapticFeedbackType.mediumImpact'], reason: 'вибрация при начале перетаскивания и при переходе в копирование');
    await shot(tester, 'desktop_schedule_copy');
    for (var i = 0; i < 10; i++) {
      await g.moveBy(Offset(colW / 10, 52 / 10 * 2));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(plans(report), '2026-11-11 15:00–19:00, 2026-11-12 17:00–21:00');
    expect(report.plans.map((p) => p.notify), [true, true], reason: 'уведомление копируется вместе с пунктом');
    expect(report.plans[0].id, isNot(report.plans[1].id));

    // «+»: новая задача сразу на шкале
    await tester.tap(find.byTooltip('Запланировать задачу'));
    await tester.pumpAndSettle();
    // задачи по спискам: «Задачи» (без списка), затем списки по порядку меню; раскрыт один список
    Finder inDialog(String s) => find.descendant(of: find.byType(AlertDialog), matching: find.text(s));
    expect(inDialog('Подготовить отчёт'), findsOneWidget, reason: 'и у запланированной задачи можно добавить ещё пункт');
    expect(inDialog('Оплатить интернет'), findsNothing, reason: 'список «Дом» свёрнут');
    final dy = [for (final s in ['Задачи', 'Дом', 'Вере']) tester.getCenter(inDialog(s)).dy];
    expect(dy[0] < dy[1] && dy[1] < dy[2], isTrue);
    // в списке сначала задачи без пунктов, потом с пунктами (каждые — от старых к новым)
    final names = [for (final e in find.descendant(of: find.byType(AlertDialog), matching: find.byType(ListTile)).evaluate()) ((e.widget as ListTile).title as Text).data];
    expect(names, ['Собрать данные', 'Разобрать почту', 'Подготовить отчёт', 'Личное: врач']);
    await tester.ensureVisible(inDialog('Дом'));
    await tester.pumpAndSettle();
    await tester.tap(inDialog('Дом'));
    await tester.pumpAndSettle();
    expect(inDialog('Оплатить интернет'), findsOneWidget);
    expect(inDialog('Подготовить отчёт'), findsNothing, reason: 'остальные списки свернулись');
    await shot(tester, 'desktop_schedule_add');
    await tester.enterText(find.byKey(const ValueKey('slot-title')), 'Созвон');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Создать'));
    await tester.pumpAndSettle();
    final call = r.tasks.values.firstWhere((t) => t.title == 'Созвон');
    expect(plans(call), '2026-11-10 13:00–14:00', reason: 'по умолчанию — ближайший целый час');

    // существующей задаче добавляется ещё один пункт
    final pay = r.tasks.values.firstWhere((t) => t.title == 'Оплатить интернет');
    final n = pay.plans.length;
    await tester.tap(find.byTooltip('Запланировать задачу'));
    await tester.pumpAndSettle();
    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextField, 'Поиск')), 'интернет');
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Оплатить интернет')));
    await tester.pumpAndSettle();
    expect(pay.plans.length, n + 1);

    // нажатие на карточку открывает задачу; её пункт виден в карточке задачи
    await tester.tap(find.text('Созвон'));
    await tester.pumpAndSettle();
    expect(find.text('Сегодня, 13:00–14:00'), findsOneWidget);
  });

  testWidgets('пункты планирования в карточке задачи: несколько, с уведомлением, без времени', (tester) async {
    await pumpApp(tester, const Size(1280, 800));
    await tester.tap(find.text('Разобрать почту'));
    await tester.pumpAndSettle();
    final t = app.repo.tasks.values.firstWhere((x) => x.title == 'Разобрать почту');
    expect(find.text('Сегодня, без времени'), findsOneWidget);
    await reveal(tester, find.byKey(const ValueKey('plan-add')));
    await tester.tap(find.byKey(const ValueKey('plan-add')));
    await tester.pumpAndSettle();
    expect(tester.getCenter(find.byKey(const ValueKey('plan-date'))).dy, lessThan(tester.getCenter(find.byKey(const ValueKey('plan-from'))).dy), reason: 'день — первой строкой, время — второй');
    await tester.tap(find.byKey(const ValueKey('plan-notify')));
    await tester.pumpAndSettle();
    expect(find.text('За 1 ч'), findsOneWidget, reason: 'по умолчанию — за час');
    await shot(tester, 'desktop_plan_dialog');
    await tester.tap(find.byKey(const ValueKey('plan-ok')));
    await tester.pumpAndSettle();
    expect([for (final p in t.plans) '${p.date} ${p.timed ? fmtMin(p.from) : '-'} ${p.notify} ${p.before}'], ['2026-11-10 - false 60', '2026-11-10 13:00 true 60']);
    expect(find.text('Сегодня, 13:00–14:00'), findsOneWidget);

    // пункт без времени с уведомлением: время уведомления — стандартное
    await tester.tap(find.byKey(const ValueKey('plan-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('plan-untime')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('plan-notify')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan-before')), findsNothing);
    expect(find.textContaining('В 09:00'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('plan-date')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('14'));
    await tester.tap(find.descendant(of: find.byType(DatePickerDialog), matching: find.byType(TextButton)).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('plan-ok')));
    await tester.pumpAndSettle();
    expect(t.plans.last.date, '2026-11-14');
    expect(t.plans.last.timed, isFalse);
    await shot(tester, 'desktop_plan_items');

    // удаление пункта из окна
    await tester.tap(find.text('Сегодня, без времени'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить'));
    await tester.pumpAndSettle();
    expect(t.plans, hasLength(2));
    expect(find.text('Добавить в «Сегодня»'), findsNothing, reason: 'на сегодня есть пункт со временем');
    // убрали и его — появилась кнопка «Добавить в „Сегодня“»
    await tester.tap(find.byTooltip('Убрать пункт').first);
    await tester.pumpAndSettle();
    expect(find.text('Добавить в «Сегодня»'), findsOneWidget);
    await tester.tap(find.text('Добавить в «Сегодня»'));
    await tester.pumpAndSettle();
    expect(app.repo.plannedToday(t), isTrue);
  });

  testWidgets('телефон: колонки открываются по очереди', (tester) async {
    await pumpApp(tester, const Size(390, 800));
    expect(find.text('Разобрать почту'), findsOneWidget);
    expect(find.text('Создать список'), findsNothing);
    await shot(tester, 'phone_list');
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(find.text('Создать список'), findsOneWidget);
    await shot(tester, 'phone_menu');
    await tester.tap(find.text('Задачи'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Подготовить отчёт'));
    await tester.pumpAndSettle();
    expect(find.text('Задача'), findsOneWidget);
    expect(find.text('Создать список'), findsNothing);
    await shot(tester, 'phone_task');
  });

  testWidgets('без пользователя показывается экран входа с «Использовать локально»', (tester) async {
    await app.repo.setKv('user_id', null);
    await app.repo.setKv('server_url', null);
    await app.repo.setKv('access_key', null);
    await pumpApp(tester, const Size(390, 800));
    expect(find.text('Адрес сервера'), findsOneWidget);
    expect(find.text('Ключ доступа'), findsOneWidget);
    expect(find.text('Использовать локально'), findsOneWidget);
    await shot(tester, 'phone_login');
  });

  testWidgets('масштаб интерфейса: хранится на устройстве и уменьшает всё', (tester) async {
    await app.repo.setKv('user_id', null);
    await app.repo.setKv('server_url', null);
    await app.repo.setKv('access_key', null);
    await pumpApp(tester, const Size(390, 800));
    double width(String t) => tester.getBottomRight(find.text(t)).dx - tester.getTopLeft(find.text(t)).dx; // на экране, с учётом масштаба
    final before = width('Ключ доступа');
    await tester.tap(find.byTooltip('Мельче'));
    await tester.pumpAndSettle();
    expect(app.repo.kv['ui_scale'], '95');
    await tester.tap(find.byTooltip('Мельче'));
    await tester.pumpAndSettle();
    expect(app.repo.kv['ui_scale'], '90');
    expect(app.repo.settingsDirty.contains('ui_scale'), isFalse); // на сервер не уходит
    expect(width('Ключ доступа'), closeTo(before * 0.9, 1));
    await shot(tester, 'phone_login_90');
    // нажатия в масштабе попадают куда надо: сброс к 100 %
    await tester.tap(find.text('90 %'));
    await tester.pumpAndSettle();
    expect(app.repo.kv['ui_scale'], isNull);
  });

  testWidgets('локальный режим: без сервера, без совместных функций; подключение к серверу из настроек', (tester) async {
    await app.repo.resetForUser('', '');
    await app.repo.setKv('user_id', null);
    await pumpApp(tester, const Size(1280, 800));
    await tester.tap(find.text('Использовать локально'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Работать локально'));
    await tester.pumpAndSettle();
    expect(app.repo.isLocal, isTrue);
    expect(find.text('Сегодняшний день'), findsWidgets, reason: 'сразу главный экран, без входа');
    for (final s in ['Только свои', 'Мои дела']) {
      expect(find.text(s), findsNothing, reason: '$s — для совместной работы');
    }
    expect(find.byTooltip('Общая задача'), findsNothing, reason: 'замок приватности не нужен');
    await tester.enterText(find.widgetWithText(TextField, 'Добавить задачу'), 'Своя задача');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Своя задача'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Исполнитель'), findsNothing);
    expect(find.text('Общая задача'), findsNothing);
    await shot(tester, 'desktop_local');

    // настройки: вместо пользователя — «Без сервера» и подключение; разделов администратора нет
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Подключиться к серверу'), findsOneWidget);
    expect(find.text('Сменить'), findsNothing);
    await tester.drag(find.descendant(of: find.byType(Dialog), matching: find.byType(Scrollable)).first, const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(find.text('Режим администратора'), findsNothing);
    await tester.drag(find.descendant(of: find.byType(Dialog), matching: find.byType(Scrollable)).first, const Offset(0, 3000));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Подключиться к серверу'));
    await tester.pumpAndSettle();
    expect(find.text('Подключение к серверу'), findsOneWidget);
    expect(find.text('Использовать локально'), findsNothing);
    expect(find.textContaining('переедут на сервер'), findsOneWidget);
  });

  testWidgets('новый сервер: первый пользователь создаётся администратором', (tester) async {
    final calls = <String>[];
    await app.repo.resetForUser('', '');
    await app.repo.setKv('user_id', null);
    await app.repo.setKv('server_url', null);
    await app.repo.setKv('access_key', null);
    app = AppState(
        app.repo,
        SyncEngine(app.repo,
            factory: (_) => _Fake({
                  'GET /v1/hello': {'time': now, 'users': [], 'setup': true},
                  'POST /v1/setup': {'ok': true, 'token': 'tok', 'user_id': 'new-admin-id'},
                }, calls)),
        NoopPlatform());
    await pumpApp(tester, const Size(390, 800));
    await tester.enterText(find.byKey(const ValueKey('server-url')), '203.0.113.5:8443');
    await tester.enterText(find.byKey(const ValueKey('access-key')), 'k.pin');
    await tester.tap(find.text('Подключиться'));
    await tester.pumpAndSettle();
    expect(find.text('Создать администратора'), findsOneWidget);
    await shot(tester, 'phone_setup');
    await tester.enterText(find.byKey(const ValueKey('setup-name')), 'Аня');
    await tester.enterText(find.byKey(const ValueKey('setup-pw')), '1234');
    await tester.enterText(find.byKey(const ValueKey('setup-pw2')), '12345');
    await tester.tap(find.text('Создать администратора'));
    await tester.pumpAndSettle();
    expect(find.text('Пароли не совпадают'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('setup-pw2')), '1234');
    await tester.tap(find.text('Создать администратора'));
    await tester.pumpAndSettle();
    expect(app.repo.serverUrl, 'https://203.0.113.5:8443');
    expect((app.repo.accessKey, app.repo.pin), ('k', 'pin'));
    expect(calls, contains('POST /v1/setup {"name":"Аня","password":"1234","device":"device"}'));
    expect(app.repo.me, 'new-admin-id');
    expect(app.repo.token, 'tok');
  });

  testWidgets('администратор управляет пользователями из настроек', (tester) async {
    final calls = <String>[];
    app = AppState(
        app.repo,
        SyncEngine(app.repo,
            factory: (_) => _Fake({
                  'POST /v1/admin/users': {'ok': true},
                  'PATCH /v1/admin/users/$other': {'ok': true},
                  'DELETE /v1/admin/users/$other': {'ok': true},
                }, calls)),
        NoopPlatform());
    await pumpApp(tester, const Size(1280, 800));
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Пользователи'));
    await tester.pumpAndSettle();
    expect(find.textContaining('это вы'), findsOneWidget, reason: 'себя видно, но удалить нельзя');
    expect(find.byTooltip('Удалить'), findsOneWidget);
    await shot(tester, 'desktop_users');

    await tester.tap(find.text('Добавить'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('user-name')), 'Петя');
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Добавить').last);
    await tester.pumpAndSettle();
    expect(find.text('У администратора должен быть пароль'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('user-pw')), 'petya');
    await tester.tap(find.text('Добавить').last);
    await tester.pumpAndSettle();
    expect(calls, contains('POST /v1/admin/users {"name":"Петя","password":"petya","is_admin":true}'));

    // правка Веры: новое имя и пароль
    await tester.tap(find.byTooltip('Изменить').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('user-name')), 'Вера П.');
    await tester.enterText(find.byKey(const ValueKey('user-pw')), 'vera1');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(calls, contains('PATCH /v1/admin/users/$other {"name":"Вера П.","password":"vera1"}'));

    await tester.tap(find.byTooltip('Удалить'));
    await tester.pumpAndSettle();
    expect(find.textContaining('перейдут к администратору'), findsOneWidget);
    await tester.tap(find.text('Удалить').last);
    await tester.pumpAndSettle();
    expect(calls, contains('DELETE /v1/admin/users/$other'));
  });

  testWidgets('обычный пользователь не видит управления пользователями', (tester) async {
    await app.repo.setUsers(const [User(me, 'Аня', hasPassword: true), User(other, 'Вера')]);
    await pumpApp(tester, const Size(1280, 800));
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Пользователи'), findsNothing);
    expect(find.text('Пароль'), findsOneWidget);
  });
}
