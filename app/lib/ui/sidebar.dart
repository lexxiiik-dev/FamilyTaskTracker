// Левое меню: пользователь, режим, поиск, разделы, списки.
import 'package:flutter/material.dart';

import '../core/model.dart';
import '../core/repo.dart';
import '../core/sync.dart';
import 'common.dart';
import 'settings.dart';

class Sidebar extends StatefulWidget {
  final VoidCallback? onNavigate;
  const Sidebar({super.key, this.onNavigate});
  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _go(String section) {
    _search.clear();
    app.openSection(section);
    widget.onNavigate?.call();
  }

  @override
  Widget build(BuildContext context) => Live(builder: _build);

  Widget _build(BuildContext context) {
    final repo = app.repo;
    final cs = Theme.of(context).colorScheme;
    final me = repo.meUser;
    final lists = repo.visibleLists;
    if (app.query.isEmpty && _search.text.isNotEmpty) _search.clear();
    return Column(
      children: [
        // 1. текущий пользователь — открывает настройки
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
          child: Plate(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            onTap: () => showSettings(context),
            child: Row(
              children: [
                UserAvatar(me, size: 36),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        me?.name ?? '—',
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        _status(),
                        style: TextStyle(fontSize: 12, color: mutedOf(context)),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Icon(Icons.settings_outlined, size: 20, color: mutedOf(context)),
              ],
            ),
          ),
        ),
        // 2. режим отображения (без сервера все задачи свои)
        if (!repo.isLocal)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(value: 'all', label: Text('Все задачи')),
                  ButtonSegment(value: 'mine', label: Text('Только свои')),
                ],
                selected: {repo.viewMode},
                onSelectionChanged: (s) => repo.setSetting('view_mode', s.first),
              ),
            ),
          ),
        // 3. поиск
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: TextField(
            controller: _search,
            decoration: InputDecoration(
              hintText: 'Поиск',
              prefixIcon: const Icon(Icons.search, size: 20),
              prefixIconConstraints: const BoxConstraints(minWidth: 38),
              suffixIcon: app.query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _search.clear();
                        app.setQuery('');
                      },
                    ),
            ),
            onChanged: app.setQuery,
            onSubmitted: (_) => widget.onNavigate?.call(),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
            children: [
              // 4. разделы
              _item(context, secToday, Icons.wb_sunny_outlined, 'Сегодняшний день'),
              _item(context, secImportant, Icons.star_border, 'Важные'),
              _item(context, secPlanned, Icons.calendar_month_outlined, 'Запланировано'),
              _item(context, secTasks, Icons.home_outlined, 'Задачи'),
              if (!repo.isLocal) _item(context, secPrivate, Icons.lock_outline, 'Мои дела'),
              const Padding(padding: EdgeInsets.symmetric(vertical: 6, horizontal: 8), child: Divider()),
              // 5. пользовательские списки
              // порядок меняется перетаскиванием: зажать список и потянуть
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: lists.length,
                onReorder: (from, to) => repo.moveList(from, to > from ? to - 1 : to),
                proxyDecorator: (child, _, _) => Material(color: cs.surface, elevation: 4, borderRadius: BorderRadius.circular(10), child: child),
                itemBuilder: (context, i) => ReorderableDelayedDragStartListener(key: ValueKey(lists[i].id), index: i, child: _listItem(context, lists[i])),
              ),
              ListTile(
                leading: Icon(Icons.add, color: cs.primary),
                title: Text('Создать список', style: TextStyle(color: cs.primary)),
                onTap: () => _createList(context),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _status() {
    if (app.repo.isLocal) return 'Без сервера · настройки';
    if (app.repo.detached) return 'Пользователь удалён · автономно';
    switch (app.sync.state) {
      case SyncState.offline:
        return 'Нет связи · изменения сохранены';
      case SyncState.running:
        return 'Синхронизация…';
      default:
        return app.repo.adminMode ? 'Режим администратора' : 'Настройки';
    }
  }

  Widget _item(BuildContext context, String id, IconData icon, String title, {Widget? trailing, VoidCallback? onLong}) {
    final cs = Theme.of(context).colorScheme;
    final selected = app.section == id && app.query.isEmpty;
    final count = app.repo.openCount(id);
    return ListTile(
      selected: selected,
      selectedTileColor: cs.primary.withValues(alpha: 0.13),
      leading: Icon(icon, size: 20, color: selected ? cs.primary : mutedOf(context)),
      title: Text(
        title,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 14, fontWeight: selected ? FontWeight.w600 : FontWeight.w400, color: cs.onSurface),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailing != null) trailing,
          if (count > 0)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text('$count', style: TextStyle(fontSize: 12, color: mutedOf(context))),
            ),
        ],
      ),
      onTap: () => _go(id),
      onLongPress: onLong,
    );
  }

  Widget _listItem(BuildContext context, Ent l) {
    final repo = app.repo;
    final a = repo.user(l.s('assignee_id'));
    final menu = repo.canEdit(l) ? () => _listMenu(context, l) : null;
    return GestureDetector(
      onSecondaryTap: menu,
      child: _item(
        context,
        l.id,
        Icons.list_alt_outlined,
        l.name.isEmpty ? 'Без названия' : l.name,
        trailing: a == null ? null : Tooltip(message: 'Исполнитель: ${a.name}', child: UserAvatar(a, size: 20)),
      ),
    );
  }

  Future<void> _createList(BuildContext context) async {
    final r = await showDialog<(String, String)>(context: context, builder: (_) => const ListDialog());
    if (r == null || r.$1.trim().isEmpty) return;
    final l = await app.repo.createList(r.$1.trim(), r.$2);
    _go(l.id);
  }

  Future<void> _listMenu(BuildContext context, Ent l) => showListMenu(context, l);
}

/// Действия со списком: переименовать, сменить исполнителя, удалить (доступны создателю списка).
Future<void> showListMenu(BuildContext context, Ent l) async {
  final repo = app.repo;
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Изменить название и исполнителя'), onTap: () => Navigator.pop(c, 'edit')),
          ListTile(leading: const Icon(Icons.home_outlined), title: const Text('Сделать основным списком'), onTap: () => Navigator.pop(c, 'home')),
          ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Удалить список'), onTap: () => Navigator.pop(c, 'delete')),
        ],
      ),
    ),
  );
  if (!context.mounted) return;
  if (action == 'home') {
    await repo.setSetting('home_list', l.id);
  } else if (action == 'edit') {
    final r = await showDialog<(String, String)>(
      context: context,
      builder: (_) => ListDialog(list: l),
    );
    if (r == null) return;
    if (r.$1.trim().isNotEmpty && r.$1.trim() != l.name) await repo.renameList(l, r.$1.trim());
    if (r.$2 != l.s('assignee_id')) await repo.setListAssignee(l, r.$2);
  } else if (action == 'delete') {
    final n = repo.tasks.values.where((t) => t.listId == l.id && !t.deleted).length;
    String? choice = 'move';
    if (n > 0) {
      choice = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('Удалить список «${l.name}»?'),
          content: const Text('Удалить задачи или переместить в общий раздел?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Отмена')),
            TextButton(onPressed: () => Navigator.pop(c, 'delete'), child: const Text('Удалить задачи')),
            FilledButton(onPressed: () => Navigator.pop(c, 'move'), child: const Text('Переместить')),
          ],
        ),
      );
    } else if (!await confirm(context, 'Удалить список «${l.name}»?')) {
      choice = null;
    }
    if (choice == null) return;
    if (app.section == l.id) app.openSection(secToday);
    await repo.deleteList(l, deleteTasks: choice == 'delete');
  }
}

/// Создание и правка списка: название и необязательный исполнитель.
class ListDialog extends StatefulWidget {
  final Ent? list;
  const ListDialog({super.key, this.list});
  @override
  State<ListDialog> createState() => _ListDialogState();
}

class _ListDialogState extends State<ListDialog> {
  late final _name = TextEditingController(text: widget.list?.name ?? '');
  late String _assignee = widget.list?.s('assignee_id') ?? '';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.list == null ? 'Новый список' : 'Список'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Название'),
              onSubmitted: (_) => Navigator.pop(context, (_name.text, _assignee)),
            ),
            // исполнитель списка — только при совместной работе на сервере
            if (!app.repo.isLocal) ...[
              const SizedBox(height: 12),
              SelectField(
                label: 'Исполнитель списка',
                text: app.repo.user(_assignee)?.name ?? 'Без исполнителя',
                leading: app.repo.user(_assignee) == null ? null : UserAvatar(app.repo.user(_assignee), size: 22),
                onTap: () async {
                  final v = await pickOption<String>(
                    context,
                    title: 'Исполнитель списка',
                    current: app.repo.user(_assignee) == null ? '' : _assignee,
                    options: [
                      const Option('', 'Без исполнителя', leading: SizedBox(width: 28, height: 28, child: Icon(Icons.person_off_outlined, size: 20))),
                      for (final u in app.repo.users) Option(u.id, u.name, leading: UserAvatar(u, size: 28)),
                    ],
                  );
                  if (v != null) setState(() => _assignee = v);
                },
              ),
              if (_assignee.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('Все задачи списка ставятся на этого исполнителя.', style: TextStyle(fontSize: 12, color: mutedOf(context))),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(context, (_name.text, _assignee)), child: Text(widget.list == null ? 'Создать' : 'Сохранить')),
      ],
    );
  }
}
