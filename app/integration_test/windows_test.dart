// Сквозная проверка Windows-приложения на настоящем окне и настоящих плагинах:
//   $env:TODO_DATA_DIR = "<временная папка>"; $env:TODO_TEST_BIN = "<...>\test\bin\todod.exe"
//   flutter test integration_test/windows_test.dart -d windows
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:todo_app/main.dart' as entry;
import 'package:todo_app/platform/platform_io.dart';
import 'package:todo_app/ui/common.dart';
import 'package:window_manager/legacy.dart';

import '../test/support.dart';

Future<void> waitFor(WidgetTester tester, bool Function() cond, String what) async {
  for (var i = 0; i < 150; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (cond()) return;
  }
  fail('не дождались: $what');
}

Future<void> waitText(WidgetTester tester, String text) => waitFor(tester, () => find.text(text).evaluate().isNotEmpty, 'текст «$text»');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows: вход, синхронизация, трей, уведомление с опозданием', (tester) async {
    expect(Platform.environment['TODO_DATA_DIR'], isNotNull, reason: 'тест должен работать в отдельном каталоге данных');
    final dir = Directory.systemTemp.createTempSync('todo-win-');
    final s = await TestServer.withUsers(dir, 18600);
    addTearDown(() => s.proc.kill());

    await entry.main([]);
    // первый запуск: адрес сервера и ключ доступа, затем выбор пользователя
    await waitText(tester, 'Адрес сервера');
    await tester.enterText(find.widgetWithText(TextField, 'Адрес сервера'), s.url);
    await tester.enterText(find.widgetWithText(TextField, 'Ключ доступа'), '${s.accessKey}.${s.pin}');
    await tester.tap(find.text('Подключиться'));
    await waitText(tester, 'Боб');
    await tester.tap(find.text('Боб'));
    await waitText(tester, 'Сегодняшний день');
    expect(app.repo.me, uB);
    expect(app.repo.token, isNotEmpty);
    expect(await windowManager.isVisible(), isTrue);

    // задача уходит на сервер
    await tester.enterText(find.widgetWithText(TextField, 'Добавить задачу'), 'Задача с ПК');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await waitText(tester, 'Задача с ПК');
    await waitFor(tester, () => app.repo.dirtyTasks.isEmpty, 'отправка задачи на сервер');
    final all = await s.admin('GET', '/v1/changes?cursor=0');
    expect([for (final t in all.json['tasks'] as List) (t as Map)['f']['title']], contains('Задача с ПК'));

    // с другого устройства приходит задача, время напоминания которой уже прошло: уведомление сразу
    final now = DateTime.now().millisecondsSinceEpoch;
    final clara = (await s.send('POST', '/v1/login', body: {'user_id': uC, 'password': '', 'device': 'test'})).json['token'] as String;
    final r = await s.send('POST', '/v1/changes', token: clara, body: {
      'now': now,
      'tasks': [
        {
          'id': 'dddddddd-0000-4000-8000-00000000000a',
          'creator_id': uC,
          'is_private': false,
          'created_at': now - 1000,
          'f': {'title': 'Позвонить в сервис', 'assignee_id': uB, 'reminder_at': now - 120000},
          't': {'title': now - 1000, 'assignee_id': now - 1000, 'reminder_at': now - 1000},
          'd': ['title', 'assignee_id', 'reminder_at'],
        }
      ]
    });
    expect(r.ok, isTrue, reason: r.error);
    // устройство вошло час назад и всё это время было без связи
    await app.repo.setKv('notify_from', '${now - 3600000}');
    final win = app.platform as WindowsPlatform;
    debugPrint('toast support: ${win.toastsReady}');
    final before = win.shownToasts;
    expect(await app.sync.sync(), isTrue, reason: app.sync.lastError);
    await waitFor(tester, () => win.shownToasts == before + 1, 'системное уведомление');
    await tester.pump(const Duration(seconds: 1));
    await app.sync.sync();
    expect(win.shownToasts, before + 1, reason: 'уведомление показывается один раз');

    // крестик сворачивает в трей: окно скрыто, синхронизация становится редкой
    await windowManager.close();
    await waitFor(tester, () => !app.active, 'сворачивание в трей');
    expect(await windowManager.isVisible(), isFalse);
    // щелчок по значку в трее возвращает окно
    win.onTrayIconMouseDown();
    await waitFor(tester, () => app.active, 'возврат из трея');
    expect(await windowManager.isVisible(), isTrue);
  });
}
