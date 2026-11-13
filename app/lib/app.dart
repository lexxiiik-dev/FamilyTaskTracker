// Состояние интерфейса и расписание синхронизации.
import 'dart:async';

import 'package:flutter/widgets.dart';

import 'core/model.dart';
import 'core/repo.dart';
import 'core/sync.dart';
import 'platform/platform.dart';

class AppState extends ChangeNotifier with WidgetsBindingObserver {
  final Repo repo;
  final SyncEngine sync;
  final PlatformHooks platform;
  AppState(this.repo, this.sync, this.platform);

  String section = secToday;
  String? taskId; // открытая карточка задачи
  Ent? draft; // полная форма новой задачи
  String query = '';
  bool _active = true;
  Timer? _timer;

  Future<void> start() async {
    section = _validSection(repo.homeSection);
    repo.onLocalChange = () {
      sync.schedule();
      unawaited(platform.refresh(repo));
    };
    sync.afterSync = () async {
      if (repo.loggedIn) await repo.dailyMaintenance(); // новый день: незакрытые задачи переходят на сегодня
      await platform.refresh(repo);
    };
    WidgetsBinding.instance.addObserver(this);
    await platform.init(this);
    setActive(true);
    unawaited(sync.sync());
  }

  String _validSection(String s) {
    if (s == secPrivate && repo.isLocal) return secToday; // «Мои дела» — для совместной работы
    if (isBuiltinSection(s)) return s;
    final l = repo.lists[s];
    return (l != null && !l.deleted) ? s : secToday; // выбранный список удалён — снова «Сегодняшний день»
  }

  /// Активное окно синхронизируется раз в 45 с; свёрнутое в трей на Windows — раз в 5 минут.
  /// На Android в фоне работает WorkManager, таймер там не нужен.
  void setActive(bool active) {
    _active = active;
    _timer?.cancel();
    final period = active ? const Duration(seconds: 45) : platform.backgroundPeriod;
    if (period != null) {
      _timer = Timer.periodic(period, (_) => sync.sync());
    }
  }

  bool get active => _active;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (platform.managesActivity) return; // Windows: активностью управляет трей
    if (state == AppLifecycleState.resumed) {
      setActive(true);
      // базу могли изменить фоновая синхронизация или виджет
      repo.reload().then((_) => sync.sync());
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      setActive(false);
    }
  }

  void openSection(String s) {
    section = s;
    taskId = null;
    draft = null;
    query = '';
    notifyListeners();
  }

  void openTask(String id) {
    taskId = id;
    draft = null;
    notifyListeners();
  }

  /// Открыть задачу по ссылке (уведомление, виджет): раздел подбирается так, чтобы задача была видна.
  void revealTask(String id) {
    final t = repo.tasks[id];
    if (t == null) return;
    final top = repo.tasks[t.parentId] ?? t;
    if (!repo.tasksOf(section).any((x) => x.id == top.id)) {
      section = top.listId.isEmpty ? secTasks : top.listId;
    }
    openTask(id);
  }

  void closeTask() {
    taskId = null;
    draft = null;
    notifyListeners();
  }

  void startDraft(Ent d) {
    draft = d;
    taskId = null;
    notifyListeners();
  }

  void setQuery(String q) {
    query = q;
    notifyListeners();
  }

  /// Черновик задачи для текущего раздела (быстрое добавление и полная форма).
  Ent draftForSection({String title = '', bool private = false, String date = '', String? listId}) {
    final lid = listId ?? (isBuiltinSection(section) ? '' : section);
    return repo.draftTask(
      title: title,
      listId: lid,
      private: (private || section == secPrivate) && repo.privateAllowed(lid), // в «Моих делах» задача сразу приватная
      date: date,
      inToday: section == secToday,
      important: section == secImportant, // в «Важных» задача сразу со звёздочкой
    );
  }

  String sectionTitle(String s) {
    switch (s) {
      case secToday:
        return 'Сегодняшний день';
      case secImportant:
        return 'Важные';
      case secPlanned:
        return 'Запланировано';
      case secSchedule:
        return 'Планирование';
      case secTasks:
        return 'Задачи';
      case secPrivate:
        return 'Мои дела';
    }
    return repo.lists[s]?.name ?? 'Список';
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
