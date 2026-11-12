// Правая колонка: карточка задачи. Полная форма создания выглядит так же (isDraft).
import 'package:flutter/material.dart';

import '../core/model.dart';
import 'common.dart';
import 'task_list.dart';

class TaskEditor extends StatefulWidget {
  final Ent task;
  final bool isDraft;
  const TaskEditor({super.key, required this.task, required this.isDraft});
  @override
  State<TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<TaskEditor> {
  late final _title = TextEditingController(text: widget.task.title);
  late final _desc = TextEditingController(text: widget.task.description);
  final _newSub = TextEditingController();
  final _titleFocus = FocusNode(), _descFocus = FocusNode();

  Ent get t => widget.task;

  @override
  void initState() {
    super.initState();
    _titleFocus.addListener(() {
      if (!_titleFocus.hasFocus) _commitTitle();
    });
    _descFocus.addListener(() {
      if (!_descFocus.hasFocus) _commitDesc();
    });
  }

  @override
  void dispose() {
    // несохранённый текст не теряется при закрытии карточки
    if (!widget.isDraft && app.repo.tasks.containsKey(t.id) && !t.deleted && app.repo.canEdit(t)) {
      if (_title.text.trim().isNotEmpty && _title.text.trim() != t.title) app.repo.setTaskField(t, 'title', _title.text.trim());
      if (_desc.text != t.description) app.repo.setTaskField(t, 'description', _desc.text);
    }
    for (final c in [_title, _desc, _newSub]) {
      c.dispose();
    }
    _titleFocus.dispose();
    _descFocus.dispose();
    super.dispose();
  }

  void _commitTitle() {
    final v = _title.text.trim();
    if (v.isEmpty && !widget.isDraft) {
      _title.text = t.title;
      return;
    }
    if (v != t.title) app.repo.setTaskField(t, 'title', v);
  }

  void _commitDesc() {
    if (_desc.text != t.description) app.repo.setTaskField(t, 'description', _desc.text);
  }

  Future<void> _set(String k, dynamic v) => app.repo.setTaskField(t, k, v);

  @override
  Widget build(BuildContext context) => Live(builder: _build);

  Widget _build(BuildContext context) {
    final repo = app.repo;
    final cs = Theme.of(context).colorScheme;
    final muted = mutedOf(context);
    final draft = widget.isDraft;
    final edit = draft || repo.canEdit(t);
    final toggle = draft || repo.canToggle(t);
    final parent = repo.tasks[t.parentId];
    final list = repo.lists[t.listId];
    final listAssignee = list?.s('assignee_id') ?? '';
    final assignee = repo.user(t.assigneeId);
    // синхронизация могла принести новый текст, пока поле не редактируется
    if (!_titleFocus.hasFocus && _title.text != t.title && !draft) _title.text = t.title;
    if (!_descFocus.hasFocus && _desc.text != t.description && !draft) _desc.text = t.description;

    final items = <Widget>[
      // название и галочка завершения, важность
      Plate(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
        child: Row(
          children: [
            RoundCheck(value: t.done, onTap: (!draft && toggle) ? () => toggleDone(context, t) : null),
            Expanded(
              child: TextField(
                controller: _title,
                focusNode: _titleFocus,
                autofocus: draft && t.title.isEmpty,
                readOnly: !edit,
                maxLines: null,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, decoration: t.done ? TextDecoration.lineThrough : null),
                decoration: const InputDecoration(
                  hintText: 'Название задачи',
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
                onSubmitted: (_) => _commitTitle(),
              ),
            ),
            IconButton(
              icon: Icon(t.important ? Icons.star : Icons.star_border, color: t.important ? cs.primary : muted),
              onPressed: edit ? () => _set('is_important', !t.important) : null,
            ),
          ],
        ),
      ),
      // описание и чек-лист — сразу под названием
      if (edit || t.description.isNotEmpty)
        TextField(
          controller: _desc,
          focusNode: _descFocus,
          readOnly: !edit,
          minLines: edit ? 3 : 1,
          maxLines: 10,
          decoration: const InputDecoration(hintText: 'Описание'),
        ),
      // в чужой задаче, которую нельзя править, пустой чек-лист не показывается
      if (edit || t.checklist.isNotEmpty) _Checklist(items: t.checklist, edit: edit, onChanged: (l) => _set('checklist', l)),
      if (parent != null) _Row(icon: Icons.subdirectory_arrow_right, title: 'Подзадача: ${parent.title}', onTap: draft ? null : () => app.openTask(parent.id)),

      // приватность и исполнитель — только при совместной работе на сервере
      // приватность: задаётся при создании и больше не меняется
      if (!repo.isLocal)
        if (draft && parent == null)
          _Row(
            icon: t.isPrivate ? Icons.lock : Icons.lock_open_outlined,
            title: 'Приватная задача',
            subtitle: repo.privateAllowed(t.listId) ? 'Видна только вам' : 'В этом списке недоступно: у него другой исполнитель',
            active: t.isPrivate,
            trailing: Switch(
              value: t.isPrivate,
              onChanged: repo.privateAllowed(t.listId)
                  ? (v) {
                      t.isPrivate = v;
                      if (v) repo.setTaskField(t, 'assignee_id', repo.me);
                      setState(() {});
                    }
                  : null,
            ),
          )
        else
          _Row(
            icon: t.isPrivate ? Icons.lock : Icons.group_outlined,
            title: t.isPrivate ? 'Приватная задача' : 'Общая задача',
            subtitle: t.isPrivate ? 'Видна только автору' : 'Автор: ${repo.userName(t.creatorId)}',
            active: t.isPrivate,
          ),

      // исполнитель (если задача общая и исполнитель не задан списком)
      if (!t.isPrivate && !repo.isLocal)
        _Row(
          icon: Icons.person_outline,
          title: 'Исполнитель: ${assignee?.name ?? '—'}',
          subtitle: listAssignee.isNotEmpty ? 'Задан списком' : null,
          leading: UserAvatar(assignee, size: 22),
          onTap: (edit && listAssignee.isEmpty) ? () => _pickAssignee(context) : null,
        ),

      // список
      _Row(
        icon: Icons.list_alt_outlined,
        title: list == null ? 'Без списка' : 'Список: ${list.name}',
        subtitle: parent != null ? 'Как у основной задачи' : null,
        onTap: (edit && parent == null) ? () => _pickList(context) : null,
      ),

      _Row(
        icon: Icons.wb_sunny_outlined,
        title: t.inToday ? 'Добавлено в «Сегодня»' : 'Добавить в «Сегодня»',
        active: t.inToday,
        onTap: toggle ? () => _set('in_today', !t.inToday) : null,
        trailing: t.inToday && toggle ? IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => _set('in_today', false)) : null,
      ),

      // дедлайн, напоминание, повторение
      Plate(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            _Row(
              flat: true,
              icon: Icons.event_outlined,
              title: t.deadline.isEmpty ? 'Добавить срок' : 'Срок: ${humanDate(t.deadline, repo.today)}',
              active: t.deadline.isNotEmpty,
              danger: repo.overdue(t),
              onTap: edit
                  ? () async {
                      final d = await pickDate(context, t.deadline, repo.today);
                      if (d != null) _set('deadline', d);
                    }
                  : null,
              trailing: t.deadline.isNotEmpty && edit ? IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => _set('deadline', '')) : null,
            ),
            const Divider(indent: 44),
            _Row(
              flat: true,
              icon: Icons.notifications_none,
              title: t.reminderAt == 0 ? 'Напомнить' : 'Напомнить: ${reminderLabel(repo, t.reminderAt)}',
              active: t.reminderAt > 0,
              onTap: edit ? () => _pickReminder(context) : null,
              trailing: t.reminderAt > 0 && edit ? IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => _set('reminder_at', 0)) : null,
            ),
            const Divider(indent: 44),
            _Row(
              flat: true,
              icon: Icons.repeat,
              title: t.recurrence == null ? 'Повторять' : describeRecurrence(t.recurrence),
              subtitle: t.deadline.isEmpty ? 'Для повторения нужен срок' : (parent != null ? 'Только для основных задач' : null),
              active: t.recurrence != null,
              onTap: (edit && t.deadline.isNotEmpty && parent == null) ? () => _pickRecurrence(context) : null,
              trailing: t.recurrence != null && edit ? IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => _set('recurrence', null)) : null,
            ),
          ],
        ),
      ),

      // подзадачи: быстрое добавление с переходом в полную форму
      if (!draft && parent == null) ...[
        Padding(
          padding: const EdgeInsets.only(left: 4, top: 4),
          child: Text(
            'Подзадачи',
            style: TextStyle(fontWeight: FontWeight.w600, color: muted),
          ),
        ),
        for (final c in repo.children(t.id)) TaskRow(task: c),
        Plate(
          padding: const EdgeInsets.fromLTRB(2, 0, 4, 0),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Добавить подзадачу',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.add, size: 20, color: cs.primary),
                onPressed: () async {
                  final v = _newSub.text.trim();
                  if (v.isEmpty) return;
                  await repo.addTask(repo.draftTask(title: v, parentId: t.id));
                  _newSub.clear();
                },
              ),
              const SizedBox(width: 2),
              Expanded(
                child: TextField(
                  controller: _newSub,
                  decoration: const InputDecoration(
                    hintText: 'Добавить подзадачу',
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                  onSubmitted: (v) async {
                    if (v.trim().isEmpty) return;
                    await repo.addTask(repo.draftTask(title: v.trim(), parentId: t.id));
                    _newSub.clear();
                  },
                ),
              ),
              IconButton(
                tooltip: 'Полная форма',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.open_in_full, size: 18),
                onPressed: () {
                  final d = repo.draftTask(title: _newSub.text.trim(), parentId: t.id);
                  _newSub.clear();
                  app.startDraft(d);
                },
              ),
            ],
          ),
        ),
      ],
    ];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Row(
            children: [
              IconButton(icon: const Icon(Icons.arrow_back), tooltip: 'Закрыть', onPressed: app.closeTask),
              Expanded(
                child: Text(draft ? 'Новая задача' : 'Задача', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
              ),
              if (!draft && edit)
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Удалить',
                  onPressed: () async {
                    final kids = repo.children(t.id).length;
                    if (!await confirm(context, 'Удалить задачу?', text: kids > 0 ? 'Вместе с ней удалятся подзадачи: $kids.' : null)) return;
                    app.closeTask();
                    await repo.deleteTask(t);
                  },
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(10),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (_, i) => items[i],
          ),
        ),
        if (draft)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(onPressed: app.closeTask, child: const Text('Отмена')),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: () async {
                      final title = _title.text.trim();
                      if (title.isEmpty) {
                        toast(context, 'Введите название задачи');
                        return;
                      }
                      await repo.setTaskField(t, 'title', title);
                      await repo.setTaskField(t, 'description', _desc.text);
                      if (app.section == 'planned' && t.deadline.isEmpty && context.mounted) {
                        toast(context, 'В «Запланировано» у задачи должен быть срок');
                        return;
                      }
                      final saved = await repo.addTask(t);
                      app.openTask(saved.id);
                    },
                    child: const Text('Добавить задачу'),
                  ),
                ),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: Text(
              t.done
                  ? 'Завершена ${humanDate(repo.dateOfMoment(t.completedAt), repo.today).toLowerCase()}'
                  : 'Создана ${humanDate(repo.dateOfMoment(t.createdAt), repo.today).toLowerCase()}',
              style: TextStyle(fontSize: 12, color: muted),
            ),
          ),
      ],
    );
  }

  Future<void> _pickAssignee(BuildContext context) async {
    final repo = app.repo;
    final uid = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Исполнитель'),
        children: [
          for (final u in repo.users)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, u.id),
              child: Row(
                children: [
                  UserAvatar(u, size: 28),
                  const SizedBox(width: 12),
                  Text(u.name),
                  if (u.id == t.assigneeId) ...[const Spacer(), const Icon(Icons.check, size: 18)],
                ],
              ),
            ),
        ],
      ),
    );
    if (uid != null) _set('assignee_id', uid); // тэг при смене исполнителя сбрасывается
  }

  Future<void> _pickList(BuildContext context) async {
    final repo = app.repo;
    // приватную задачу можно положить только в список без исполнителя или со «своим» исполнителем
    final options = repo.visibleLists.where((l) => !t.isPrivate || l.s('assignee_id').isEmpty || l.s('assignee_id') == t.creatorId).toList();
    final id = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Список'),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(c, ''), child: const Text('Без списка (раздел «Задачи»)')),
          for (final l in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, l.id),
              child: Text(l.s('assignee_id').isEmpty ? l.name : '${l.name} · ${repo.userName(l.s('assignee_id'))}'),
            ),
        ],
      ),
    );
    if (id != null) _set('list_id', id);
  }

  Future<void> _pickReminder(BuildContext context) async {
    final repo = app.repo;
    final cur = t.reminderAt > 0 ? repo.localOf(t.reminderAt) : null;
    final date = await pickDate(context, cur == null ? (t.deadline.isEmpty ? repo.today : t.deadline) : fmtDate(cur), repo.today);
    if (date == null || !context.mounted) return;
    final time = await pickTime(context, cur == null ? repo.deadlineTime : fmtTime(cur.hour, cur.minute));
    if (time == null) return;
    _set('reminder_at', repo.momentOf(date, time));
  }

  Future<void> _pickRecurrence(BuildContext context) async {
    final r = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => RecurrenceDialog(initial: t.recurrence, deadline: t.deadline),
    );
    if (r != null) _set('recurrence', r);
  }
}

class _Row extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? leading;
  final VoidCallback? onTap;
  final bool active, danger, flat;
  const _Row({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.leading,
    this.onTap,
    this.active = false,
    this.danger = false,
    this.flat = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = danger ? cs.error : (active ? cs.primary : cs.onSurface);
    final row = Row(
      children: [
        SizedBox(
          width: 24,
          child: Center(child: leading ?? Icon(icon, size: 20, color: danger ? cs.error : (active ? cs.primary : mutedOf(context)))),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(color: color, fontSize: 14),
                overflow: TextOverflow.ellipsis,
              ),
              if (subtitle != null) Text(subtitle!, style: TextStyle(fontSize: 12, color: mutedOf(context))),
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
    const pad = EdgeInsets.symmetric(horizontal: 10, vertical: 10);
    if (flat)
      return InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 46),
          child: Padding(padding: pad, child: row),
        ),
      );
    return Plate(
      padding: pad,
      onTap: onTap,
      child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 26), child: row),
    );
  }
}

/// Чек-лист: круглые галочки, правка пункта по нажатию на текст, порядок меняется перетаскиванием за ручку.
class _Checklist extends StatefulWidget {
  final List<Map<String, dynamic>> items;
  final bool edit;
  final void Function(List<Map<String, dynamic>>) onChanged;
  const _Checklist({required this.items, required this.edit, required this.onChanged});
  @override
  State<_Checklist> createState() => _ChecklistState();
}

class _ChecklistState extends State<_Checklist> {
  final _new = TextEditingController(), _editC = TextEditingController();
  final _newFocus = FocusNode(), _editFocus = FocusNode();
  int _editing = -1;

  static const _bare = InputDecoration(
    filled: false,
    isDense: true,
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    contentPadding: EdgeInsets.symmetric(vertical: 8),
  );

  @override
  void initState() {
    super.initState();
    _editFocus.addListener(() {
      if (!_editFocus.hasFocus && _commitEdit() != null && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _commitEdit(); // незавершённая правка не теряется при закрытии карточки
    for (final c in [_new, _editC]) {
      c.dispose();
    }
    _newFocus.dispose();
    _editFocus.dispose();
    super.dispose();
  }

  void _change(void Function(List<Map<String, dynamic>>) fn) {
    final l = [for (final m in widget.items) Map<String, dynamic>.of(m)];
    fn(l);
    widget.onChanged(l);
  }

  /// Сохраняет правку пункта. Возвращает null, если ничего не редактировалось, иначе true — пункт удалён (текст стёрт).
  bool? _commitEdit() {
    final i = _editing;
    if (i < 0) return null;
    _editing = -1;
    if (i >= widget.items.length) return false;
    final v = _editC.text.trim();
    if (v.isEmpty) {
      _change((l) => l.removeAt(i));
      return true;
    }
    if (v != widget.items[i]['text']) _change((l) => l[i] = {'text': v, 'done': l[i]['done'] == true});
    return false;
  }

  void _startEdit(int i) {
    final prev = _editing;
    final removed = _commitEdit() == true;
    if (removed && prev < i) i--;
    if (removed && prev == i) return;
    _editC.text = (widget.items[i]['text'] ?? '').toString();
    setState(() => _editing = i);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing == i) _editFocus.requestFocus();
    });
  }

  void _add() {
    final v = _new.text.trim();
    if (v.isNotEmpty) {
      _change((l) => l.add({'text': v, 'done': false}));
      _new.clear();
    }
    _newFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final muted = mutedOf(context);
    final items = widget.items;
    final edit = widget.edit;
    if (_editing >= items.length) _editing = -1;
    return Plate(
      padding: const EdgeInsets.fromLTRB(2, 4, 4, 4),
      child: Column(
        children: [
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: items.length,
            onReorder: (from, to) {
              _commitEdit();
              if (to > from) to--;
              if (to != from) _change((l) => l.insert(to, l.removeAt(from)));
            },
            itemBuilder: (context, i) {
              final c = items[i];
              final done = c['done'] == true;
              return Row(
                key: ValueKey('cl-$i'),
                children: [
                  RoundCheck(value: done, size: 18, onTap: edit ? () => _change((l) => l[i] = {'text': l[i]['text'], 'done': !done}) : null),
                  Expanded(
                    child: _editing == i
                        ? TextField(
                            controller: _editC,
                            focusNode: _editFocus,
                            maxLines: null,
                            textInputAction: TextInputAction.done,
                            style: const TextStyle(fontSize: 14),
                            decoration: _bare,
                            onSubmitted: (_) {
                              _commitEdit();
                              setState(() {});
                            },
                          )
                        : InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: edit ? () => _startEdit(i) : null,
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Text(
                                (c['text'] ?? '').toString(),
                                style: TextStyle(fontSize: 14, decoration: done ? TextDecoration.lineThrough : null, color: done ? muted : null),
                              ),
                            ),
                          ),
                  ),
                  if (edit)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Удалить пункт',
                      icon: Icon(Icons.close, size: 16, color: muted),
                      onPressed: () {
                        _editing = -1;
                        _change((l) => l.removeAt(i));
                      },
                    ),
                  if (edit && items.length > 1)
                    ReorderableDragStartListener(
                      index: i,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(2, 8, 6, 8),
                          child: Icon(Icons.drag_indicator, size: 18, color: muted),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          if (edit)
            Row(
              children: [
                IconButton(
                  tooltip: 'Добавить пункт',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.add, size: 20, color: Theme.of(context).colorScheme.primary),
                  onPressed: _add,
                ),
                Expanded(
                  child: TextField(
                    controller: _new,
                    focusNode: _newFocus,
                    style: const TextStyle(fontSize: 14),
                    decoration: _bare.copyWith(hintText: 'Пункт чек-листа'),
                    onSubmitted: (_) => _add(),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Правило повторения: каждый день, по дням недели, каждые N дней/недель/месяцев, ежегодно.
class RecurrenceDialog extends StatefulWidget {
  final Map<String, dynamic>? initial;
  final String deadline;
  const RecurrenceDialog({super.key, this.initial, required this.deadline});
  @override
  State<RecurrenceDialog> createState() => _RecurrenceDialogState();
}

class _RecurrenceDialogState extends State<RecurrenceDialog> {
  late String type = (widget.initial?['type'] ?? 'daily') as String;
  late Set<int> days = ((widget.initial?['days'] as List?) ?? [parseDate(widget.deadline).weekday]).map((e) => (e as num).toInt()).toSet();
  late int n = (widget.initial?['n'] as num?)?.toInt() ?? 2;
  late String unit = (widget.initial?['unit'] ?? 'day') as String;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Повторение'),
      content: SizedBox(
        width: 340,
        child: RadioGroup<String>(
          groupValue: type,
          onChanged: (v) => setState(() => type = v ?? type),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const RadioListTile(value: 'daily', title: Text('Каждый день')),
              const RadioListTile(value: 'weekly', title: Text('По дням недели')),
              if (type == 'weekly')
                Padding(
                  padding: const EdgeInsets.only(left: 16, bottom: 8),
                  child: Wrap(
                    spacing: 4,
                    children: [
                      for (var d = 1; d <= 7; d++)
                        FilterChip(
                          label: Text(weekdaysShort[d - 1]),
                          showCheckmark: false,
                          visualDensity: VisualDensity.compact,
                          selected: days.contains(d),
                          onSelected: (v) => setState(() => v ? days.add(d) : days.remove(d)),
                        ),
                    ],
                  ),
                ),
              const RadioListTile(value: 'interval', title: Text('Каждые N дней, недель или месяцев')),
              if (type == 'interval')
                Padding(
                  padding: const EdgeInsets.only(left: 16, bottom: 8),
                  child: Row(
                    children: [
                      IconButton(icon: const Icon(Icons.remove), onPressed: n > 1 ? () => setState(() => n--) : null),
                      Text('$n', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      IconButton(icon: const Icon(Icons.add), onPressed: n < 365 ? () => setState(() => n++) : null),
                      const SizedBox(width: 8),
                      Flexible(
                        child: SegmentedButton<String>(
                          showSelectedIcon: false,
                          style: const ButtonStyle(visualDensity: VisualDensity.compact, padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 6))),
                          segments: const [
                            ButtonSegment(value: 'day', label: Text('дней')),
                            ButtonSegment(value: 'week', label: Text('недель')),
                            ButtonSegment(value: 'month', label: Text('месяцев')),
                          ],
                          selected: {unit},
                          onSelectionChanged: (v) => setState(() => unit = v.first),
                        ),
                      ),
                    ],
                  ),
                ),
              const RadioListTile(value: 'yearly', title: Text('Ежегодно')),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(
          onPressed: () {
            if (type == 'weekly' && days.isEmpty) return;
            Navigator.pop(context, switch (type) {
              'weekly' => {'type': 'weekly', 'days': days.toList()..sort()},
              'interval' => {'type': 'interval', 'n': n, 'unit': unit},
              _ => {'type': type},
            });
          },
          child: const Text('Готово'),
        ),
      ],
    );
  }
}
