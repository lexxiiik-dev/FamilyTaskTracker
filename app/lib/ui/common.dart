// Общие элементы интерфейса: тема, аватарки, круглая галочка, диалоги выбора.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app.dart';
import '../core/model.dart';
import '../core/repo.dart';

/// Единственный экземпляр состояния приложения (создаётся в main).
late AppState app;

Color parseHex(String? s, Color def) {
  if (s == null || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(s)) return def;
  return Color(0xFF000000 | int.parse(s.substring(1), radix: 16));
}

String toHex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

const accentPresets = ['#3F6B4A', '#843875', '#2F6FB5', '#B5542F', '#B58A2F', '#2F9E9A', '#6B5BD6', '#C0392B', '#5C6B73'];
const defaultAccent = Color(0xFF3F6B4A);
Color defaultPlate(bool dark) => dark ? const Color(0xFF24221F) : const Color(0xFFFBF9F1);
Color defaultBorder(bool dark) => dark ? const Color(0xFF45413A) : const Color(0xFFDAD2B9);
List<String> platePresets(bool dark) => dark
    ? const ['#24221F', '#141A22', '#1E1E1E', '#1B2420', '#221C26', '#2A2320', '#101418']
    : const ['#FBF9F1', '#FFFFFF', '#F6F8FB', '#F3EFE6', '#EEF3EE', '#F1EEF6', '#FDF3EC'];
List<String> borderPresets(bool dark) => dark
    ? const ['#45413A', '#2F3845', '#3A3A3A', '#34463A', '#463A52', '#55443A', '#5E6B7A']
    : const ['#DAD2B9', '#C8CED6', '#D0D0D0', '#B9CDBB', '#CDBBD6', '#E0C4B0', '#8A8F98'];

/// Фоновая картинка хранится только на устройстве (JPEG в base64); расшифровка кэшируется.
String? _bgSrc;
Uint8List? _bgBytes;
Uint8List? backgroundBytes(Repo r) {
  final s = r.kv['bg_image'];
  if (s == null || s.isEmpty) return null;
  if (!identical(s, _bgSrc)) {
    try {
      _bgBytes = base64Decode(s);
    } catch (_) {
      _bgBytes = null;
    }
    _bgSrc = s;
  }
  return _bgBytes;
}

/// Насколько фоновая картинка закрашена цветом темы, 0..1.
double backgroundDim(Repo r) => ((int.tryParse(r.kv['bg_dim'] ?? '') ?? 50).clamp(0, 90)) / 100;

/// Оформление: акцентный цвет, цвет подложек и окантовок, светлая или тёмная тема.
ThemeData buildTheme(Repo r, Brightness system) {
  final mode = r.setting<String>('theme', 'system');
  final dark = mode == 'dark' || (mode != 'light' && system == Brightness.dark);
  final accent = parseHex(r.setting<String>('accent', ''), defaultAccent);
  final plate = parseHex(r.setting<String>(dark ? 'plate_dark' : 'plate', ''), defaultPlate(dark));
  final border = parseHex(r.setting<String>(dark ? 'border_dark' : 'border', ''), defaultBorder(dark));
  final bg = Color.lerp(plate, dark ? Colors.black : border, dark ? 0.28 : 0.30)!;
  // цвет текста — по яркости подложки, чтобы любой выбранный цвет оставался читаемым
  final darkPlate = plate.computeLuminance() < 0.3;
  final text = darkPlate ? const Color(0xFFEDE9E0) : const Color(0xFF2B2A26);
  final primary = darkPlate ? Color.lerp(accent, Colors.white, 0.25)! : accent;
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: dark ? Brightness.dark : Brightness.light).copyWith(
    primary: primary,
    surface: plate,
    onSurface: text,
    outline: border,
    outlineVariant: border,
    surfaceContainerHighest: Color.lerp(plate, text, 0.07),
    surfaceContainerHigh: Color.lerp(plate, text, 0.05),
    surfaceContainer: Color.lerp(plate, text, 0.035),
    surfaceContainerLow: Color.lerp(plate, text, 0.02),
  );
  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(12),
    side: BorderSide(color: border),
  );
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'Roboto',
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    dividerColor: border,
    dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
    cardTheme: CardThemeData(color: plate, elevation: 0, shape: shape, margin: EdgeInsets.zero),
    dialogTheme: DialogThemeData(
      backgroundColor: plate,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: border),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(color: plate, shape: shape),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: Color.lerp(plate, text, 0.04),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: primary, width: 1.4),
      ),
    ),
    listTileTheme: ListTileThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), dense: true),
    appBarTheme: AppBarTheme(backgroundColor: bg, foregroundColor: text, elevation: 0, scrolledUnderElevation: 0),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

Color mutedOf(BuildContext c) => Theme.of(c).colorScheme.onSurface.withValues(alpha: 0.6);
Color borderOf(BuildContext c) => Theme.of(c).colorScheme.outline;

/// Перестраивает содержимое при любом изменении данных, выбора или состояния синхронизации.
class Live extends StatelessWidget {
  final WidgetBuilder builder;
  const Live({super.key, required this.builder});
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: Listenable.merge([app, app.repo, app.sync]), builder: (c, _) => builder(c));
}

/// Плашка с окантовкой — основной «строительный блок» оформления.
class Plate extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;
  const Plate({super.key, required this.child, this.padding = const EdgeInsets.all(12), this.onTap, this.color});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: color ?? cs.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class UserAvatar extends StatelessWidget {
  final User? user;
  final double size;
  const UserAvatar(this.user, {super.key, this.size = 32});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final u = user;
    final letter = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.18), shape: BoxShape.circle),
      child: Text(
        (u == null || u.name.isEmpty) ? '?' : u.name.characters.first.toUpperCase(),
        style: TextStyle(fontWeight: FontWeight.w700, fontSize: size * 0.45, color: cs.primary),
      ),
    );
    if (u == null || u.avatarVer == 0) return letter;
    return FutureBuilder<Uint8List?>(
      key: ValueKey('${u.id}:${u.avatarVer}'),
      future: app.sync.avatar(u),
      builder: (_, snap) => snap.data == null
          ? letter
          : ClipOval(
              child: Image.memory(snap.data!, width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true),
            ),
    );
  }
}

/// Круглая галочка завершения, как в To Do.
class RoundCheck extends StatelessWidget {
  final bool value;
  final VoidCallback? onTap;
  final double size;
  const RoundCheck({super.key, required this.value, this.onTap, this.size = 22});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    return InkResponse(
      onTap: onTap,
      radius: size,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: value ? cs.primary.withValues(alpha: enabled ? 1 : 0.5) : Colors.transparent,
            border: Border.all(color: value ? Colors.transparent : cs.onSurface.withValues(alpha: enabled ? 0.55 : 0.25), width: 1.6),
          ),
          child: value ? Icon(Icons.check, size: size * 0.7, color: cs.onPrimary) : null,
        ),
      ),
    );
  }
}

/// Вариант для [pickOption].
class Option<T> {
  final T value;
  final String label;
  final Widget? leading;
  const Option(this.value, this.label, {this.leading});
}

/// Выбор одного значения в окне по центру экрана (с окантовкой, как у остальных окон).
Future<T?> pickOption<T>(BuildContext context, {required String title, required List<Option<T>> options, T? current}) => showDialog<T>(
  context: context,
  builder: (c) => SimpleDialog(
    title: Text(title),
    children: [
      for (final o in options)
        SimpleDialogOption(
          onPressed: () => Navigator.pop(c, o.value),
          child: Row(
            children: [
              if (o.leading != null) ...[o.leading!, const SizedBox(width: 12)],
              Expanded(child: Text(o.label, overflow: TextOverflow.ellipsis)),
              if (o.value == current) const Icon(Icons.check, size: 18),
            ],
          ),
        ),
    ],
  ),
);

/// Поле с выбранным значением; по нажатию открывает окно выбора.
class SelectField extends StatelessWidget {
  final String? label, helper;
  final String text;
  final Widget? leading;
  final VoidCallback onTap;
  const SelectField({super.key, this.label, this.helper, required this.text, this.leading, required this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(10),
    onTap: onTap,
    child: InputDecorator(
      decoration: InputDecoration(labelText: label, helperText: helper, suffixIcon: const Icon(Icons.arrow_drop_down)),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 10)],
          Expanded(child: Text(text, overflow: TextOverflow.ellipsis)),
        ],
      ),
    ),
  );
}

void toast(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
}

Future<bool> confirm(BuildContext context, String title, {String? text, String ok = 'Удалить'}) async {
  return await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: text == null ? null : Text(text),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(ok)),
          ],
        ),
      ) ??
      false;
}

/// Выбор даты не раньше сегодняшнего дня (сроки и напоминания в прошлое не ставятся).
/// У просроченной задачи календарь открывается на сегодня; закрыли окно — дата не меняется (null).
Future<String?> pickDate(BuildContext context, String current, String today) async {
  final t = parseDate(today);
  final init = current.isEmpty || current.compareTo(today) < 0 ? t : parseDate(current);
  final d = await showDatePicker(
    context: context,
    initialDate: DateTime(init.year, init.month, init.day),
    firstDate: DateTime(t.year, t.month, t.day),
    lastDate: DateTime(2100),
  );
  return d == null ? null : fmtDate(d);
}

String fmtTime(int h, int m) => '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';

Future<String?> pickTime(BuildContext context, String current) async {
  final p = current.split(':');
  final t = await showTimePicker(
    context: context,
    initialTime: TimeOfDay(hour: int.tryParse(p[0]) ?? 9, minute: p.length > 1 ? int.tryParse(p[1]) ?? 0 : 0),
    builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true), child: child!),
  );
  return t == null ? null : fmtTime(t.hour, t.minute);
}

/// Подпись даты и времени напоминания в часовом поясе из настроек.
String reminderLabel(Repo r, int ms) {
  final date = r.dateOfMoment(ms);
  final dt = r.localOf(ms);
  return '${humanDate(date, r.today)}, ${fmtTime(dt.hour, dt.minute)}';
}
