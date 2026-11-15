// Первый запуск: адрес сервера и ключ доступа (или работа без сервера), затем выбор пользователя.
// На новом сервере, где ещё нет пользователей, создаётся первый — он становится администратором.
// В вебе адрес сервера — это адрес самой страницы, спрашивается только ключ доступа.
import 'package:flutter/material.dart';

import '../core/model.dart';
import '../core/transport.dart';
import 'common.dart';

class LoginScreen extends StatefulWidget {
  /// Экран открыт из локального режима (подключение к серверу): есть кнопка «Назад».
  final bool fromLocal;
  const LoginScreen({super.key, this.fromLocal = false});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

enum _Step { connect, setup, pick }

class _LoginScreenState extends State<LoginScreen> {
  late final _url = TextEditingController(text: app.repo.serverUrl);
  late final _key = TextEditingController(text: app.repo.accessKey.isEmpty ? '' : [app.repo.accessKey, if (app.repo.pin.isNotEmpty) app.repo.pin].join('.'));
  final _name = TextEditingController(), _pw = TextEditingController(), _pw2 = TextEditingController();
  bool _busy = false;
  String _error = '';
  late _Step _step = (!widget.fromLocal && app.repo.accessKey.isNotEmpty && (isWebTransport || app.repo.serverUrl.isNotEmpty)) ? _Step.pick : _Step.connect;

  @override
  void initState() {
    super.initState();
    // адрес и ключ уже известны (например, вышли из пользователя): сразу список пользователей
    if (_step == _Step.pick) _refresh();
  }

  @override
  void dispose() {
    for (final c in [_url, _key, _name, _pw, _pw2]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await app.sync.hello();
      if (mounted) setState(() => _step = app.sync.setupNeeded ? _Step.setup : _Step.pick);
    } catch (_) {
      if (mounted) {
        setState(() {
          _step = _Step.connect;
          _error = 'Не удалось подключиться: проверьте адрес и ключ доступа';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() async {
    final url = isWebTransport ? '' : normalizeUrl(_url.text);
    final (key, pin) = splitAccessKey(_key.text);
    if ((!isWebTransport && url.isEmpty) || key.isEmpty) {
      setState(() => _error = isWebTransport ? 'Введите ключ доступа' : 'Введите адрес сервера и ключ доступа');
      return;
    }
    if (!isWebTransport && url.startsWith('https://') == false && !url.startsWith('http://')) {
      setState(() => _error = 'Адрес сервера начинается с https://');
      return;
    }
    await app.repo.setKv('server_url', url);
    await app.repo.setKv('access_key', key);
    await app.repo.setKv('pin', pin);
    await _refresh();
  }

  Future<void> _useLocal() async {
    if (!await confirm(
      context,
      'Работать без сервера?',
      text:
          'Задачи будут храниться только на этом устройстве, без синхронизации и совместной работы. '
          'Подключиться к серверу можно позже в настройках — задачи переедут на сервер.',
      ok: 'Работать локально',
    )) {
      return;
    }
    if (mounted) setState(() => _error = '');
    await app.repo.startLocal();
    await app.sync.sync();
  }

  Future<void> _setup() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Введите имя');
      return;
    }
    if (_pw.text.length < 4) {
      setState(() => _error = 'Пароль администратора — не короче 4 символов');
      return;
    }
    if (_pw.text != _pw2.text) {
      setState(() => _error = 'Пароли не совпадают');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    final err = await app.sync.setup(name, _pw.text, app.platform.deviceName);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err ?? '';
    });
    if (err == null) _done();
  }

  void _done() {
    if (widget.fromLocal && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final muted = mutedOf(context);
    final children = switch (_step) {
      _Step.connect => [
        Text(
          isWebTransport ? 'Ключ доступа выдаёт администратор сервера.' : 'Адрес сервера и ключ доступа выдаёт администратор сервера.',
          textAlign: TextAlign.center,
          style: TextStyle(color: muted),
        ),
        const SizedBox(height: 14),
        if (!isWebTransport) ...[
          TextField(
            key: const ValueKey('server-url'),
            controller: _url,
            decoration: const InputDecoration(labelText: 'Адрес сервера', hintText: 'https://1.2.3.4:8443'),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 10),
        ],
        TextField(
          key: const ValueKey('access-key'),
          controller: _key,
          decoration: const InputDecoration(labelText: 'Ключ доступа'),
          onSubmitted: (_) => _connect(),
        ),
        const SizedBox(height: 14),
        FilledButton(onPressed: _busy ? null : _connect, child: Text(_busy ? 'Подключение…' : 'Подключиться')),
        if (!isWebTransport && !widget.fromLocal) ...[
          const SizedBox(height: 18),
          Row(
            children: [
              const Expanded(child: Divider()),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text('или', style: TextStyle(color: muted)),
              ),
              const Expanded(child: Divider()),
            ],
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : _useLocal,
            icon: const Icon(Icons.phone_android_outlined, size: 18),
            label: const Text('Использовать локально'),
          ),
          const SizedBox(height: 6),
          Text(
            'Без сервера: задачи только на этом устройстве',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: muted),
          ),
        ],
      ],
      _Step.setup => [
        Text(
          'Сервер новый: создайте первого пользователя. Он станет администратором и сможет добавлять других.',
          textAlign: TextAlign.center,
          style: TextStyle(color: muted),
        ),
        const SizedBox(height: 14),
        TextField(
          key: const ValueKey('setup-name'),
          controller: _name,
          decoration: const InputDecoration(labelText: 'Ваше имя'),
        ),
        const SizedBox(height: 10),
        TextField(
          key: const ValueKey('setup-pw'),
          controller: _pw,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Пароль'),
        ),
        const SizedBox(height: 10),
        TextField(
          key: const ValueKey('setup-pw2'),
          controller: _pw2,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Пароль ещё раз'),
          onSubmitted: (_) => _setup(),
        ),
        const SizedBox(height: 14),
        FilledButton(onPressed: _busy ? null : _setup, child: Text(_busy ? 'Создание…' : 'Создать администратора')),
        const SizedBox(height: 4),
        TextButton(onPressed: () => setState(() => _step = _Step.connect), child: const Text('Другой сервер')),
      ],
      _Step.pick => [
        Text(
          'Кто вы?',
          textAlign: TextAlign.center,
          style: TextStyle(color: muted),
        ),
        const SizedBox(height: 14),
        UserPicker(onDone: _done),
        const SizedBox(height: 8),
        TextButton(onPressed: () => setState(() => _step = _Step.connect), child: Text(isWebTransport ? 'Другой ключ доступа' : 'Другой сервер')),
      ],
    };
    return Scaffold(
      appBar: widget.fromLocal ? AppBar(title: const Text('Подключение к серверу')) : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!widget.fromLocal) ...[
                    Icon(Icons.check_circle_outline, size: 54, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(height: 10),
                    const Text(
                      'Задачи',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 22),
                  ] else
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Text(
                        'Задачи и списки этого устройства переедут на сервер к пользователю, под которым вы войдёте.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: muted),
                      ),
                    ),
                  ...children,
                  if (_error.isNotEmpty || app.sync.lastError.isNotEmpty && _step == _Step.pick)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _error.isNotEmpty ? _error : app.sync.lastError,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                  const SizedBox(height: 18),
                  // на некоторых телефонах интерфейс крупный и не помещается — масштаб можно выбрать ещё до входа
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Размер интерфейса', style: TextStyle(color: muted)),
                      const SizedBox(width: 4),
                      const UiScaleControl(),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Карточки пользователей; у пользователя с паролем спрашивается пароль.
class UserPicker extends StatefulWidget {
  final VoidCallback onDone;
  const UserPicker({super.key, required this.onDone});
  @override
  State<UserPicker> createState() => _UserPickerState();
}

class _UserPickerState extends State<UserPicker> {
  String _busy = '';

  Future<void> _pick(User u) async {
    var password = '';
    if (u.hasPassword) {
      final p = await showDialog<String>(
        context: context,
        builder: (_) => _PasswordDialog(user: u),
      );
      if (p == null) return;
      password = p;
    }
    setState(() => _busy = u.id);
    final err = await app.sync.login(u.id, password, app.platform.deviceName);
    if (!mounted) return;
    setState(() => _busy = '');
    if (err != null) {
      toast(context, err);
    } else {
      widget.onDone();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app.repo,
      builder: (context, _) {
        final users = app.repo.isLocal ? const <User>[] : app.repo.users;
        if (users.isEmpty)
          return Text(
            'Список пользователей пуст',
            textAlign: TextAlign.center,
            style: TextStyle(color: mutedOf(context)),
          );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final u in users)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Plate(
                  onTap: _busy.isEmpty ? () => _pick(u) : null,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      UserAvatar(u, size: 38),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(u.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                            Text(
                              [if (u.isAdmin) 'администратор', if (u.hasPassword) '🔒 пароль', if (u.id == app.repo.me) 'текущий'].join(' · '),
                              style: TextStyle(fontSize: 12, color: mutedOf(context)),
                            ),
                          ],
                        ),
                      ),
                      if (_busy == u.id) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _PasswordDialog extends StatefulWidget {
  final User user;
  const _PasswordDialog({required this.user});
  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _c = TextEditingController();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Пароль: ${widget.user.name}'),
    content: TextField(
      controller: _c,
      autofocus: true,
      obscureText: true,
      decoration: const InputDecoration(hintText: 'Пароль'),
      onSubmitted: (v) => Navigator.pop(context, v),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
      FilledButton(onPressed: () => Navigator.pop(context, _c.text), child: const Text('Войти')),
    ],
  );
}
