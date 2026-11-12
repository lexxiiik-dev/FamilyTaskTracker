// Управление пользователями сервера (администратор) и смена своего пароля.
import 'package:flutter/material.dart';

import '../core/model.dart';
import 'common.dart';

Future<void> showUsers(BuildContext context) => showDialog(context: context, builder: (_) => const UsersDialog());

class UsersDialog extends StatefulWidget {
  const UsersDialog({super.key});
  @override
  State<UsersDialog> createState() => _UsersDialogState();
}

class _UsersDialogState extends State<UsersDialog> {
  bool _busy = false;

  Future<void> _run(Future<String?> Function() action, String okText) async {
    setState(() => _busy = true);
    final err = await action();
    if (!mounted) return;
    setState(() => _busy = false);
    toast(context, err ?? okText);
  }

  Future<void> _add() async {
    final r = await showDialog<_UserForm>(context: context, builder: (_) => const _UserEditDialog());
    if (r == null) return;
    await _run(() => app.sync.createUser(r.name, r.password ?? '', r.isAdmin), 'Пользователь добавлен');
  }

  Future<void> _edit(User u) async {
    final r = await showDialog<_UserForm>(
      context: context,
      builder: (_) => _UserEditDialog(user: u),
    );
    if (r == null) return;
    await _run(
      () => app.sync.updateUser(u.id, name: r.name != u.name ? r.name : null, password: r.password, isAdmin: r.isAdmin != u.isAdmin ? r.isAdmin : null),
      'Сохранено',
    );
  }

  Future<void> _delete(User u) async {
    if (!await confirm(
      context,
      'Удалить пользователя ${u.name}?',
      text:
          'Его приватные задачи удалятся. Общие задачи и списки перейдут к администратору. '
          'На его устройствах синхронизация остановится.',
      ok: 'Удалить',
    )) {
      return;
    }
    await _run(() => app.sync.deleteUser(u.id), 'Пользователь удалён');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app.repo,
      builder: (context, _) {
        final users = app.repo.users;
        final muted = mutedOf(context);
        return Dialog(
          insetPadding: const EdgeInsets.all(14),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460, maxHeight: 640),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 8, 4),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text('Пользователи', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                      ),
                      IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    children: [
                      for (final u in users)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Plate(
                            padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                            child: Row(
                              children: [
                                UserAvatar(u, size: 34),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(u.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                                      Text(
                                        [
                                          if (u.isAdmin) 'администратор',
                                          u.hasPassword ? 'с паролем' : 'без пароля',
                                          if (u.id == app.repo.me) 'это вы',
                                        ].join(' · '),
                                        style: TextStyle(fontSize: 12, color: muted),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(icon: const Icon(Icons.edit_outlined, size: 20), tooltip: 'Изменить', onPressed: _busy ? null : () => _edit(u)),
                                if (u.id != app.repo.me)
                                  IconButton(icon: const Icon(Icons.delete_outline, size: 20), tooltip: 'Удалить', onPressed: _busy ? null : () => _delete(u)),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('Новые пользователи входят с тем же адресом и ключом доступа.', style: TextStyle(fontSize: 12, color: muted)),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(onPressed: _busy ? null : _add, icon: const Icon(Icons.person_add_alt, size: 18), label: const Text('Добавить')),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _UserForm {
  final String name;
  final String? password; // null — не менять
  final bool isAdmin;
  const _UserForm(this.name, this.password, this.isAdmin);
}

/// Новый пользователь (user == null) или правка существующего.
class _UserEditDialog extends StatefulWidget {
  final User? user;
  const _UserEditDialog({this.user});
  @override
  State<_UserEditDialog> createState() => _UserEditDialogState();
}

class _UserEditDialogState extends State<_UserEditDialog> {
  late final _name = TextEditingController(text: widget.user?.name ?? '');
  final _pw = TextEditingController();
  late bool _admin = widget.user?.isAdmin ?? false;
  // правка: пароль меняется, только если его ввели или явно убрали
  bool _removePw = false;
  String _error = '';

  @override
  void dispose() {
    _name.dispose();
    _pw.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final pw = _pw.text;
    final isNew = widget.user == null;
    if (name.isEmpty) return setState(() => _error = 'Введите имя');
    if (pw.isNotEmpty && pw.length < 4) return setState(() => _error = 'Пароль — не короче 4 символов');
    final keepsPassword = !isNew && widget.user!.hasPassword && !_removePw;
    if (_admin && pw.isEmpty && !keepsPassword) return setState(() => _error = 'У администратора должен быть пароль');
    final String? password = pw.isNotEmpty ? pw : (isNew ? '' : (_removePw ? '' : null));
    Navigator.pop(context, _UserForm(name, password, _admin));
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.user;
    final self = u?.id == app.repo.me;
    return AlertDialog(
      title: Text(u == null ? 'Новый пользователь' : u.name),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('user-name'),
              controller: _name,
              autofocus: u == null,
              decoration: const InputDecoration(labelText: 'Имя'),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('user-pw'),
              controller: _pw,
              obscureText: true,
              decoration: InputDecoration(
                labelText: u == null ? 'Пароль (можно без пароля)' : (u.hasPassword ? 'Новый пароль' : 'Задать пароль'),
                helperText: u != null && u.hasPassword ? 'Пусто — оставить прежний' : null,
              ),
              onSubmitted: (_) => _save(),
            ),
            if (u != null && u.hasPassword && !_admin)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _removePw,
                onChanged: (v) => setState(() => _removePw = v ?? false),
                title: const Text('Убрать пароль'),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _admin,
              onChanged: self ? null : (v) => setState(() => _admin = v),
              title: const Text('Администратор'),
              subtitle: Text(self ? 'Свои права не изменить' : 'Управляет пользователями и настройками сервера', style: const TextStyle(fontSize: 12)),
            ),
            if (_error.isNotEmpty) Text(_error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: _save, child: Text(u == null ? 'Добавить' : 'Сохранить')),
      ],
    );
  }
}

/// Смена своего пароля.
Future<void> showChangePassword(BuildContext context) async {
  final ok = await showDialog<bool>(context: context, builder: (_) => const _MyPasswordDialog());
  if (ok == true && context.mounted) toast(context, 'Пароль изменён. На других устройствах нужно войти заново.');
}

class _MyPasswordDialog extends StatefulWidget {
  const _MyPasswordDialog();
  @override
  State<_MyPasswordDialog> createState() => _MyPasswordDialogState();
}

class _MyPasswordDialogState extends State<_MyPasswordDialog> {
  final _old = TextEditingController(), _new = TextEditingController(), _new2 = TextEditingController();
  String _error = '';
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_old, _new, _new2]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_new.text != _new2.text) return setState(() => _error = 'Пароли не совпадают');
    if (_new.text.isEmpty && app.repo.isAdmin) return setState(() => _error = 'У администратора должен быть пароль');
    setState(() {
      _busy = true;
      _error = '';
    });
    final err = await app.sync.changeMyPassword(_old.text, _new.text);
    if (!mounted) return;
    if (err == null) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final has = app.repo.meUser?.hasPassword ?? false;
    return AlertDialog(
      title: const Text('Пароль'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (has)
              TextField(
                controller: _old,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Текущий пароль'),
              ),
            const SizedBox(height: 10),
            TextField(
              controller: _new,
              obscureText: true,
              decoration: InputDecoration(labelText: 'Новый пароль', helperText: app.repo.isAdmin ? null : 'Пусто — входить без пароля'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _new2,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Новый пароль ещё раз'),
              onSubmitted: (_) => _save(),
            ),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Сохранить')),
      ],
    );
  }
}
