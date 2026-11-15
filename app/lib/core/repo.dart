// Состояние приложения: все операции идут в локальную базу, синхронизация — отдельно (sync.dart).
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';

import 'model.dart';
import 'storage.dart';

const _uuid = Uuid();

/// Пользователь локального режима (без сервера).
const localUserId = 'local';

/// Встроенные разделы левого меню.
const secToday = 'today', secImportant = 'important', secPlanned = 'planned', secTasks = 'tasks', secPrivate = 'private', secSchedule = 'schedule';

/// Встроенный раздел (не пользовательский список).
/// Цвета виджета Android в локальных настройках устройства: фон, окантовка, текст, акцент.
const widgetColorKeys = ['w_bg', 'w_border', 'w_text', 'w_accent'];

/// Непрозрачность фона виджета, 0..100.
int widgetAlpha(Repo r) => (int.tryParse(r.kv['w_alpha'] ?? '') ?? 100).clamp(0, 100);

/// Виджет показывает только задачи, где пользователь исполнитель (иначе — все задачи списка).
bool widgetMineOnly(Repo r) => !r.isLocal && r.kv['w_scope'] == 'mine';

bool isBuiltinSection(String s) => s == secToday || s == secImportant || s == secPlanned || s == secTasks || s == secPrivate || s == secSchedule;

class Repo extends ChangeNotifier {
  final Storage st;
  final int Function() clock;
  Repo(this.st, {int Function()? clock}) : clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Map<String, Ent> tasks = {};
  final Map<String, Ent> lists = {};
  List<User> users = [];
  Map<String, String> kv = {};

  /// Настройки пользователя: ключ -> {v, t}; [settingsDirty] — изменённые здесь и ещё не отправленные.
  Map<String, Map<String, dynamic>> settings = {};
  Set<String> settingsDirty = {};
  Map<String, dynamic> global = {};

  /// Вызывается после локального изменения: повод синхронизироваться.
  VoidCallback? onLocalChange;

  Future<void> load() async {
    await st.open();
    await reload();
  }

  /// Перечитать базу (её могла изменить фоновая синхронизация или виджет).
  Future<void> reload() async {
    kv = await st.loadKv();
    tasks.clear();
    lists.clear();
    for (final e in await st.loadEnts()) {
      (e.kind == 'list' ? lists : tasks)[e.id] = e;
    }
    users = [for (final u in (jsonDecode(kv['users'] ?? '[]') as List)) User.fromJson((u as Map).cast<String, dynamic>())];
    settings = (jsonDecode(kv['settings'] ?? '{}') as Map).map((k, v) => MapEntry(k as String, (v as Map).cast<String, dynamic>()));
    settingsDirty = (jsonDecode(kv['settings_dirty'] ?? '[]') as List).cast<String>().toSet();
    global = (jsonDecode(kv['global'] ?? '{}') as Map).cast<String, dynamic>();
    notifyListeners();
  }

  // ---- настройки устройства (только локально) ----

  String get serverUrl => kv['server_url'] ?? '';
  String get accessKey => kv['access_key'] ?? '';
  String get pin => kv['pin'] ?? '';
  String get token => kv['token'] ?? '';
  String get me => kv['user_id'] ?? '';
  bool get loggedIn => me.isNotEmpty;

  /// Локальный режим: без сервера, задачник для одного человека на этом устройстве.
  bool get isLocal => kv['mode'] == 'local';

  /// Пользователь удалён на сервере: синхронизация остановлена, приложение работает автономно.
  bool get detached => kv['detached'] == '1';

  Future<void> setKv(String k, String? v) async {
    if (v == null) {
      kv.remove(k);
    } else {
      kv[k] = v;
    }
    await st.putKv(k, v);
  }

  /// Настройка только этого устройства, от которой зависит внешний вид (например, фоновая картинка).
  /// [persist] = false — только показать (пока ползунок двигается), без записи на диск.
  Future<void> setLocal(String k, String? v, {bool persist = true}) async {
    // сначала показать, потом записать на диск
    if (v == null) {
      kv.remove(k);
    } else {
      kv[k] = v;
    }
    notifyListeners();
    if (persist) await st.putKv(k, v);
  }

  // ---- пользователи ----

  User? user(String id) {
    for (final u in users) {
      if (u.id == id) return u;
    }
    return null;
  }

  User? get meUser => user(me);
  String userName(String id) => user(id)?.name ?? '—';
  bool get isAdmin => meUser?.isAdmin ?? false;
  bool get adminMode => isAdmin && setting<bool>('admin_mode', false);

  Future<void> setUsers(List<User> list) async {
    users = list;
    await setKv('users', jsonEncode([for (final u in list) u.toJson()]));
  }

  // ---- настройки пользователя (синхронизируются) ----

  T setting<T>(String key, T def) {
    final v = settings[key]?['v'];
    return v is T ? v : def;
  }

  Future<void> setSetting(String key, dynamic value) async {
    settings[key] = {'v': value, 't': clock()};
    settingsDirty.add(key);
    await _saveSettings();
    notifyListeners();
    onLocalChange?.call();
  }

  Future<void> _saveSettings() async {
    await setKv('settings', jsonEncode(settings));
    await setKv('settings_dirty', jsonEncode(settingsDirty.toList()));
  }

  /// Настройки с сервера: неотправленные локальные ключи сохраняются.
  Future<void> mergeSettings(Map<String, dynamic> server, {Map<String, int>? sentT}) async {
    for (final e in server.entries) {
      final k = e.key;
      if (settingsDirty.contains(k)) {
        if (sentT == null || (settings[k]?['t'] as num?)?.toInt() != sentT[k]) continue;
        settingsDirty.remove(k);
      }
      settings[k] = (e.value as Map).cast<String, dynamic>();
    }
    await _saveSettings();
  }

  String get viewMode => setting<String>('view_mode', 'all'); // all | mine
  /// Раздел «Запланировано» убран: его заменило «Планирование».
  String get homeSection {
    final s = setting<String>('home_list', secToday);
    return s == secPlanned ? secSchedule : s;
  }
  String get deadlineTime => setting<String>('deadline_time', '09:00');

  // ---- время ----

  /// Часовой пояс для дат: из настроек сервера, а если там не задан — пояс устройства.
  tz.Location get loc {
    final z = (global['tz'] ?? '').toString();
    if (z.isNotEmpty && !isLocal) {
      try {
        return tz.getLocation(z);
      } catch (_) {}
    }
    return tz.local;
  }

  DateTime nowDt() => DateTime.fromMillisecondsSinceEpoch(clock());
  String get today => fmtDate(tz.TZDateTime.from(nowDt(), loc));

  /// Момент (мс) «в такой-то день в такое-то время» по часовому поясу из настроек.
  int momentOf(String date, String hhmm) {
    final d = parseDate(date);
    final p = hhmm.split(':');
    return tz.TZDateTime(loc, d.year, d.month, d.day, int.tryParse(p[0]) ?? 9, p.length > 1 ? int.tryParse(p[1]) ?? 0 : 0).millisecondsSinceEpoch;
  }

  /// Момент в часовом поясе из настроек (для показа часов и минут).
  DateTime localOf(int ms) => tz.TZDateTime.fromMillisecondsSinceEpoch(loc, ms);

  String dateOfMoment(int ms) => fmtDate(tz.TZDateTime.fromMillisecondsSinceEpoch(loc, ms));

  /// Просрочена: все пункты планирования остались в прошлых днях (до переноса на сегодня).
  bool overdue(Ent t) {
    if (t.done) return false;
    final p = t.plans;
    return p.isNotEmpty && p.last.date.compareTo(today) < 0;
  }

  /// Ближайший пункт планирования (сегодня и дальше; если таких нет — последний).
  PlanItem? nextPlan(Ent t) {
    final p = t.plans;
    if (p.isEmpty) return null;
    final td = today;
    for (final x in p) {
      if (x.date.compareTo(td) >= 0) return x;
    }
    return p.last;
  }


  // ---- права (сервер проверяет то же самое) ----

  bool canEdit(Ent e) => e.creatorId == me || (adminMode && !e.isPrivate);
  bool canToggle(Ent t) => canEdit(t) || t.assigneeId == me;

  /// Можно ли сделать новую задачу в этом списке приватной.
  bool privateAllowed(String listId) {
    final a = lists[listId]?.s('assignee_id') ?? '';
    return a.isEmpty || a == me;
  }

  // ---- выборки ----

  /// [allUsers] — без учёта режима «Только свои» (так показывает задачи виджет).
  bool _visible(Ent t, {bool allUsers = false}) {
    if (t.deleted) return false;
    if (t.isPrivate) return t.creatorId == me;
    return allUsers || viewMode == 'all' || t.assigneeId == me;
  }

  /// Все списки, независимо от режима отображения.
  List<Ent> get allLists => _sortLists(lists.values.where((l) => !l.deleted).toList());

  /// Порядок списков — личная настройка пользователя (синхронизируется между его устройствами).
  /// Списки, которых в ней нет (новые), идут в конце по времени создания.
  List<Ent> _sortLists(List<Ent> out) {
    final order = setting<List>('list_order', const []);
    final pos = {for (var i = 0; i < order.length; i++) order[i].toString(): i};
    out.sort((a, b) {
      final pa = pos[a.id], pb = pos[b.id];
      if (pa != null && pb != null) return pa.compareTo(pb);
      if (pa != null) return -1;
      if (pb != null) return 1;
      return a.createdAt.compareTo(b.createdAt);
    });
    return out;
  }

  /// Переставить список в меню: [from] и [to] — места среди видимых списков.
  /// Скрытые режимом «Только свои» списки остаются на своих местах.
  Future<void> moveList(int from, int to) async {
    final visible = visibleLists.map((l) => l.id).toList();
    if (from < 0 || from >= visible.length || to < 0 || to >= visible.length || from == to) return;
    final shown = visible.toSet();
    visible.insert(to, visible.removeAt(from));
    var i = 0;
    final order = [for (final l in allLists) shown.contains(l.id) ? visible[i++] : l.id];
    await setSetting('list_order', order);
  }

  List<Ent> get visibleLists {
    final out = lists.values.where((l) {
      if (l.deleted) return false;
      final a = l.s('assignee_id');
      return viewMode == 'all' || a.isEmpty || a == me;
    }).toList();
    return _sortLists(out);
  }

  static int _order(Ent a, Ent b) {
    final c = b.createdAt.compareTo(a.createdAt);
    return c != 0 ? c : a.id.compareTo(b.id);
  }

  /// Задача закрыта в один из прошлых дней.
  bool _closedBefore(Ent t, String today) => t.done && t.completedAt > 0 && dateOfMoment(t.completedAt).compareTo(today) < 0;

  /// «Сегодняшний день» — задачи с пунктом планирования на сегодня.
  bool _inToday(Ent t, String today) => t.plans.any((p) => p.date == today);

  /// Есть ли у задачи пункт на сегодня (кнопка «Добавить в „Сегодня“» тогда скрыта).
  bool plannedToday(Ent t) => _inToday(t, today);



  /// Задачи раздела или списка (без учёта вложенности).
  List<Ent> tasksOf(String section, {bool allUsers = false}) {
    final td = today;
    final out = tasks.values.where((t) {
      if (!_visible(t, allUsers: allUsers)) return false;
      switch (section) {
        case secToday:
          return _inToday(t, td);
        case secImportant:
          return t.important;
        case secPlanned:
        case secSchedule:
          return t.planned;
        case secTasks:
          return t.listId.isEmpty;
        case secPrivate:
          return t.isPrivate; // чужие приватные задачи отсекает _visible
        default:
          return t.listId == section;
      }
    }).toList();
    out.sort(_order);
    return out;
  }

  List<Ent> search(String q) {
    final needle = q.trim().toLowerCase();
    if (needle.isEmpty) return [];
    final out = tasks.values.where((t) {
      if (!_visible(t)) return false;
      if (t.title.toLowerCase().contains(needle) || t.description.toLowerCase().contains(needle)) return true;
      return t.checklist.any((c) => (c['text'] ?? '').toString().toLowerCase().contains(needle));
    }).toList();
    out.sort(_order);
    return out;
  }

  List<Ent> children(String parentId, {bool includeDeleted = false}) {
    final out = tasks.values.where((t) => t.parentId == parentId && (includeDeleted || !t.deleted)).toList();
    out.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return out;
  }

  int openCount(String section) => tasksOf(section).where((t) => !t.done).length;

  // ---- изменения ----

  bool _set(Ent e, String k, dynamic v) {
    if (jsonEncode(e.f[k]) == jsonEncode(v)) return false;
    e.f[k] = v;
    e.t[k] = clock();
    e.d.add(k);
    return true;
  }

  /// Локальный «предпросмотр» того, что сервер сделает сам (каскады): без отметки «изменено».
  void _preview(Ent e, String k, dynamic v) => e.f[k] = v;

  Future<void> _save(Iterable<Ent> ents, {bool local = true}) async {
    await st.putEnts(ents);
    notifyListeners();
    if (local) onLocalChange?.call();
  }

  void _applyListRules(Ent t) {
    final parent = tasks[t.parentId];
    if (parent != null) _set(t, 'list_id', parent.listId);
    final la = lists[t.listId]?.s('assignee_id') ?? '';
    if (t.isPrivate) {
      _setAssignee(t, t.creatorId);
    } else if (la.isNotEmpty) {
      _setAssignee(t, la);
    } else if (t.assigneeId.isEmpty) {
      _setAssignee(t, t.creatorId);
    }
  }

  void _setAssignee(Ent t, String uid) {
    if (t.assigneeId == uid) return;
    _set(t, 'assignee_id', uid);
  }
  // ---- пункты планирования ----

  String newPlanId() => _uuid.v4().substring(0, 8);

  /// Записать пункты планирования (автор или исполнитель). Для черновика меняется только сам объект.
  Future<void> setPlans(Ent t, List<PlanItem> items) async {
    final list = [...items]..sort(PlanItem.compare);
    _set(t, 'plans', [for (final p in list) p.toJson()]);
    if (tasks.containsKey(t.id)) {
      await _save([t]);
    } else {
      notifyListeners();
    }
  }

  /// Добавить пункт или заменить пункт с тем же id.
  Future<void> putPlan(Ent t, PlanItem p) => setPlans(t, [for (final x in t.plans) if (x.id != p.id) x, p]);

  Future<void> removePlan(Ent t, String id) => setPlans(t, [for (final x in t.plans) if (x.id != id) x]);

  /// «Добавить в „Сегодня“»: пункт без времени на сегодня.
  Future<void> addToday(Ent t) async {
    if (plannedToday(t)) return;
    await putPlan(t, PlanItem(newPlanId(), today));
  }

  /// Черновик новой задачи (в базу не пишется, пока не вызван [addTask]).
  /// [date] — пункт планирования без времени на этот день.
  Ent draftTask({
    String title = '',
    String listId = '',
    bool private = false,
    String date = '',
    String parentId = '',
    bool inToday = false,
    bool important = false,
  }) {
    final parent = tasks[parentId];
    final t = Ent('task', _uuid.v4(), creatorId: me, isPrivate: parent?.isPrivate ?? private, createdAt: clock());
    _set(t, 'title', title);
    if (parent != null) {
      _set(t, 'parent_id', parentId);
      _set(t, 'list_id', parent.listId);
    } else if (listId.isNotEmpty) {
      _set(t, 'list_id', listId);
    }
    if (inToday && date.isEmpty) date = today;
    if (date.isNotEmpty) _set(t, 'plans', [PlanItem(newPlanId(), date).toJson()]);
    if (important) _set(t, 'is_important', true);
    _set(t, 'assignee_id', me);
    _applyListRules(t);
    return t;
  }

  Future<Ent> addTask(Ent draft) async {
    _applyListRules(draft);
    tasks[draft.id] = draft;
    await _save([draft]);
    return draft;
  }

  /// Изменить поле задачи. Для черновика (ещё не в базе) меняется только сам объект.
  Future<void> setTaskField(Ent t, String k, dynamic v) async {
    final changed = <Ent>[t];

    if (k == 'assignee_id') {
      _setAssignee(t, v as String);
    } else {
      _set(t, k, v);
    }
    if (k == 'list_id') {
      _applyListRules(t);
      for (final c in children(t.id)) {
        _set(c, 'list_id', v);
        _applyListRules(c);
        changed.add(c);
      }
    }
    if (tasks.containsKey(t.id)) {
      await _save(changed);
    } else {
      notifyListeners();
    }
  }

  /// Пункты, полученные из полей прежних версий (срок, напоминание, «Сегодня»),
  /// которые изменены позже пунктов планирования (или пунктов ещё не было).
  List<PlanItem> _legacyPlans(Ent t, String td) {
    final since = t.t['plans'] ?? -1;
    bool fresh(String k) => (t.t[k] ?? 0) > since;
    final out = <PlanItem>[];
    if (fresh('reminder_at') && t.reminderAt > 0) {
      final d = dateOfMoment(t.reminderAt), a = localOf(t.reminderAt);
      final from = a.hour * 60 + a.minute;
      // задача с напоминанием занимает на шкале полчаса от времени напоминания
      out.add(PlanItem('lr${t.reminderAt.toRadixString(36)}', d, from: from, to: (from + 30).clamp(from + 1, 1440), notify: true, before: 0));
    }
    if (fresh('deadline') && t.deadline.isNotEmpty) {
      out.add(PlanItem('ld${t.deadline.replaceAll('-', '')}', t.deadline, notify: true));
    }
    if (fresh('in_today') && t.inToday && !_closedBefore(t, td)) {
      out.add(PlanItem('lt${td.replaceAll('-', '')}', td));
    }
    return out;
  }

  /// Ежедневное обслуживание пунктов планирования (после каждой синхронизации):
  /// - поля прежних версий переводятся в пункты;
  /// - открытая задача, у которой все пункты остались в прошлых днях, получает пункт без времени на сегодня;
  /// - у закрытой задачи убираются пункты на дни после закрытия.
  /// Делают это автор и исполнитель (им можно менять пункты).
  Future<void> dailyMaintenance() async {
    final td = today;
    final changed = <Ent>[];
    for (final t in tasks.values) {
      if (t.deleted || !canToggle(t)) continue;
      var items = t.plans;
      var dirty = false;
      for (final p in _legacyPlans(t, td)) {
        // пункт без времени не нужен, если на этот день уже что-то есть
        if (items.any((x) => x.id == p.id || (x.date == p.date && (!p.timed || x.from == p.from)))) continue;
        items = [...items, p];
        dirty = true;
      }
      if (!t.done && items.isNotEmpty && items.every((p) => p.date.compareTo(td) < 0)) {
        items = [...items, PlanItem('roll${td.replaceAll('-', '')}', td)];
        dirty = true;
      }
      if (t.done && t.completedAt > 0) {
        final closed = dateOfMoment(t.completedAt);
        final keep = items.where((p) => p.date.compareTo(closed) <= 0).toList();
        if (keep.length != items.length) {
          items = keep;
          dirty = true;
        }
      }
      // пункты записываются и тогда, когда поля прежних версий есть, а пунктов нет: больше их не разбираем
      if (!dirty && t.t['plans'] != null) continue;
      if (!dirty && !_hasLegacy(t)) continue;
      items.sort(PlanItem.compare);
      _set(t, 'plans', [for (final p in items) p.toJson()]);
      if (!dirty) t.t['plans'] = clock(); // значение то же — отметка, что поля прежних версий разобраны
      if (!dirty) t.d.add('plans');
      changed.add(t);
    }
    if (changed.isNotEmpty) await _save(changed);
  }

  bool _hasLegacy(Ent t) => t.deadline.isNotEmpty || t.reminderAt > 0 || t.inToday;

  /// Почему задачу нельзя закрыть (или null, если можно).
  String? closeBlocker(Ent t) {
    if (children(t.id).any((c) => !c.done)) return 'Сначала закройте подзадачи';
    return null;
  }

  /// Закрыть или переоткрыть задачу. Регулярная задача при закрытии порождает следующий экземпляр.
  Future<void> setDone(Ent t, bool done) async {
    if (done && closeBlocker(t) != null) return;
    final changed = <Ent>[t];
    final td = today;
    final items = t.plans;
    _set(t, 'status', done ? 'done' : 'open');
    final rule = t.recurrence;
    if (done && rule != null && t.parentId.isEmpty) {
      // ID следующего экземпляра выводится из ID текущего: если задачу закроют на двух
      // устройствах офлайн, получится один и тот же экземпляр, а не два
      final nextId = _uuid.v5(_nsFor(t.id), 'next');
      if (!tasks.containsKey(nextId)) {
        // отсчёт — от первого пункта планирования (или от сегодняшнего дня); все пункты сдвигаются вместе
        final base = items.isEmpty ? td : items.first.date;
        final nd = nextDeadline(base, rule, td);
        final shift = daysBetween(base, nd);
        final n = Ent('task', nextId, creatorId: t.creatorId, isPrivate: t.isPrivate, createdAt: clock());
        _set(n, 'title', t.title);
        _set(n, 'description', t.description);
        _set(n, 'checklist', [for (final c in t.checklist) {'text': c['text'], 'done': false}]);
        _set(n, 'list_id', t.listId);
        _set(n, 'assignee_id', t.assigneeId);
        _set(n, 'is_important', t.important);
        _set(n, 'recurrence', rule);
        _set(n, 'plans', [
          if (items.isEmpty) PlanItem(_uuid.v5(_nsFor(nextId), 'p0').substring(0, 8), nd).toJson(),
          for (final p in items) p.copyWith(id: _uuid.v5(_nsFor(nextId), p.id).substring(0, 8), date: addDays(p.date, shift)).toJson(),
        ]);
        tasks[n.id] = n;
        changed.add(n);
        for (final c in children(t.id)) {
          final cn = Ent('task', _uuid.v5(_nsFor(c.id), 'next'), creatorId: c.creatorId, isPrivate: c.isPrivate, createdAt: clock());
          _set(cn, 'title', c.title);
          _set(cn, 'description', c.description);
          _set(cn, 'checklist', [for (final x in c.checklist) {'text': x['text'], 'done': false}]);
          _set(cn, 'parent_id', n.id);
          _set(cn, 'list_id', n.listId);
          _set(cn, 'assignee_id', c.assigneeId);
          _set(cn, 'is_important', c.important);
          tasks[cn.id] = cn;
          changed.add(cn);
        }
      }
    }
    if (done) {
      // Закрытая задача теряет повторение (следующий экземпляр уже создан выше) и пункты
      // планирования на следующие дни. Сегодняшние и прошлые пункты остаются.
      if (canEdit(t) && t.recurrence != null) _set(t, 'recurrence', null);
      final keep = [for (final p in items) if (p.date.compareTo(td) <= 0) p.toJson()];
      if (keep.length != items.length) _set(t, 'plans', keep);
    }
    await _save(changed);
  }

  static String _nsFor(String id) {
    // v5 требует UUID в качестве пространства имён; для нестандартных ID берём производный
    return RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$').hasMatch(id) ? id : _uuid.v5(Namespace.url.value, id);
  }

  Future<void> deleteTask(Ent t) async {
    _set(t, 'deleted', true);
    final kids = children(t.id);
    for (final c in kids) {
      _preview(c, 'deleted', true);
    }
    await _save([t, ...kids]);
  }

  Future<Ent> createList(String name, String assigneeId, {String color = ''}) async {
    final l = Ent('list', _uuid.v4(), creatorId: me, createdAt: clock());
    _set(l, 'name', name);
    if (assigneeId.isNotEmpty) _set(l, 'assignee_id', assigneeId);
    if (color.isNotEmpty) _set(l, 'color', color);
    lists[l.id] = l;
    await _save([l]);
    return l;
  }

  /// Цвет списка (карточки его задач в «Планировании»).
  Future<void> setListColor(Ent l, String color) async {
    if (_set(l, 'color', color)) await _save([l]);
  }

  Future<void> renameList(Ent l, String name) async {
    _set(l, 'name', name);
    await _save([l]);
  }

  /// Сменить исполнителя списка: все его задачи переходят новому исполнителю.
  Future<void> setListAssignee(Ent l, String uid) async {
    _set(l, 'assignee_id', uid);
    final affected = <Ent>[];
    for (final t in tasks.values.where((t) => t.listId == l.id && !t.deleted)) {
      if (t.isPrivate && uid.isNotEmpty && uid != t.creatorId) {
        _preview(t, 'list_id', '');
      } else if (uid.isNotEmpty && t.assigneeId != uid) {
        _preview(t, 'assignee_id', uid);
      }
      affected.add(t);
    }
    await _save([l, ...affected]);
  }

  /// Удалить список: его задачи удаляются или переходят в общий раздел «Задачи».
  Future<void> deleteList(Ent l, {required bool deleteTasks}) async {
    _set(l, 'delete_tasks', deleteTasks);
    _set(l, 'deleted', true);
    final affected = <Ent>[];
    for (final t in tasks.values.where((t) => t.listId == l.id && !t.deleted)) {
      if (deleteTasks && (!t.isPrivate || t.creatorId == l.creatorId)) {
        _preview(t, 'deleted', true);
      } else {
        _preview(t, 'list_id', '');
      }
      affected.add(t);
    }
    await _save([l, ...affected]);
    if (homeSection == l.id) await setSetting('home_list', secToday);
  }

  // ---- синхронизация: слияние версий сервера ----

  List<Ent> get dirtyTasks => tasks.values.where((e) => e.d.isNotEmpty).toList();
  List<Ent> get dirtyLists => lists.values.where((e) => e.d.isNotEmpty).toList();

  /// Версия сервера принимается целиком, кроме полей, изменённых здесь и ещё не отправленных.
  /// [sentT] — время полей в только что отправленной версии: если поле с тех пор не менялось,
  /// оно считается подтверждённым.
  Future<void> mergeServer(String kind, List<dynamic> rows, {Map<String, Map<String, int>>? sent}) async {
    final map = kind == 'list' ? lists : tasks;
    final put = <Ent>[], drop = <Ent>[];
    for (final raw in rows) {
      final srv = Ent.fromJson(kind, (raw as Map).cast<String, dynamic>())..d.clear();
      var cur = map[srv.id];
      if (cur == null) {
        cur = srv;
      } else {
        final sentT = sent?[srv.id];
        cur.creatorId = srv.creatorId;
        cur.isPrivate = srv.isPrivate;
        for (final k in defaultsOf(kind).keys) {
          if (cur.d.contains(k)) {
            if (sentT == null || cur.t[k] != sentT[k]) continue;
            cur.d.remove(k);
          }
          cur.f[k] = srv.f[k];
          if (srv.t.containsKey(k)) cur.t[k] = srv.t[k]!;
        }
      }
      if (cur.deleted && cur.d.isEmpty) {
        map.remove(cur.id);
        drop.add(cur);
      } else {
        map[cur.id] = cur;
        put.add(cur);
      }
    }
    await st.putEnts(put);
    await st.deleteEnts(drop);
  }

  /// Отклонённые сервером записи, которых он не вернул (например, нет прав на создание):
  /// перестаём их отправлять.
  Future<void> dropRejected(String kind, Iterable<String> ids, Map<String, Map<String, int>> sent, Set<String> returned) async {
    final map = kind == 'list' ? lists : tasks;
    final put = <Ent>[];
    for (final id in ids) {
      final e = map[id];
      if (e == null || returned.contains(id) || !sent.containsKey(id)) continue;
      e.d.removeWhere((k) => e.t[k] == sent[id]![k]);
      put.add(e);
    }
    await st.putEnts(put);
  }

  /// Другая база на сервере (переезд, восстановление): всё открытое отправляется заново.
  Future<void> markAllDirty() async {
    final put = <Ent>[];
    for (final e in [...tasks.values, ...lists.values]) {
      if (e.deleted || (e.kind == 'task' && e.done)) continue;
      if (e.isPrivate && e.creatorId != me) continue;
      e.d.addAll(e.t.keys);
      put.add(e);
    }
    await st.putEnts(put);
  }

  void changed() => notifyListeners();

  /// Начать работу без сервера. Данные прежнего пользователя (если были) убираются.
  Future<void> startLocal() async {
    await resetForUser(localUserId, '');
    await setKv('mode', 'local');
    await setKv('global', null);
    global = {};
    await setUsers(const [User(localUserId, 'Я')]);
    notifyListeners();
  }

  /// Подключение к серверу после локального режима: задачи и списки этого устройства переходят
  /// к вошедшему пользователю и отправляются на сервер, личные настройки — тоже.
  Future<void> adoptLocal(String uid, String tokenValue) async {
    final put = <Ent>[], drop = <Ent>[];
    for (final e in [...tasks.values, ...lists.values]) {
      if (e.deleted) {
        drop.add(e);
        continue;
      }
      if (e.creatorId == localUserId || e.creatorId.isEmpty) e.creatorId = uid;
      if (e.s('assignee_id') == localUserId) e.f['assignee_id'] = uid;
      e.d.addAll(e.t.keys);
      if (e.kind == 'task' && e.t.containsKey('assignee_id')) e.d.add('assignee_id');
      put.add(e);
    }
    for (final e in drop) {
      (e.kind == 'list' ? lists : tasks).remove(e.id);
    }
    await st.deleteEnts(drop);
    await st.putEnts(put);
    settingsDirty = settings.keys.toSet();
    await _saveSettings();
    for (final k in ['mode', 'cursor', 'epoch', 'detached', 'global']) {
      await setKv(k, null);
    }
    global = {};
    await setKv('token', tokenValue);
    await setKv('user_id', uid);
    notifyListeners();
  }

  /// Смена пользователя на устройстве: локальные данные прежнего пользователя убираются.
  Future<void> resetForUser(String uid, String tokenValue) async {
    await st.deleteEnts([...tasks.values, ...lists.values]);
    tasks.clear();
    lists.clear();
    settings = {};
    settingsDirty = {};
    await _saveSettings();
    await setKv('cursor', null);
    await setKv('epoch', null);
    await setKv('detached', null);
    await setKv('fired', null);
    await setKv('scheduled', null);
    await setKv('notify_from', clock().toString());
    await setKv('mode', null);
    await setKv('token', tokenValue);
    await setKv('user_id', uid);
    notifyListeners();
  }

  /// Выйти: устройство возвращается к экрану подключения, локальные данные убираются.
  Future<void> signOut() async {
    await resetForUser('', '');
    await setKv('user_id', null);
    await setKv('token', null);
    notifyListeners();
  }
}
