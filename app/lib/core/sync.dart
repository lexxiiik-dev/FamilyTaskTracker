// Синхронизация: сначала отправить локальные изменения, потом забрать изменения с сервера.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'model.dart';
import 'repo.dart';
import 'transport.dart';

enum SyncState { idle, running, offline, needLogin, detached }

class SyncEngine extends ChangeNotifier {
  final Repo repo;
  final Transport Function(ServerConfig) factory;
  SyncEngine(this.repo, {Transport Function(ServerConfig)? factory}) : factory = factory ?? createTransport;

  SyncState state = SyncState.idle;
  String lastError = '';
  DateTime? lastOk;

  /// Вызывается после каждой удачной синхронизации (пересчёт напоминаний, виджет).
  Future<void> Function()? afterSync;

  Transport? _t;
  String _tKey = '';
  Future<bool>? _running;
  Timer? _debounce;

  Transport get transport {
    final key = '${repo.serverUrl}|${repo.accessKey}|${repo.pin}|${repo.token}';
    if (_t == null || key != _tKey) {
      _t?.close();
      _t = factory(ServerConfig(url: repo.serverUrl, accessKey: repo.accessKey, pin: repo.pin, token: repo.token));
      _tKey = key;
    }
    return _t!;
  }

  /// Запрос с обработкой переезда: сервер ответил 410 и новым адресом — запоминаем его и повторяем.
  Future<Resp> call(String method, String path, {Object? body}) async {
    var r = await transport.send(method, path, body: body);
    if (r.status == 410) {
      final moved = (r.json['moved_to'] ?? '').toString();
      if (moved.startsWith('https://')) {
        await repo.setKv('server_url', moved);
        r = await transport.send(method, path, body: body);
      }
    }
    return r;
  }

  /// Синхронизация после локального изменения — с небольшой задержкой, чтобы собрать пачку правок.
  void schedule([Duration delay = const Duration(milliseconds: 1500)]) {
    _debounce?.cancel();
    _debounce = Timer(delay, () => sync());
  }

  Future<bool> sync() {
    return _running ??= _sync().whenComplete(() => _running = null);
  }

  void _setState(SyncState s, [String err = '']) {
    state = s;
    lastError = err;
    notifyListeners();
  }

  Future<bool> _sync() async {
    if (repo.isLocal) {
      // без сервера: только то, что делается после синхронизации (конец дня, виджет, напоминания)
      try {
        await afterSync?.call();
      } catch (e) {
        debugPrint('afterSync: $e');
      }
      return true;
    }
    if (!repo.loggedIn || repo.token.isEmpty) {
      _setState(SyncState.needLogin);
      return false;
    }
    if (repo.detached) {
      _setState(SyncState.detached);
      return false;
    }
    _setState(SyncState.running);
    try {
      if (!await _push()) return false;
      if (!await _pull()) return false;
      lastOk = DateTime.now();
      _setState(SyncState.idle);
      repo.changed();
      try {
        await afterSync?.call();
      } catch (e) {
        debugPrint('afterSync: $e');
      }
      return true;
    } catch (e) {
      _setState(SyncState.offline, e.toString());
      return false;
    }
  }

  Future<bool> _authFailed(Resp r) async {
    if (r.status != 401) return false;
    final err = r.json['error'];
    if (err == 'user_deleted') {
      // пользователя удалили: синхронизация прекращается, локальные данные остаются
      await repo.setKv('detached', '1');
      _setState(SyncState.detached);
    } else {
      // токен устройства больше не действует (например, сменили пароль): нужно войти заново
      await repo.setKv('token', null);
      _setState(SyncState.needLogin, 'Войдите заново');
    }
    repo.changed();
    return true;
  }

  Future<bool> _push() async {
    final tasks = repo.dirtyTasks, lists = repo.dirtyLists;
    final dirtySettings = {for (final k in repo.settingsDirty) k: repo.settings[k]};
    if (tasks.isEmpty && lists.isEmpty && dirtySettings.isEmpty) return true;
    Map<String, Map<String, int>> snap(List<Ent> l) => {for (final e in l) e.id: Map<String, int>.from(e.t)};
    final sentTasks = snap(tasks), sentLists = snap(lists);
    final sentSettings = {for (final e in dirtySettings.entries) e.key: ((e.value?['t'] ?? 0) as num).toInt()};
    final r = await call(
      'POST',
      '/v1/changes',
      body: {
        'now': repo.clock(),
        'tasks': [for (final e in tasks) e.toJson()],
        'lists': [for (final e in lists) e.toJson()],
        if (dirtySettings.isNotEmpty) 'settings': dirtySettings,
      },
    );
    if (await _authFailed(r)) return false;
    if (!r.ok) throw Exception(r.error);
    final j = r.json;
    final rt = (j['tasks'] as List?) ?? const [], rl = (j['lists'] as List?) ?? const [];
    await repo.mergeServer('list', rl, sent: sentLists);
    await repo.mergeServer('task', rt, sent: sentTasks);
    final rejected = ((j['rejected'] as List?) ?? const []).cast<String>();
    await repo.dropRejected('task', rejected, sentTasks, {for (final x in rt) (x as Map)['id'] as String});
    await repo.dropRejected('list', rejected, sentLists, {for (final x in rl) (x as Map)['id'] as String});
    if (j['settings'] is Map) {
      await repo.mergeSettings((j['settings'] as Map).cast<String, dynamic>(), sentT: sentSettings);
    }
    return true;
  }

  Future<bool> _pull() async {
    var repush = false;
    for (var page = 0; page < 200; page++) {
      final cursor = int.tryParse(repo.kv['cursor'] ?? '') ?? 0;
      final r = await call('GET', '/v1/changes?cursor=$cursor');
      if (await _authFailed(r)) return false;
      if (!r.ok) throw Exception(r.error);
      final j = r.json;
      final epoch = (j['epoch'] ?? '').toString();
      final known = repo.kv['epoch'] ?? '';
      if (epoch != known) {
        // на сервере другая база (переезд или восстановление): забираем всё заново
        await repo.setKv('epoch', epoch);
        if (known.isNotEmpty) {
          await repo.markAllDirty();
          repush = true;
        }
        if (cursor != 0) {
          await repo.setKv('cursor', '0');
          continue;
        }
      }

      await repo.mergeServer('list', (j['lists'] as List?) ?? const []);
      await repo.mergeServer('task', (j['tasks'] as List?) ?? const []);
      await repo.setUsers([for (final u in (j['users'] as List?) ?? const []) User.fromJson((u as Map).cast<String, dynamic>())]);
      if (j['settings'] is Map) await repo.mergeSettings((j['settings'] as Map).cast<String, dynamic>());
      if (j['global'] is Map) {
        final g = <String, dynamic>{for (final e in (j['global'] as Map).entries) e.key as String: (e.value as Map)['v']};
        repo.global = g;
        await repo.setKv('global', jsonEncode(g));
      }
      await repo.setKv('cursor', '${j['cursor']}');
      if (j['more'] != true) {
        // после смены базы на сервере свои открытые задачи отправляются заново
        return repush ? await _push() : true;
      }
    }
    return true;
  }

  // ---- вход ----

  /// На сервере ещё нет пользователей: первый вошедший станет администратором.
  bool setupNeeded = false;

  /// Проверить адрес и ключ, получить список пользователей для экрана входа.
  Future<List<User>> hello() async {
    final r = await call('GET', '/v1/hello');
    if (!r.ok) throw Exception(r.error);
    final j = r.json;
    setupNeeded = j['setup'] == true;
    final users = [for (final u in (j['users'] as List?) ?? const []) User.fromJson((u as Map).cast<String, dynamic>())];
    if (!repo.isLocal) await repo.setUsers(users);
    repo.changed();
    return users;
  }

  /// Первый запуск сервера: создать администратора и сразу войти. Возвращает null или текст ошибки.
  Future<String?> setup(String name, String password, String device) => _auth('/v1/setup', {'name': name, 'password': password, 'device': device});

  /// Войти под пользователем. Возвращает null при успехе или текст ошибки.
  Future<String?> login(String userId, String password, String device) => _auth('/v1/login', {'user_id': userId, 'password': password, 'device': device});

  Future<String?> _auth(String path, Map<String, dynamic> body) async {
    final Resp r;
    try {
      r = await call('POST', path, body: body);
    } catch (e) {
      return 'Нет связи с сервером';
    }
    if (!r.ok) return r.error;
    final uid = (r.json['user_id'] ?? '').toString();
    final token = (r.json['token'] ?? '').toString();
    if (repo.isLocal) {
      // был локальный режим: задачи этого устройства переезжают на сервер
      await repo.adoptLocal(uid, token);
    } else if (uid != repo.me || repo.detached) {
      await repo.resetForUser(uid, token);
    } else {
      await repo.setKv('token', token);
    }
    setupNeeded = false;
    _setState(SyncState.idle);
    unawaited(sync());
    return null;
  }

  // ---- управление пользователями (администратор) и свой пароль ----

  /// Запрос администратора; после успеха список пользователей обновляется. Возвращает null или текст ошибки.
  Future<String?> admin(String method, String path, [Map<String, dynamic>? body]) async {
    try {
      final r = await call(method, path, body: body);
      if (!r.ok) return r.error;
      await sync();
      return null;
    } catch (_) {
      return 'Нет связи с сервером';
    }
  }

  Future<String?> createUser(String name, String password, bool isAdmin) =>
      admin('POST', '/v1/admin/users', {'name': name, 'password': password, 'is_admin': isAdmin});

  /// [password]: null — не менять, '' — убрать пароль.
  Future<String?> updateUser(String id, {String? name, String? password, bool? isAdmin}) =>
      admin('PATCH', '/v1/admin/users/$id', {'name': ?name, 'password': ?password, 'is_admin': ?isAdmin});

  Future<String?> deleteUser(String id) => admin('DELETE', '/v1/admin/users/$id');

  /// Сменить свой пароль: это устройство получает новый токен, остальные устройства входят заново.
  Future<String?> changeMyPassword(String oldPassword, String newPassword) async {
    try {
      final r = await call('POST', '/v1/me/password', body: {'old': oldPassword, 'new': newPassword});
      if (!r.ok) return r.error;
      await repo.setKv('token', (r.json['token'] ?? '').toString());
      unawaited(sync());
      return null;
    } catch (_) {
      return 'Нет связи с сервером';
    }
  }
  // ---- аватарки ----

  final Map<String, Uint8List?> _avatars = {};

  Future<Uint8List?> avatar(User u) async {
    if (u.avatarVer == 0) return null;
    final key = '${u.id}:${u.avatarVer}';
    if (_avatars.containsKey(key)) return _avatars[key];
    final cached = repo.kv['avatar:${u.id}'];
    if (cached != null && cached.startsWith('${u.avatarVer}:')) {
      return _avatars[key] = base64Decode(cached.substring(cached.indexOf(':') + 1));
    }
    try {
      final r = await call('GET', '/v1/avatar/${u.id}?v=${u.avatarVer}');
      if (!r.ok) return null;
      await repo.setKv('avatar:${u.id}', '${u.avatarVer}:${base64Encode(r.body)}');
      return _avatars[key] = r.body;
    } catch (_) {
      return null;
    }
  }

  Future<String?> uploadAvatar(Uint8List jpeg) async {
    try {
      final r = await call('POST', '/v1/avatar', body: jpeg);
      if (!r.ok) return r.error;
      unawaited(sync());
      return null;
    } catch (_) {
      return 'Нет связи с сервером';
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _t?.close();
    super.dispose();
  }
}
