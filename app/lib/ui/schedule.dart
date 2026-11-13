// Пункты планирования задачи и раздел «Планирование»: временная шкала на несколько дней.
// У задачи может быть сколько угодно пунктов: на разные дни, со временем или без времени.
// На шкале пункты переносятся между днями и временем, уводятся в зону «без времени»
// и копируются (зажать карточку на секунду, затем тянуть).
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/model.dart';
import '../core/repo.dart';
import 'common.dart';

const _hourH = 52.0; // высота часа на шкале
const _axisW = 44.0; // ширина колонки с подписями часов
const _snap = 15; // шаг перетаскивания, минут
const copyHold = Duration(seconds: 1); // удержание, после которого перенос становится копированием

int _min(String hhmm) {
  final p = hhmm.split(':');
  return (int.tryParse(p[0]) ?? 0) * 60 + (p.length > 1 ? int.tryParse(p[1]) ?? 0 : 0);
}

/// Цвет карточки задачи: цвет её списка, у задач без списка — акцентный.
Color planColor(BuildContext context, Ent t) {
  final cs = Theme.of(context).colorScheme;
  final c = app.repo.lists[t.listId]?.color ?? '';
  return c.isEmpty ? cs.primary : parseHex(c, cs.primary);
}

/// «Сегодня, 14:00–15:00» или «Завтра, без времени».
String planItemLabel(Repo r, PlanItem p) =>
    p.timed ? '${humanDate(p.date, r.today)}, ${fmtMin(p.from)}–${fmtMin(p.to)}' : '${humanDate(p.date, r.today)}, без времени';

/// Время по умолчанию: ближайший целый час сегодня (или 09:00 в другой день), на час.
PlanItem defaultPlanItem(Repo r, {String date = '', String id = ''}) {
  final today = r.today;
  if (date.isEmpty || date.compareTo(today) < 0) date = today;
  var h = 9;
  if (date == today) h = (r.localOf(r.clock()).hour + 1).clamp(0, 23);
  return PlanItem(id.isEmpty ? r.newPlanId() : id, date, from: h * 60, to: h * 60 + 60);
}

/// Поля пункта: первая строка — день, вторая — время начала и окончания (или «без времени»).
class PlanFields extends StatelessWidget {
  final PlanItem item;
  final ValueChanged<PlanItem> onChanged;
  const PlanFields({super.key, required this.item, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final repo = app.repo;
    final muted = mutedOf(context);
    final p = item;
    Widget chip(String label, IconData icon, VoidCallback onTap, {Key? key}) => Expanded(
          child: OutlinedButton.icon(key: key, onPressed: onTap, icon: Icon(icon, size: 16), label: Text(label, overflow: TextOverflow.ellipsis)),
        );
    Widget row(String caption, List<Widget> children) => Row(children: [
          SizedBox(width: 52, child: Text(caption, style: TextStyle(fontSize: 13, color: muted))),
          ...children,
        ]);
    const dash = Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('—'));
    return Column(mainAxisSize: MainAxisSize.min, children: [
      row('День', [
        chip(humanDate(p.date, repo.today), Icons.event_outlined, () async {
          final d = await pickDate(context, p.date, repo.today);
          if (d != null) onChanged(p.copyWith(date: d));
        }, key: const ValueKey('plan-date')),
      ]),
      const SizedBox(height: 8),
      row('Время', [
        if (p.timed) ...[
          chip(fmtMin(p.from), Icons.schedule, () async {
            final v = await pickTime(context, fmtMin(p.from));
            if (v == null) return;
            // конец сдвигается вместе с началом, длительность сохраняется
            final len = p.to - p.from;
            final f = _min(v).clamp(0, 1440 - _snap);
            onChanged(p.copyWith(from: f, to: (f + len).clamp(f + _snap, 1440)));
          }, key: const ValueKey('plan-from')),
          dash,
          chip(fmtMin(p.to), Icons.schedule, () async {
            final v = await pickTime(context, fmtMin(p.to % 1440));
            if (v == null) return;
            var e = _min(v);
            if (e == 0) e = 1440; // 00:00 — конец дня
            // конец раньше начала — начало отодвигается на час до конца
            onChanged(e > p.from ? p.copyWith(to: e) : p.copyWith(from: (e - 60).clamp(0, 1440), to: e));
          }, key: const ValueKey('plan-to')),
          IconButton(
            key: const ValueKey('plan-untime'),
            tooltip: 'Без времени',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close, size: 18, color: muted),
            onPressed: () => onChanged(p.untimed()),
          ),
        ] else
          Expanded(
            child: OutlinedButton.icon(
              key: const ValueKey('plan-settime'),
              onPressed: () {
                final d = defaultPlanItem(repo, date: p.date);
                onChanged(p.copyWith(from: d.from, to: d.to));
              },
              icon: const Icon(Icons.more_time, size: 16),
              label: const Text('Без времени · указать время'),
            ),
          ),
      ]),
    ]);
  }
}

/// Результат окна пункта: новый вид пункта или удаление.
class PlanEdit {
  final PlanItem? item;
  final bool delete;
  const PlanEdit(this.item, {this.delete = false});
}

Future<PlanEdit?> editPlanItem(BuildContext context, PlanItem initial, {bool isNew = false}) =>
    showDialog<PlanEdit>(context: context, builder: (_) => _PlanItemDialog(initial: initial, isNew: isNew));

class _PlanItemDialog extends StatefulWidget {
  final PlanItem initial;
  final bool isNew;
  const _PlanItemDialog({required this.initial, required this.isNew});
  @override
  State<_PlanItemDialog> createState() => _PlanItemDialogState();
}

class _PlanItemDialogState extends State<_PlanItemDialog> {
  late PlanItem p = widget.initial;

  @override
  Widget build(BuildContext context) {
    final muted = mutedOf(context);
    return AlertDialog(
      title: Text(widget.isNew ? 'Новый пункт планирования' : 'Пункт планирования'),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          PlanFields(item: p, onChanged: (x) => setState(() => p = x)),
          const SizedBox(height: 10),
          SwitchListTile(
            key: const ValueKey('plan-notify'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Включить уведомление'),
            subtitle: p.notify && !p.timed
                ? Text('В ${app.repo.deadlineTime} — стандартное время уведомлений по сегодняшним задачам', style: TextStyle(fontSize: 12, color: muted))
                : null,
            value: p.notify,
            onChanged: (v) => setState(() => p = p.copyWith(notify: v)),
          ),
          if (p.notify && p.timed)
            SelectField(
              key: const ValueKey('plan-before'),
              label: 'Насколько заранее',
              text: _cap(beforeLabel(p.before)),
              onTap: () async {
                final v = await pickOption<int>(context,
                    title: 'Насколько заранее', current: p.before, options: [for (final m in beforeOptions) Option(m, _cap(beforeLabel(m)))]);
                if (v != null) setState(() => p = p.copyWith(before: v));
              },
            ),
        ]),
      ),
      actions: [
        if (!widget.isNew) TextButton(onPressed: () => Navigator.pop(context, const PlanEdit(null, delete: true)), child: const Text('Удалить')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(key: const ValueKey('plan-ok'), onPressed: () => Navigator.pop(context, PlanEdit(p)), child: const Text('Готово')),
      ],
    );
  }
}

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Пункты планирования в карточке задачи: список, правка по нажатию, добавление.
class PlanItemsEditor extends StatelessWidget {
  final Ent task;
  final bool enabled;
  const PlanItemsEditor({super.key, required this.task, required this.enabled});

  @override
  Widget build(BuildContext context) {
    final repo = app.repo;
    final cs = Theme.of(context).colorScheme;
    final muted = mutedOf(context);
    final items = task.plans;
    final rows = <Widget>[];
    for (final p in items) {
      final past = !task.done && p.date.compareTo(repo.today) < 0;
      rows.add(InkWell(
        key: ValueKey('plan-item:${p.id}'),
        onTap: enabled
            ? () async {
                final r = await editPlanItem(context, p);
                if (r == null) return;
                if (r.delete) {
                  await repo.removePlan(task, p.id);
                } else if (r.item != null) {
                  await repo.putPlan(task, r.item!);
                }
              }
            : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 2, 6),
          child: Row(children: [
            SizedBox(width: 24, child: Icon(p.timed ? Icons.schedule : Icons.event_outlined, size: 20, color: past ? cs.error : cs.primary)),
            const SizedBox(width: 12),
            Expanded(child: Text(planItemLabel(repo, p), style: TextStyle(fontSize: 14, color: past ? cs.error : cs.onSurface))),
            if (p.notify)
              Tooltip(
                message: p.timed ? 'Уведомление ${beforeLabel(p.before)}' : 'Уведомление в ${repo.deadlineTime}',
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: Icon(Icons.notifications_active_outlined, size: 18, color: cs.primary)),
              ),
            if (enabled)
              IconButton(
                tooltip: 'Убрать пункт',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.close, size: 18, color: muted),
                onPressed: () => repo.removePlan(task, p.id),
              )
            else
              const SizedBox(width: 8),
          ]),
        ),
      ));
      rows.add(const Divider(indent: 44, height: 1));
    }
    if (enabled) {
      rows.add(InkWell(
        key: const ValueKey('plan-add'),
        onTap: () async {
          final last = items.isEmpty ? '' : items.last.date;
          final r = await editPlanItem(context, defaultPlanItem(repo, date: last), isNew: true);
          if (r?.item != null) await repo.putPlan(task, r!.item!);
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 46),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(children: [
              SizedBox(width: 24, child: Icon(Icons.date_range_outlined, size: 20, color: items.isEmpty ? muted : cs.primary)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(items.isEmpty ? 'Планирование' : 'Добавить пункт планирования', style: TextStyle(fontSize: 14, color: cs.onSurface)),
                  if (items.isEmpty) Text('Когда заняться задачей; уведомления', style: TextStyle(fontSize: 12, color: muted)),
                ]),
              ),
            ]),
          ),
        ),
      ));
    } else if (items.isEmpty) {
      rows.add(Padding(padding: const EdgeInsets.all(12), child: Text('Не запланирована', style: TextStyle(color: muted))));
    } else {
      rows.removeLast();
    }
    return Plate(padding: EdgeInsets.zero, child: Column(children: rows));
  }
}

// ---------------------------------------------------------------- шкала

/// Перетаскиваемая карточка: что тянут и как показывать «призрак» под пальцем.
class _Drag {
  final Ent task;
  final PlanItem item;
  final Offset grab; // точка захвата внутри карточки
  final Size size;
  final WidgetBuilder face;
  Offset pos;
  bool copy = false;
  _Drag(this.task, this.item, this.grab, this.size, this.face, this.pos);
}

class SchedulePane extends StatefulWidget {
  final VoidCallback? onMenu;
  const SchedulePane({super.key, this.onMenu});
  @override
  State<SchedulePane> createState() => _SchedulePaneState();
}

class _SchedulePaneState extends State<SchedulePane> {
  String _first = ''; // первый показанный день; пусто — сегодня
  late final ScrollController _scroll;
  final _gridKey = GlobalKey(), _viewKey = GlobalKey(), _dueKey = GlobalKey();
  List<String> _dates = const [];
  double _colW = 150;
  _Drag? _drag;
  OverlayEntry? _ghost;

  @override
  void initState() {
    super.initState();
    // шкала открывается за час до текущего времени
    final h = app.repo.localOf(app.repo.clock()).hour;
    _scroll = ScrollController(initialScrollOffset: ((h - 1).clamp(0, 16)) * _hourH);
  }

  @override
  void dispose() {
    _ghost?.remove();
    _scroll.dispose();
    super.dispose();
  }

  // ---- перетаскивание ----

  bool isDragging(Ent t, PlanItem p) => _drag != null && _drag!.task.id == t.id && _drag!.item.id == p.id;
  bool get dragCopy => _drag?.copy ?? false;

  void beginDrag(Ent t, PlanItem p, Offset global, Offset grab, Size size, WidgetBuilder face) {
    _ghost?.remove();
    _drag = _Drag(t, p, grab, size, face, global);
    // включился режим перетаскивания: лёгкая вибрация, карточка «приподнимается» и получает значок
    HapticFeedback.selectionClick();
    final overlay = Overlay.of(context);
    _ghost = OverlayEntry(builder: (_) {
      final d = _drag;
      if (d == null) return const SizedBox.shrink();
      final cs = Theme.of(context).colorScheme;
      // координаты оверлея могут не совпадать с экранными (например, над ним своя строка заголовка окна в Windows)
      final box = overlay.context.findRenderObject() as RenderBox?;
      final at = box == null ? d.pos : box.globalToLocal(d.pos);
      Widget badge(Key key, IconData icon) => Container(
            key: key,
            width: 18,
            height: 18,
            decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle, boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black26)]),
            child: Icon(icon, size: 13, color: cs.onPrimary),
          );
      return Positioned(
        left: at.dx - d.grab.dx,
        top: at.dy - d.grab.dy,
        width: d.size.width,
        height: d.size.height < 20 ? 20 : d.size.height, // карточка видна целиком, какой бы длинной она ни была
        child: IgnorePointer(
          child: Material(
            type: MaterialType.transparency,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 1, end: d.copy ? 1.07 : 1.03),
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutBack,
              builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
              child: Container(
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(7), boxShadow: const [BoxShadow(blurRadius: 10, offset: Offset(0, 3), color: Colors.black26)]),
                child: Stack(clipBehavior: Clip.none, children: [
                  Positioned.fill(child: d.face(context)),
                  Positioned(
                    right: -7,
                    top: -7,
                    child: d.copy ? badge(const ValueKey('copy-badge'), Icons.add) : badge(const ValueKey('move-badge'), Icons.open_with),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
    });
    overlay.insert(_ghost!);
    setState(() {});
  }
  void moveDrag(Offset global) {
    if (_drag == null) return;
    _drag!.pos = global;
    _ghost?.markNeedsBuild();
  }

  /// Удержание без движения: перенос становится копированием (с вибрацией и анимацией).
  void setCopy() {
    if (_drag == null || _drag!.copy) return;
    _drag!.copy = true;
    HapticFeedback.mediumImpact();
    _ghost?.markNeedsBuild();
    setState(() {});
  }

  void endDrag({required bool drop}) {
    final d = _drag;
    _ghost?.remove();
    _ghost = null;
    _drag = null;
    if (mounted) setState(() {});
    if (d != null && drop) _drop(d);
  }

  String? _dateAt(Offset global) {
    final grid = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (grid == null || _dates.isEmpty) return null;
    final x = grid.globalToLocal(global).dx;
    if (x < _axisW) return null;
    return _dates[((x - _axisW) / _colW).floor().clamp(0, _dates.length - 1)];
  }

  bool _inside(GlobalKey k, Offset global) {
    final box = k.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    return (Offset.zero & box.size).contains(box.globalToLocal(global));
  }

  /// Карточку отпустили: в зоне «без времени» — пункт без времени на этот день,
  /// над шкалой — на это время (длительность сохраняется; у пункта без времени — час).
  void _drop(_Drag d) {
    final repo = app.repo;
    final date = _dateAt(d.pos);
    if (date == null) return;
    PlanItem? next;
    if (_inside(_dueKey, d.pos)) {
      next = d.item.untimed().copyWith(date: date);
    } else if (_inside(_viewKey, d.pos)) {
      final grid = _gridKey.currentContext!.findRenderObject() as RenderBox;
      final y = grid.globalToLocal(d.pos).dy - (d.item.timed ? d.grab.dy : 0);
      final len = d.item.timed ? d.item.to - d.item.from : 60;
      // карточка со временем встаёт верхним краем к ближайшему шагу, пункт без времени — в тот промежуток, куда указали
      final steps = y / _hourH * 60 / _snap;
      final m = ((d.item.timed ? steps.round() : steps.floor()) * _snap).clamp(0, 1440 - len);
      next = d.item.copyWith(date: date, from: m, to: m + len);
    }
    if (next == null) return;
    if (d.copy) {
      repo.putPlan(d.task, next.copyWith(id: repo.newPlanId()));
    } else if (next.date != d.item.date || next.from != d.item.from || next.to != d.item.to) {
      repo.putPlan(d.task, next);
    }
  }

  // ---- вид ----

  /// Все пункты на этот день: (задача, пункт).
  List<(Ent, PlanItem)> _items(String date, {required bool timed}) {
    final out = <(Ent, PlanItem)>[
      for (final t in app.repo.tasksOf(secSchedule))
        for (final p in t.plans)
          if (p.date == date && p.timed == timed) (t, p)
    ];
    out.sort((a, b) {
      if (a.$1.done != b.$1.done) return a.$1.done ? 1 : -1;
      final c = PlanItem.compare(a.$2, b.$2);
      return c != 0 ? c : a.$1.createdAt.compareTo(b.$1.createdAt);
    });
    return out;
  }

  @override
  Widget build(BuildContext context) => Live(builder: _build);

  Widget _build(BuildContext context) {
    final repo = app.repo;
    final today = repo.today;
    final first = _first.isEmpty ? today : _first;
    final muted = mutedOf(context);
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, box) {
      final days = ((box.maxWidth - _axisW) ~/ 150).clamp(1, 7);
      final dates = [for (var i = 0; i < days; i++) addDays(first, i)];
      _dates = dates;
      final a = parseDate(dates.first), b = parseDate(dates.last);
      final range = days == 1
          ? '${a.day} ${monthsGen[a.month - 1]}'
          : (a.month == b.month ? '${a.day}–${b.day} ${monthsGen[b.month - 1]}' : '${a.day} ${monthsGen[a.month - 1]} – ${b.day} ${monthsGen[b.month - 1]}');
      final colW = (box.maxWidth - _axisW - 8) / days;
      _colW = colW;
      return Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
          child: Row(children: [
            if (widget.onMenu != null) IconButton(icon: const Icon(Icons.menu), onPressed: widget.onMenu),
            const SizedBox(width: 6),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Планирование', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
                Text(range, style: TextStyle(fontSize: 13, color: muted)),
              ]),
            ),
            IconButton(icon: const Icon(Icons.chevron_left), tooltip: 'Раньше', onPressed: () => setState(() => _first = addDays(first, -days))),
            TextButton(onPressed: first == today ? null : () => setState(() => _first = ''), child: const Text('Сегодня')),
            IconButton(icon: const Icon(Icons.chevron_right), tooltip: 'Позже', onPressed: () => setState(() => _first = addDays(first, days))),
            IconButton(
              icon: Icon(Icons.add, color: cs.primary),
              tooltip: 'Запланировать задачу',
              onPressed: () => showSlotDialog(context, defaultPlanItem(repo, date: dates.contains(today) ? today : dates.first)),
            ),
          ]),
        ),
        // заголовки дней
        Padding(
          padding: const EdgeInsets.only(left: _axisW, right: 8, bottom: 4),
          child: Row(children: [
            for (final d in dates)
              Expanded(
                child: Text(
                  '${weekdaysShort[parseDate(d).weekday - 1]}, ${parseDate(d).day}',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, fontWeight: d == today ? FontWeight.w700 : FontWeight.w500, color: d == today ? cs.primary : muted),
                ),
              ),
          ]),
        ),
        // пункты без времени: пунктиром в начале дня; сюда же можно увести пункт со шкалы
        ConstrainedBox(
          key: _dueKey,
          constraints: const BoxConstraints(minHeight: 30, maxHeight: 112),
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(right: 8, bottom: 4),
            child: IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(
                  width: _axisW,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4, right: 6),
                    child: Tooltip(
                      message: 'Без времени: перетащите сюда карточку со шкалы',
                      child: Text('без\nвр.', textAlign: TextAlign.right, style: TextStyle(fontSize: 10, height: 1.15, color: muted)),
                    ),
                  ),
                ),
                for (final d in dates)
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      // нажатие на пустое место — пункт без времени на этот день
                      onTap: () => showSlotDialog(context, PlanItem(repo.newPlanId(), d)),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 26),
                        decoration: BoxDecoration(border: Border(left: BorderSide(color: borderOf(context)))),
                        child: Column(children: [
                          for (final (t, p) in _items(d, timed: false))
                            _DueChip(key: ValueKey('due:${t.id}:${p.id}'), task: t, item: p, ctl: this),
                        ]),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
        ),
        Divider(height: 1, color: borderOf(context)),
        Expanded(
          key: _viewKey,
          child: SingleChildScrollView(
            controller: _scroll,
            padding: const EdgeInsets.only(right: 8, top: 8, bottom: 8),
            child: SizedBox(
              key: _gridKey,
              height: 24 * _hourH,
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(
                  width: _axisW,
                  child: Stack(clipBehavior: Clip.none, children: [
                    for (var h = 1; h < 24; h++)
                      Positioned(top: h * _hourH - 8, right: 6, child: Text(fmtTime(h, 0), style: TextStyle(fontSize: 11, color: muted))),
                  ]),
                ),
                for (final d in dates) Expanded(child: _DayColumn(key: ValueKey('day:$d'), date: d, colW: colW, items: _items(d, timed: true), ctl: this)),
              ]),
            ),
          ),
        ),
      ]);
    });
  }
}

/// Нажатия и перетаскивание карточки (пункта на шкале или без времени).
/// Мышью или пальцем: сразу тянуть — перенос; зажать на 2 секунды и потом тянуть — копирование.
/// Пальцем перетаскивание начинается после короткого удержания, чтобы шкалу можно было листать.
class _DragSource extends StatefulWidget {
  final Ent task;
  final PlanItem item;
  final _SchedulePaneState ctl;
  final WidgetBuilder face;
  final Widget child;
  const _DragSource({required this.task, required this.item, required this.ctl, required this.face, required this.child});
  @override
  State<_DragSource> createState() => _DragSourceState();
}

class _DragSourceState extends State<_DragSource> {
  Timer? _hold;
  Offset? _down;
  bool _moved = false, _dragging = false, _copyReady = false;

  @override
  void dispose() {
    _hold?.cancel();
    if (_dragging) widget.ctl.endDrag(drop: false);
    super.dispose();
  }

  void _pressed(Offset g) {
    _down = g;
    _moved = _copyReady = false;
    _hold?.cancel();
    _hold = Timer(copyHold, () {
      if (_moved || _down == null) return;
      _copyReady = true;
      if (!_dragging) _begin(_down!);
      widget.ctl.setCopy();
    });
  }

  void _begin(Offset g) {
    if (_dragging || !mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    _dragging = true;
    _down ??= g; // нажатие могло не успеть дойти до onTapDown (сразу потянули)
    widget.ctl.beginDrag(widget.task, widget.item, g, box.globalToLocal(_down ?? g), box.size, widget.face);
    if (_copyReady) widget.ctl.setCopy();
  }

  void _update(Offset g) {
    if (_down != null && (g - _down!).distance > 6 && !_moved) {
      _moved = true;
      _hold?.cancel();
    }
    widget.ctl.moveDrag(g);
  }

  void _end() {
    _hold?.cancel();
    if (_dragging) widget.ctl.endDrag(drop: _moved); // зажали и отпустили на месте — ничего не меняется
    _dragging = false;
    _down = null;
  }

  /// Палец или кнопку отпустили: если перетаскивание не началось, удержание больше не считается.
  void _released() {
    if (!_dragging) {
      _hold?.cancel();
      _down = null;
    }
  }

  void _cancel() {
    _hold?.cancel();
    if (_dragging) widget.ctl.endDrag(drop: false);
    _dragging = false;
    _down = null;
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.task;
    final can = app.repo.canToggle(t);
    final hidden = widget.ctl.isDragging(t, widget.item) && !widget.ctl.dragCopy;
    return Opacity(
      opacity: hidden ? 0.3 : 1,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        // нажатие, движение и отпускание видны сразу (до распознавания жестов): по ним идёт отсчёт удержания
        child: Listener(
          onPointerDown: can ? (e) => _pressed(e.position) : null,
          onPointerMove: can
              ? (e) {
                  if (_down != null && !_moved && (e.position - _down!).distance > 6) {
                    _moved = true;
                    _hold?.cancel();
                  }
                }
              : null,
          onPointerUp: can ? (_) => _released() : null,
          onPointerCancel: can ? (_) => _released() : null,
          child: GestureDetector(
          dragStartBehavior: DragStartBehavior.down,
          onTap: () => app.openTask(t.id),
          onPanStart: can ? (d) => _begin(d.globalPosition) : null,
          onPanUpdate: can ? (d) => _update(d.globalPosition) : null,
          onPanEnd: can ? (_) => _end() : null,
          // жест перетаскивания проиграл долгому нажатию — удержание продолжает считаться
          onPanCancel: can
              ? () {
                  if (_dragging) _cancel();
                }
              : null,
          onLongPressStart: can ? (d) => _begin(d.globalPosition) : null,
          onLongPressMoveUpdate: can ? (d) => _update(d.globalPosition) : null,
          onLongPressEnd: can ? (_) => _end() : null,
          child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Пункт без времени: пунктирная плашка в начале дня.
class _DueChip extends StatelessWidget {
  final Ent task;
  final PlanItem item;
  final _SchedulePaneState ctl;
  const _DueChip({super.key, required this.task, required this.item, required this.ctl});

  Widget _face(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = task;
    final color = t.done ? cs.onSurface.withValues(alpha: 0.4) : planColor(context, t);
    return CustomPaint(
      painter: _DashedBorder(color.withValues(alpha: 0.9)),
      child: Container(
        height: 22,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        decoration: BoxDecoration(color: Color.alphaBlend(color.withValues(alpha: 0.12), cs.surface), borderRadius: BorderRadius.circular(6)),
        child: Row(children: [
          Expanded(
            child: Text(t.title.isEmpty ? 'Без названия' : t.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w500, decoration: t.done ? TextDecoration.lineThrough : null, color: cs.onSurface.withValues(alpha: t.done ? 0.55 : 1))),
          ),
          if (item.notify) Icon(Icons.notifications_none, size: 12, color: mutedOf(context)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = app.repo;
    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 3, 3, 0),
      child: _DragSource(
        task: task,
        item: item,
        ctl: ctl,
        face: _face,
        child: Tooltip(
          message: '${task.title}\n${planItemLabel(repo, item)}',
          waitDuration: const Duration(milliseconds: 700),
          triggerMode: TooltipTriggerMode.manual, // долгое нажатие — это перетаскивание, а не подсказка
          child: _face(context),
        ),
      ),
    );
  }
}

class _DashedBorder extends CustomPainter {
  final Color color;
  const _DashedBorder(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final path = Path()..addRRect(RRect.fromRectAndRadius((Offset.zero & size).deflate(0.6), const Radius.circular(6)));
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 7) {
        canvas.drawPath(m.extractPath(d, d + 4), p);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder old) => old.color != color;
}

class _Seg {
  final Ent t;
  final PlanItem p;
  final double top, height;
  int col = 0, cols = 1;
  _Seg(this.t, this.p, this.top, this.height);
}

/// Колонка одного дня: сетка часов, карточки пунктов, линия текущего времени.
class _DayColumn extends StatelessWidget {
  final String date;
  final double colW;
  final List<(Ent, PlanItem)> items;
  final _SchedulePaneState ctl;
  const _DayColumn({super.key, required this.date, required this.colW, required this.items, required this.ctl});

  @override
  Widget build(BuildContext context) {
    final repo = app.repo;
    final cs = Theme.of(context).colorScheme;
    final segs = [for (final (t, p) in items) _Seg(t, p, p.from / 60 * _hourH, (p.to - p.from) / 60 * _hourH)]
      ..sort((a, b) => a.top != b.top ? a.top.compareTo(b.top) : a.t.id.compareTo(b.t.id));
    // пересекающиеся карточки встают рядом
    var cluster = <_Seg>[];
    var clusterEnd = -1.0;
    final ends = <double>[];
    void close() {
      for (final s in cluster) {
        s.cols = ends.length;
      }
      cluster = [];
      ends.clear();
    }

    for (final s in segs) {
      final bottom = s.top + (s.height < 22 ? 22 : s.height);
      if (s.top >= clusterEnd) close();
      var c = ends.indexWhere((e) => e <= s.top);
      if (c < 0) {
        c = ends.length;
        ends.add(bottom);
      } else {
        ends[c] = bottom;
      }
      s.col = c;
      cluster.add(s);
      if (bottom > clusterEnd) clusterEnd = bottom;
    }
    close();

    final dayStart = repo.momentOf(date, '00:00');
    final now = repo.clock();
    final nowMin = (now - dayStart) / 60000;
    final w = colW - 5;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // нажатие на пустое место — запланировать на этот час
      onTapUp: (d) {
        final m = (d.localPosition.dy / _hourH * 60 ~/ 30 * 30).clamp(0, 23 * 60 + 30);
        showSlotDialog(context, PlanItem(repo.newPlanId(), date, from: m, to: (m + 60).clamp(m + 30, 1440)));
      },
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned.fill(child: CustomPaint(painter: _GridPainter(borderOf(context)))),
        for (final s in segs)
          Positioned(
            key: ValueKey('seg:${s.t.id}:${s.p.id}'),
            top: s.top,
            left: 3 + s.col * w / s.cols,
            width: w / s.cols - 2,
            height: s.height < 22 ? 22 : s.height,
            child: _Block(task: s.t, item: s.p, ctl: ctl),
          ),
        if (nowMin >= 0 && nowMin < 1440)
          Positioned(top: nowMin / 60 * _hourH - 1, left: 0, right: 0, child: IgnorePointer(child: Container(height: 2, color: cs.error.withValues(alpha: 0.8)))),
      ]),
    );
  }
}

class _GridPainter extends CustomPainter {
  final Color color;
  const _GridPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    final half = Paint()
      ..color = color.withValues(alpha: color.a * 0.4)
      ..strokeWidth = 1;
    canvas.drawLine(Offset.zero, Offset(0, size.height), p);
    for (var h = 0; h <= 24; h++) {
      canvas.drawLine(Offset(0, h * _hourH), Offset(size.width, h * _hourH), p);
      if (h < 24) canvas.drawLine(Offset(0, (h + 0.5) * _hourH), Offset(size.width, (h + 0.5) * _hourH), half);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.color != color;
}

/// Карточка пункта на шкале: нажатие открывает задачу, перетаскивание переносит (или копирует),
/// нижний край меняет длительность.
class _Block extends StatefulWidget {
  final Ent task;
  final PlanItem item;
  final _SchedulePaneState ctl;
  const _Block({required this.task, required this.item, required this.ctl});
  @override
  State<_Block> createState() => _BlockState();
}

class _BlockState extends State<_Block> {
  double _grow = 0;

  Ent get t => widget.task;
  PlanItem get p => widget.item;

  void _endGrow() {
    final d = (_grow / _hourH * 60 / _snap).round() * _snap;
    setState(() => _grow = 0);
    if (d == 0) return;
    app.repo.putPlan(t, p.copyWith(to: (p.to + d).clamp(p.from + _snap, 1440)));
  }

  Widget _face(BuildContext context, {double? height}) {
    final repo = app.repo;
    final cs = Theme.of(context).colorScheme;
    final base = t.done ? cs.onSurface.withValues(alpha: 0.35) : planColor(context, t);
    final selected = app.taskId == t.id;
    final tall = (height ?? 0) >= 40;
    final mine = t.assigneeId == repo.me;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Color.alphaBlend(base.withValues(alpha: 0.24), cs.surface),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: base.withValues(alpha: selected ? 1 : 0.6), width: selected ? 1.6 : 1),
      ),
      padding: const EdgeInsets.fromLTRB(6, 2, 4, 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          t.title.isEmpty ? 'Без названия' : t.title,
          maxLines: tall ? 2 : 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: 12.5,
              height: 1.2,
              fontWeight: FontWeight.w600,
              decoration: t.done ? TextDecoration.lineThrough : null,
              color: cs.onSurface.withValues(alpha: t.done ? 0.55 : 1)),
        ),
        if (tall)
          Text(
            ['${fmtMin(p.from)}–${fmtMin(p.to)}', if (!mine && !t.isPrivate) repo.userName(t.assigneeId)].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: mutedOf(context)),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = app.repo;
    final can = repo.canToggle(t);
    return LayoutBuilder(builder: (context, box) {
      final h = (box.maxHeight + _grow).clamp(12.0, 24 * _hourH);
      return Stack(clipBehavior: Clip.none, children: [
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: h,
          child: _DragSource(
            task: t,
            item: p,
            ctl: widget.ctl,
            face: (c) => _face(c, height: box.maxHeight),
            child: Tooltip(
              message: '${t.title}\n${planItemLabel(repo, p)}',
              waitDuration: const Duration(milliseconds: 700),
          triggerMode: TooltipTriggerMode.manual, // долгое нажатие — это перетаскивание, а не подсказка
              child: _face(context, height: h),
            ),
          ),
        ),
        if (can)
          Positioned(
            left: 0,
            right: 0,
            top: h - 7,
            height: 9,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeUpDown,
              child: GestureDetector(
                key: ValueKey('grow:${t.id}:${p.id}'),
                behavior: HitTestBehavior.opaque,
                dragStartBehavior: DragStartBehavior.down,
                onVerticalDragUpdate: (d) => setState(() => _grow += d.delta.dy),
                onVerticalDragEnd: (_) => _endGrow(),
                onVerticalDragCancel: () => setState(() => _grow = 0),
              ),
            ),
          ),
      ]);
    });
  }
}

/// Окно «Запланировать»: новая задача или новый пункт у существующей задачи.
Future<void> showSlotDialog(BuildContext context, PlanItem item) => showDialog<void>(context: context, builder: (_) => _SlotDialog(item: item));

class _SlotDialog extends StatefulWidget {
  final PlanItem item;
  const _SlotDialog({required this.item});
  @override
  State<_SlotDialog> createState() => _SlotDialogState();
}

class _SlotDialogState extends State<_SlotDialog> {
  late PlanItem _item = widget.item;
  String? _open; // id раскрытого списка ('' — «Задачи», '-' — все свёрнуты)
  final _title = TextEditingController(), _search = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    _search.dispose();
    super.dispose();
  }

  Ent _draft() {
    final d = app.repo.draftTask(title: _title.text.trim());
    app.repo.setPlans(d, [_item]);
    return d;
  }

  Future<void> _create() async {
    if (_title.text.trim().isEmpty) return;
    final nav = Navigator.of(context);
    await app.repo.addTask(_draft());
    nav.pop();
  }

  Future<void> _use(Ent t) async {
    final nav = Navigator.of(context);
    await app.repo.putPlan(t, _item.copyWith(id: app.repo.newPlanId()));
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final repo = app.repo;
    final muted = mutedOf(context);
    final q = _search.text.trim().toLowerCase();
    // существующие: открытые задачи, которые пользователь вправе планировать (автор или исполнитель),
    // по спискам: сначала «Задачи» (без списка), затем списки в порядке меню
    final groups = <(String, String, List<Ent>)>[
      ('', 'Задачи', <Ent>[]),
      for (final l in repo.visibleLists) (l.id, l.name.isEmpty ? 'Без названия' : l.name, <Ent>[]),
    ];
    final byId = {for (final g in groups) g.$1: g.$3};
    for (final t in repo.tasks.values) {
      if (t.deleted || t.done || !repo.canToggle(t) || (t.isPrivate && t.creatorId != repo.me)) continue;
      if (q.isNotEmpty && !t.title.toLowerCase().contains(q)) continue;
      byId[t.listId]?.add(t);
    }
    // внутри списка: сначала ещё не запланированные, затем с пунктами; в каждой части — от старых к новым
    for (final g in groups) {
      g.$3.sort((a, b) {
        final pa = a.planned ? 1 : 0, pb = b.planned ? 1 : 0;
        if (pa != pb) return pa - pb;
        return a.createdAt.compareTo(b.createdAt);
      });
    }
    final shown = q.isEmpty ? groups : groups.where((g) => g.$3.isNotEmpty).toList();
    // открыт один список; по умолчанию — первый непустой. При поиске раскрыто всё найденное
    _open ??= groups.firstWhere((g) => g.$3.isNotEmpty, orElse: () => groups.first).$1;
    final rows = <Widget>[];
    for (final g in shown) {
      final open = q.isNotEmpty || _open == g.$1;
      final accent = Theme.of(context).colorScheme.primary;
      final lc = repo.lists[g.$1]?.color ?? '';
      final color = lc.isEmpty ? accent : parseHex(lc, accent);
      rows.add(InkWell(
        key: ValueKey('slot-group:${g.$1}'),
        borderRadius: BorderRadius.circular(8),
        onTap: q.isNotEmpty ? null : () => setState(() => _open = open ? '-' : g.$1),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
          child: Row(children: [
            Icon(open ? Icons.expand_more : Icons.chevron_right, size: 20, color: muted),
            const SizedBox(width: 4),
            Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(child: Text(g.$2, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
            Text('${g.$3.length}', style: TextStyle(fontSize: 12, color: muted)),
          ]),
        ),
      ));
      if (!open) continue;
      if (g.$3.isEmpty) {
        rows.add(Padding(padding: const EdgeInsets.fromLTRB(32, 0, 0, 8), child: Text('Открытых задач нет', style: TextStyle(fontSize: 13, color: muted))));
      }
      for (final t in g.$3) {
        final next = repo.nextPlan(t);
        final sub = [
          if (next != null) planItemLabel(repo, next).toLowerCase(),
          if (t.assigneeId != repo.me) repo.userName(t.assigneeId),
        ].join(' · ');
        rows.add(ListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 26, right: 4),
          title: Text(t.title.isEmpty ? 'Без названия' : t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: sub.isEmpty ? null : Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: muted)),
          onTap: () => _use(t),
        ));
      }
    }    return AlertDialog(
      title: const Text('Запланировать'),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      content: SizedBox(
        width: 400,
        height: 520,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          PlanFields(item: _item, onChanged: (x) => setState(() => _item = x)),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: TextField(
                key: const ValueKey('slot-title'),
                controller: _title,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Новая задача'),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _create(),
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              tooltip: 'Полная форма',
              icon: const Icon(Icons.open_in_full, size: 18),
              onPressed: () {
                final d = _draft();
                Navigator.pop(context);
                app.startDraft(d);
              },
            ),
            FilledButton(onPressed: _title.text.trim().isEmpty ? null : _create, child: const Text('Создать')),
          ]),
          const SizedBox(height: 14),
          Text('Или пункт для существующей задачи', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: muted)),
          const SizedBox(height: 6),
          TextField(
            controller: _search,
            decoration: const InputDecoration(hintText: 'Поиск', prefixIcon: Icon(Icons.search, size: 18), prefixIconConstraints: BoxConstraints(minWidth: 36), isDense: true),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: rows.isEmpty
                ? Center(child: Text('Ничего не найдено', style: TextStyle(color: muted)))
                : SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows)),
          ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена'))],
    );
  }
}
