// Windows: трей, автозапуск, toast-уведомления. Android: точные будильники, WorkManager, виджет.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:home_widget/home_widget.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:tray_manager/legacy.dart';
import 'package:window_manager/legacy.dart';
import 'package:workmanager/workmanager.dart';

import '../app.dart';
import '../core/model.dart';
import '../core/reminders.dart';
import '../core/repo.dart';
import '../core/storage.dart';
import '../core/sync.dart';
import '../core/timezones.dart';
import 'platform.dart';
import 'platform_stub.dart';
import 'window_bar.dart';

PlatformHooks createPlatform() {
  if (Platform.isWindows) return WindowsPlatform();
  if (Platform.isAndroid) return AndroidPlatform();
  return NoopPlatform();
}

final _notifications = FlutterLocalNotificationsPlugin();

/// Несколько строк (общее утреннее уведомление) показываются целиком.
NotificationDetails _androidDetails(String body) => NotificationDetails(
  android: AndroidNotificationDetails(
    'reminders',
    'Напоминания',
    channelDescription: 'Напоминания о задачах',
    importance: Importance.max,
    priority: Priority.high,
    category: AndroidNotificationCategory.reminder,
    // в строке уведомлений — белая галочка, в самом уведомлении она окрашена в цвет приложения
    icon: 'ic_stat_check',
    color: const Color(0xFF3F6B4A),
    styleInformation: body.contains('\n') ? BigTextStyleInformation(body) : null,
  ),
);
// ============================================================ Windows

// проверочный запуск с отдельным каталогом данных не мешает работающему приложению
final _instancePort = Platform.environment['TODO_DATA_DIR'] == null ? 47611 : 47612;
const _aumid = 'todo.app';
const _protocol = 'todo-app';

class WindowsPlatform with TrayListener, WindowListener implements PlatformHooks {
  late AppState _app;
  bool _startHidden = false;

  /// Сколько системных уведомлений показано с момента запуска (для диагностики и тестов).
  int shownToasts = 0;
  bool _toasts = false;
  bool get toastsReady => _toasts;
  String _pendingLink = ''; // ссылка из уведомления, с которой запущено приложение
  ServerSocket? _instanceLock;
  Timer? _ticker;

  @override
  String get deviceName => 'ПК ${Platform.localHostname}';
  @override
  Duration? get backgroundPeriod => const Duration(minutes: 5); // в трее — редкая синхронизация
  @override
  bool get managesActivity => true;
  @override
  bool get hasHomeWidget => false;
  @override
  Widget? titleBar() => const WindowBar();

  /// Один экземпляр на пользователя: повторный запуск просто показывает уже работающее окно.
  @override
  Future<bool> preflight(List<String> args) async {
    _startHidden = args.contains('--autostart');
    // нажатие на уведомление запускает приложение со ссылкой вида todo-app:task/<id>
    final link = args.firstWhere((a) => a.startsWith('$_protocol:'), orElse: () => '');
    try {
      _instanceLock = await ServerSocket.bind(InternetAddress.loopbackIPv4, _instancePort);
      _instanceLock!.listen((s) async {
        final text = await utf8.decoder.bind(s).join().timeout(const Duration(seconds: 2), onTimeout: () => '');
        s.destroy();
        await _showWindow();
        _openLink(text);
      });
      _pendingLink = link;
    } catch (_) {
      // приложение уже работает: передаём ему ссылку и выходим
      try {
        final s = await Socket.connect(InternetAddress.loopbackIPv4, _instancePort, timeout: const Duration(seconds: 2));
        s.write(link);
        await s.flush();
        await s.close();
      } catch (_) {}
      return false;
    }
    await windowManager.ensureInitialized();
    return true;
  }

  @override
  Future<void> init(AppState app) async {
    _app = app;
    const options = WindowOptions(size: Size(1180, 760), minimumSize: Size(380, 520), center: true, title: 'Задачи', titleBarStyle: TitleBarStyle.hidden);
    unawaited(
      windowManager.waitUntilReadyToShow(options, () async {
        await windowManager.setPreventClose(true); // крестик сворачивает в трей
        if (_startHidden) {
          app.setActive(false);
        } else {
          await windowManager.show();
          await windowManager.focus();
        }
      }),
    );
    windowManager.addListener(this);

    await trayManager.setIcon('assets/tray.ico');
    await trayManager.setToolTip('Задачи');
    trayManager.addListener(this);
    launchAtStartup.setup(appName: 'Задачи', appPath: Platform.resolvedExecutable, args: ['--autostart']);
    if (app.repo.kv['autostart_set'] != '1' && Platform.environment['TODO_DATA_DIR'] == null) {
      // стартует вместе с системой; отключается в меню значка в трее
      await launchAtStartup.enable();
      await app.repo.setKv('autostart_set', '1');
    }
    await _buildMenu();

    _toasts = await _registerToastIdentity();
    if (_pendingLink.isNotEmpty) _openLink(_pendingLink);
    // напоминания проверяются по таймеру: окно в трее ничего не рисует
    _ticker = Timer.periodic(const Duration(seconds: 20), (_) => refresh(app.repo));
  }

  void _openLink(String link) {
    final m = RegExp('^$_protocol:/*task/([A-Za-z0-9-]+)').firstMatch(link.trim());
    if (m != null) _app.revealTask(m.group(1)!);
  }

  static Future<bool> _reg(List<String> args) async => (await Process.run('reg', args)).exitCode == 0;

  /// Регистрация приложения для системных уведомлений (в реестре текущего пользователя):
  /// имя и значок отправителя toast-уведомлений и обработчик ссылки, по которой открывается задача.
  Future<bool> _registerToastIdentity() async {
    try {
      final exe = Platform.resolvedExecutable;
      final icon = '${File(exe).parent.path}\\data\\flutter_assets\\assets\\icon.png';
      const id = 'HKCU\\Software\\Classes\\AppUserModelId\\$_aumid';
      const proto = 'HKCU\\Software\\Classes\\$_protocol';
      return await _reg(['add', id, '/v', 'DisplayName', '/t', 'REG_SZ', '/d', 'Задачи', '/f']) &&
          await _reg(['add', id, '/v', 'IconUri', '/t', 'REG_SZ', '/d', icon, '/f']) &&
          await _reg(['add', proto, '/ve', '/t', 'REG_SZ', '/d', 'URL:Задачи', '/f']) &&
          await _reg(['add', proto, '/v', 'URL Protocol', '/t', 'REG_SZ', '/d', '', '/f']) &&
          await _reg(['add', '$proto\\shell\\open\\command', '/ve', '/t', 'REG_SZ', '/d', '"$exe" "%1"', '/f']);
    } catch (e) {
      debugPrint('регистрация уведомлений: $e');
      return false;
    }
  }

  /// Системное toast-уведомление Windows. Нажатие открывает задачу в приложении.
  Future<bool> _toast(String title, String body, String taskId) async {
    const esc = HtmlEscape(HtmlEscapeMode.attribute);
    final xml =
        '<toast activationType="protocol" launch="$_protocol:task/${esc.convert(taskId)}">'
        '<visual><binding template="ToastGeneric"><text>${esc.convert(title)}</text><text>${esc.convert(body)}</text></binding></visual></toast>';
    const script = r'''
$ErrorActionPreference = 'Stop'
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
$doc = New-Object Windows.Data.Xml.Dom.XmlDocument
$doc.LoadXml($env:TODO_TOAST_XML)
$toast = New-Object Windows.UI.Notifications.ToastNotification $doc
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($env:TODO_TOAST_APP).Show($toast)
''';
    try {
      final r = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
        environment: {'TODO_TOAST_XML': xml, 'TODO_TOAST_APP': _aumid},
      ).timeout(const Duration(seconds: 20));
      if (r.exitCode != 0) debugPrint('уведомление не показано: ${r.stderr}');
      return r.exitCode == 0;
    } catch (e) {
      debugPrint('уведомление не показано: $e');
      return false;
    }
  }

  Future<void> _buildMenu() async {
    final auto = await launchAtStartup.isEnabled();
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'open', label: 'Открыть'),
          MenuItem(key: 'sync', label: 'Синхронизировать'),
          MenuItem.checkbox(key: 'autostart', label: 'Запускать вместе с Windows', checked: auto),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: 'Выход'),
        ],
      ),
    );
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
    if (!_app.active) {
      _app.setActive(true);
      unawaited(_app.sync.sync());
    }
  }

  @override
  void onWindowClose() async {
    await windowManager.hide();
    _app.setActive(false);
  }

  @override
  void onTrayIconMouseDown() => _showWindow();
  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'open':
        await _showWindow();
      case 'sync':
        await _app.sync.sync();
      case 'autostart':
        if (await launchAtStartup.isEnabled()) {
          await launchAtStartup.disable();
        } else {
          await launchAtStartup.enable();
        }
        await _buildMenu();
      case 'quit':
        await _quit();
    }
  }

  /// «Выход» в трее завершает процесс целиком. Одного закрытия окна мало: движок Flutter,
  /// таймеры и запросы синхронизации держали процесс живым в фоне.
  Future<void> _quit() async {
    _ticker?.cancel();
    Future<void> step(Future<void> Function() f) async {
      try {
        await f().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }

    await step(() => trayManager.destroy());
    await step(() async => _app.repo.st.close());
    await step(() async => _instanceLock?.close());
    await step(() => windowManager.setPreventClose(false));
    await step(() => windowManager.hide());
    exit(0);
  }

  bool _busy = false;

  @override
  Future<void> refresh(Repo repo) async {
    if (_busy || !repo.loggedIn) return;
    _busy = true;
    try {
      final plan = await processReminders(repo, canSchedule: false);
      for (final r in plan.showNow) {
        if (_toasts && await _toast(r.title.isEmpty ? 'Задача' : r.title, r.body, r.taskId)) shownToasts++;
      }
    } catch (e) {
      debugPrint('напоминания: $e');
    } finally {
      _busy = false;
    }
  }
}

// ============================================================ Android

const _widgetProvider = 'todo.app.TodoWidgetProvider';

class AndroidPlatform implements PlatformHooks {
  late AppState _app;

  @override
  String get deviceName => 'Android';
  @override
  Duration? get backgroundPeriod => null; // в фоне синхронизирует WorkManager
  @override
  bool get managesActivity => false;
  @override
  bool get hasHomeWidget => true;
  @override
  Widget? titleBar() => null;
  @override
  Future<bool> preflight(List<String> args) async => true;

  @override
  Future<void> init(AppState app) async {
    _app = app;
    await _initNotifications(onTap: (id) => _app.revealTask(id));
    final launch = await _notifications.getNotificationAppLaunchDetails();
    final fromNotification = launch?.didNotificationLaunchApp == true ? launch?.notificationResponse?.payload : null;

    // фоновая синхронизация примерно раз в 15 минут
    await Workmanager().initialize(backgroundDispatcher);
    await Workmanager().registerPeriodicTask(
      'todo-sync',
      'sync',
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );

    // виджет: отметка выполнения идёт через фоновый обработчик, нажатия открывают приложение
    await HomeWidget.registerInteractivityCallback(widgetBackgroundCallback);
    HomeWidget.widgetClicked.listen(_onLink);
    final initial = await HomeWidget.initiallyLaunchedFromHomeWidget();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (fromNotification != null && fromNotification.isNotEmpty) _app.revealTask(fromNotification);
      _onLink(initial);
      if (app.repo.loggedIn) _askPermissions();
    });
    app.repo.addListener(_permissionsAfterLogin);
  }

  bool _asked = false;
  void _permissionsAfterLogin() {
    if (_app.repo.loggedIn) _askPermissions();
  }

  /// Разрешения на уведомления и точные будильники — один раз, после входа.
  Future<void> _askPermissions() async {
    if (_asked) return;
    _asked = true;
    _app.repo.removeListener(_permissionsAfterLogin);
    final android = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    if (await android?.canScheduleExactNotifications() == false) await android?.requestExactAlarmsPermission();
    await refresh(_app.repo);
  }

  void _onLink(Uri? uri) {
    if (uri == null) return;
    switch (uri.host) {
      case 'task':
        _app.revealTask(uri.queryParameters['id'] ?? '');
      case 'list':
        final id = uri.queryParameters['id'] ?? secToday;
        if (isBuiltinSection(id) || _app.repo.lists.containsKey(id)) _app.openSection(id);
      case 'new':
        // полная форма добавления: список выбирается в форме
        _app.startDraft(_app.repo.draftTask());
    }
  }

  @override
  Future<void> refresh(Repo repo) => refreshAndroid(repo);
}

Future<void> _initNotifications({void Function(String taskId)? onTap}) async {
  await _notifications.initialize(
    settings: const InitializationSettings(android: AndroidInitializationSettings('ic_stat_check')),
    onDidReceiveNotificationResponse: (r) {
      if ((r.payload ?? '').isNotEmpty) onTap?.call(r.payload!);
    },
  );
}

bool _refreshing = false;

/// Пересчитать напоминания (точные будильники) и обновить данные виджета.
Future<void> refreshAndroid(Repo repo) async {
  if (_refreshing || !repo.loggedIn) return;
  _refreshing = true;
  try {
    final android = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    final exact = await android?.canScheduleExactNotifications() ?? false;
    final plan = await processReminders(repo, canSchedule: true);
    for (final id in plan.cancel) {
      await _notifications.cancel(id: id);
    }
    for (final r in plan.showNow) {
      // задача пришла уже после времени напоминания — показываем сразу
      await _notifications.show(id: r.nid, title: r.title.isEmpty ? 'Задача' : r.title, body: r.body, payload: r.taskId, notificationDetails: _androidDetails(r.body));
    }
    for (final r in plan.schedule) {
      await _notifications.zonedSchedule(
        id: r.nid,
        title: r.title.isEmpty ? 'Задача' : r.title,
        body: r.body,
        payload: r.taskId,
        scheduledDate: tz.TZDateTime.fromMillisecondsSinceEpoch(tz.UTC, r.at),
        notificationDetails: _androidDetails(r.body),
        androidScheduleMode: exact ? AndroidScheduleMode.exactAllowWhileIdle : AndroidScheduleMode.inexactAllowWhileIdle,
      );
    }
    await HomeWidget.saveWidgetData<String>('snapshot', jsonEncode(widgetSnapshot(repo)));
    await HomeWidget.updateWidget(qualifiedAndroidName: _widgetProvider);
  } catch (e) {
    debugPrint('refreshAndroid: $e');
  } finally {
    _refreshing = false;
  }
}

/// Данные для виджета: разделы и списки с открытыми задачами (читает нативный код на Kotlin).
Map<String, dynamic> widgetSnapshot(Repo r) {
  final today = r.today;
  final mineOnly = widgetMineOnly(r);
  Map<String, dynamic> row(Ent t, {bool sub = false}) => {
    'id': t.id,
    'title': t.title,
    'sub': sub,
    'private': t.isPrivate,
    'important': t.important,
    'done': t.done,
    'can': r.canToggle(t) && (t.done || r.closeBlocker(t) == null),
    // вторая строка: ближайший пункт планирования и, для чужих задач, исполнитель
    'due': [
      if (r.nextPlan(t) case final p?) p.timed ? '${humanDate(p.date, today)}, ${fmtMin(p.from)}' : humanDate(p.date, today),
      if (!t.isPrivate && t.assigneeId != r.me) r.userName(t.assigneeId),
    ].join(' · '),
    'overdue': r.overdue(t),
  };

  /// «Планирование» в виджете — только сегодняшний день: задачи по времени их пунктов
  /// (сначала без времени), во второй строке — время сегодняшних пунктов.
  List<Map<String, dynamic>> schedule() {
    final all = r.tasksOf(secSchedule, allUsers: true).where((t) => !mineOnly || t.assigneeId == r.me);
    final items = <(Ent, List<PlanItem>)>[
      for (final t in all)
        if (t.plans.where((p) => p.date == today).toList() case final ps when ps.isNotEmpty) (t, ps)
    ]..sort((a, b) {
        if (a.$1.done != b.$1.done) return a.$1.done ? 1 : -1;
        final c = a.$2.first.from.compareTo(b.$2.first.from);
        return c != 0 ? c : a.$1.createdAt.compareTo(b.$1.createdAt);
      });
    return [
      for (final (t, ps) in items.take(100))
        {
          ...row(t),
          'due': [
            ps.map((p) => p.timed ? '${fmtMin(p.from)}–${fmtMin(p.to)}' : 'без времени').join(', '),
            if (!t.isPrivate && t.assigneeId != r.me) r.userName(t.assigneeId),
          ].join(' · '),
        }
    ];
  }

  List<Map<String, dynamic>> rows(String section) {
    if (section == secSchedule) return schedule();
    // задачи раздела независимо от режима «Только свои» в приложении (у виджета своя настройка):
    // сначала те, где пользователь исполнитель, затем чужие, в конце закрытые
    final all = r.tasksOf(section, allUsers: true);
    final ids = {for (final t in all) t.id};
    final top = all.where((t) => (t.parentId.isEmpty || !ids.contains(t.parentId)) && (!mineOnly || t.assigneeId == r.me)).toList();
    final done = top.where((t) => t.done).toList()..sort((a, b) => b.completedAt.compareTo(a.completedAt));
    final out = <Map<String, dynamic>>[];
    for (final t in [...top.where((t) => !t.done && t.assigneeId == r.me), ...top.where((t) => !t.done && t.assigneeId != r.me)]) {
      if (out.length >= 80) break;
      out.add(row(t));
      for (final c in r.children(t.id).where((c) => !c.done)) {
        out.add(row(c, sub: true));
      }
    }
    out.addAll(done.take(20).map(row));
    return out;
  }

  final sections = <Map<String, dynamic>>[
    {'id': secToday, 'name': 'Сегодняшний день'},
    {'id': secImportant, 'name': 'Важные'},
    {'id': secSchedule, 'name': 'Планирование'},
    {'id': secTasks, 'name': 'Задачи'},
    {'id': secPrivate, 'name': 'Мои дела'},
    for (final l in r.allLists) {'id': l.id, 'name': l.name},
  ];
  final tasks = {for (final s in sections) s['id'] as String: rows(s['id'] as String)};
  return {
    'lists': sections,
    // виджет, настроенный на прежний раздел «Запланировано», показывает «Планирование»
    'tasks': {...tasks, secPlanned: tasks[secSchedule]},
    'style': widgetStyle(r),
  };
}

/// Оформление виджета: только заданные пользователем цвета (остальные берутся из палитры системы).
Map<String, dynamic> widgetStyle(Repo r) => {
  for (final k in widgetColorKeys)
    if (RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(r.kv[k] ?? '')) k.substring(2): r.kv[k],
  'alpha': widgetAlpha(r),
};

Future<Repo> _backgroundRepo() async {
  await initTimeZones();
  final repo = Repo(openPlatformStorage());
  await repo.load();
  return repo;
}

/// Фоновая синхронизация (WorkManager): отдельный изолят без интерфейса.
@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, input) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      final repo = await _backgroundRepo();
      if (!repo.loggedIn) return true;
      await _initNotifications();
      final sync = SyncEngine(repo);
      await sync.sync();
      await refreshAndroid(repo);
      sync.dispose();
      await repo.st.close();
    } catch (e) {
      debugPrint('фоновая синхронизация: $e');
    }
    return true;
  });
}

/// Нажатие на галочку в виджете: задача отмечается выполненной без открытия приложения.
@pragma('vm:entry-point')
Future<void> widgetBackgroundCallback(Uri? uri) async {
  if (uri == null || uri.host != 'toggle') return;
  try {
    WidgetsFlutterBinding.ensureInitialized();
    final repo = await _backgroundRepo();
    final t = repo.tasks[uri.queryParameters['id']];
    // галочка в виджете закрывает открытую задачу и возвращает закрытую
    if (t != null && repo.canToggle(t) && (t.done || repo.closeBlocker(t) == null)) {
      await repo.setDone(t, !t.done);
    }
    await _initNotifications();
    await refreshAndroid(repo);
    final sync = SyncEngine(repo);
    await sync.sync();
    await refreshAndroid(repo);
    sync.dispose();
    await repo.st.close();
  } catch (e) {
    debugPrint('виджет: $e');
  }
}
