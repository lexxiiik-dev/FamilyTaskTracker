// Центральная колонка: задачи выбранного раздела, блок «Завершённые», быстрое добавление.
import 'package:flutter/material.dart';

import '../core/model.dart';
import '../core/repo.dart';
import 'common.dart';
import 'sidebar.dart';

class TaskListPane extends StatefulWidget {
  final VoidCallback? onMenu;
  const TaskListPane({super.key, this.onMenu});
  @override
  State<TaskListPane> createState() => _TaskListPaneState();
}

class _TaskListPaneState extends State<TaskListPane> {
  bool _showDone = true; // блок «Завершённые» по умолчанию развёрнут

  @override
  Widget build(BuildContext context) => Live(builder: _build);

  Widget _build(BuildContext context) {
    final repo = app.repo;
    final searching = app.query.trim().isNotEmpty;
    final section = app.section;
    final all = searching ? repo.search(app.query) : repo.tasksOf(section);
    final ids = {for (final t in all) t.id};
    // верхний уровень: задачи без основной или те, чья основная в этот раздел не попала
    bool top(Ent t) => t.parentId.isEmpty || !ids.contains(t.parentId);
    final open = all.where((t) => !t.done && top(t)).toList();
    final done = all.where((t) => t.done && top(t)).toList()..sort((a, b) => b.completedAt.compareTo(a.completedAt));

    final rows = <Widget>[];
    void addTask(Ent t, {bool flat = false}) {
      rows.add(TaskRow(task: t, showList: searching || section == secToday || section == secImportant || section == secPrivate));
      if (flat) return;
      for (final c in repo.children(t.id)) {
        rows.add(TaskRow(task: c, indent: true));
      }
    }

    for (final t in open) {
      addTask(t);
    }
    if (done.isNotEmpty) {
      rows.add(
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _showDone = !_showDone),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
            child: Row(
              children: [
                Icon(_showDone ? Icons.expand_more : Icons.chevron_right, size: 20, color: mutedOf(context)),
                const SizedBox(width: 4),
                Text(
                  'Завершённые',
                  style: TextStyle(fontWeight: FontWeight.w600, color: mutedOf(context)),
                ),
                const SizedBox(width: 8),
                Text('${done.length}', style: TextStyle(color: mutedOf(context))),
              ],
            ),
          ),
        ),
      );
      if (_showDone) {
        for (final t in done) {
          addTask(t);
        }
      }
    }

    final list = repo.lists[section];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
          child: Row(
            children: [
              if (widget.onMenu != null) IconButton(icon: const Icon(Icons.menu), onPressed: widget.onMenu),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      searching ? 'Поиск: ${app.query.trim()}' : app.sectionTitle(section),
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (!searching && section == secToday)
                      Text(
                        humanDate(repo.today, repo.today) == 'Сегодня' ? _longDate(repo.today) : '',
                        style: TextStyle(fontSize: 13, color: mutedOf(context)),
                      ),
                    if (!searching && list != null && repo.user(list.s('assignee_id')) != null)
                      Text('Исполнитель: ${repo.userName(list.s('assignee_id'))}', style: TextStyle(fontSize: 13, color: mutedOf(context))),
                  ],
                ),
              ),
              if (!searching && list != null && repo.canEdit(list))
                Builder(
                  builder: (c) => IconButton(
                    icon: const Icon(Icons.more_horiz),
                    tooltip: 'Список',
                    onPressed: () {
                      final b = c.findRenderObject() as RenderBox;
                      showListMenu(context, list, at: b.localToGlobal(b.size.bottomLeft(Offset.zero)));
                    },
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Text(searching ? 'Ничего не найдено' : 'Задач нет', style: TextStyle(color: mutedOf(context))),
                )
              : ListView.builder(padding: const EdgeInsets.fromLTRB(10, 4, 10, 10), itemCount: rows.length, itemBuilder: (_, i) => rows[i]),
        ),
        if (!searching) QuickAdd(key: ValueKey('qa:$section')),
      ],
    );
  }

  String _longDate(String date) {
    final d = parseDate(date);
    const wd = ['понедельник', 'вторник', 'среда', 'четверг', 'пятница', 'суббота', 'воскресенье'];
    return '${wd[d.weekday - 1]}, ${d.day} ${monthsGen[d.month - 1]}';
  }
}


/// Попытка закрыть/переоткрыть задачу с проверкой прав и открытых подзадач.
Future<void> toggleDone(BuildContext context, Ent t) async {
  final repo = app.repo;
  if (!t.done) {
    final why = repo.closeBlocker(t);
    if (why != null) {
      toast(context, why);
      return;
    }
  }
  await repo.setDone(t, !t.done);
}

class TaskRow extends StatelessWidget {
  final Ent task;
  final bool indent;
  final bool showList;
  const TaskRow({super.key, required this.task, this.indent = false, this.showList = false});

  @override
  Widget build(BuildContext context) {
    final repo = app.repo;
    final cs = Theme.of(context).colorScheme;
    final t = task;
    final selected = app.taskId == t.id;
    final muted = mutedOf(context);
    final meta = <InlineSpan>[];
    void add(String s, {Color? color, IconData? icon}) {
      if (meta.isNotEmpty)
        meta.add(
          TextSpan(
            text: '  ·  ',
            style: TextStyle(color: muted),
          ),
        );
      if (icon != null) {
        meta.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.only(right: 3),
              child: Icon(icon, size: 13, color: color ?? muted),
            ),
          ),
        );
      }
      meta.add(
        TextSpan(
          text: s,
          style: TextStyle(color: color ?? muted),
        ),
      );
    }

    if (showList && t.listId.isNotEmpty) add(repo.lists[t.listId]?.name ?? '');
    // ближайший пункт планирования (и сколько их ещё)
    final next = repo.nextPlan(t);
    if (next != null) {
      final more = t.plans.length - 1;
      final label = next.timed ? '${humanDate(next.date, repo.today)}, ${fmtMin(next.from)}' : humanDate(next.date, repo.today);
      add(
        more > 0 ? '$label +$more' : label,
        color: repo.overdue(t) ? cs.error : (next.date == repo.today && !t.done ? cs.primary : null),
        icon: next.timed ? Icons.schedule : Icons.event_outlined,
      );
      if (t.plans.any((p) => p.notify)) add('', icon: Icons.notifications_none);
    }
    if (t.recurrence != null) add('', icon: Icons.repeat);
    final cl = t.checklist;
    if (cl.isNotEmpty) add('${cl.where((c) => c['done'] == true).length}/${cl.length}', icon: Icons.checklist);
    if (!t.isPrivate && t.assigneeId != repo.me) add(repo.userName(t.assigneeId), icon: Icons.person_outline);
    if (t.description.isNotEmpty) add('', icon: Icons.notes);

    return Padding(
      padding: EdgeInsets.only(left: indent ? 28 : 0, bottom: 5),
      child: Plate(
        color: selected ? Color.lerp(cs.surface, cs.primary, 0.10) : null,
        padding: const EdgeInsets.fromLTRB(4, 3, 4, 3),
        onTap: () => app.openTask(t.id),
        child: Row(
          children: [
            RoundCheck(value: t.done, onTap: repo.canToggle(t) ? () => toggleDone(context, t) : null),
            const SizedBox(width: 4),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        // приватные задачи визуально обособлены замком
                        if (t.isPrivate)
                          Padding(
                            padding: const EdgeInsets.only(right: 5),
                            child: Icon(Icons.lock_outline, size: 14, color: cs.primary),
                          ),
                        Flexible(
                          child: Text(
                            t.title.isEmpty ? 'Без названия' : t.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 14.5, decoration: t.done ? TextDecoration.lineThrough : null, color: t.done ? muted : cs.onSurface),
                          ),
                        ),
                      ],
                    ),
                    if (meta.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text.rich(
                          TextSpan(children: meta),
                          style: const TextStyle(fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(t.important ? Icons.star : Icons.star_border, size: 20, color: t.important ? cs.primary : muted),
              onPressed: repo.canEdit(t) ? () => repo.setTaskField(t, 'is_important', !t.important) : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// Поле быстрого добавления: приватность, дата, переход в полную форму.
class QuickAdd extends StatefulWidget {
  const QuickAdd({super.key});
  @override
  State<QuickAdd> createState() => _QuickAddState();
}

class _QuickAddState extends State<QuickAdd> {
  final _c = TextEditingController();
  final _focus = FocusNode();
  bool _private = false;
  String _date = ''; // день пункта планирования без времени

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _listId => app.repo.lists.containsKey(app.section) ? app.section : '';

  Future<Ent?> _draft() async {
    return app.draftForSection(title: _c.text.trim(), private: _private, date: _date);

  }

  Future<void> _submit() async {
    if (_c.text.trim().isEmpty) return;
    final d = await _draft();
    if (d == null) return;
    await app.repo.addTask(d);
    _c.clear();
    setState(() => _date = '');
    _focus.requestFocus();
  }

  Future<void> _full() async {
    final d = await _draft();
    if (d == null) return;
    _c.clear();
    setState(() => _date = '');
    app.startDraft(d);
  }

  @override
  Widget build(BuildContext context) => Live(builder: _build);

  Widget _build(BuildContext context) {
    final repo = app.repo;
    final cs = Theme.of(context).colorScheme;
    final allowed = repo.privateAllowed(_listId);
    final forced = app.section == secPrivate; // в «Моих делах» все новые задачи приватные
    final private = (_private || forced) && allowed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: Plate(
        padding: const EdgeInsets.fromLTRB(2, 2, 4, 2),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Добавить задачу',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.add, color: cs.primary, size: 22),
              onPressed: () {
                if (_c.text.trim().isEmpty) {
                  _focus.requestFocus();
                } else {
                  _submit();
                }
              },
            ),
            const SizedBox(width: 2),
            Expanded(
              child: TextField(
                controller: _c,
                focusNode: _focus,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  hintText: 'Добавить задачу',
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                ),
                onSubmitted: (_) => _submit(),
              ),
            ),
            if (_date.isNotEmpty)
              InputChip(
                label: Text(humanDate(_date, repo.today), style: const TextStyle(fontSize: 12)),
                visualDensity: VisualDensity.compact,
                onDeleted: () => setState(() => _date = ''),
              ),
            if (!repo.isLocal)
              IconButton(
                tooltip: allowed ? (private ? 'Приватная задача' : 'Общая задача') : 'В этом списке приватные задачи недоступны',
                visualDensity: VisualDensity.compact,
                icon: Icon(private ? Icons.lock : Icons.lock_open_outlined, size: 20, color: private ? cs.primary : null),
                onPressed: (allowed && !forced) ? () => setState(() => _private = !_private) : null,
              ),
            IconButton(
              tooltip: 'Запланировать на день',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.event_outlined, size: 20),
              onPressed: () async {
                final d = await pickDate(context, _date, repo.today);
                if (d != null) setState(() => _date = d);
              },
            ),
            IconButton(tooltip: 'Полная форма', visualDensity: VisualDensity.compact, icon: const Icon(Icons.open_in_full, size: 18), onPressed: _full),
          ],
        ),
      ),
    );
  }
}
