// Настройки: внешний вид, напоминания, основной список, пользователь, сервер, раздел администратора.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../core/repo.dart';
import '../core/transport.dart';
import '../platform/clipboard.dart';
import 'color_picker.dart';
import 'common.dart';
import 'login.dart';
import 'users.dart';

/// Фоновая картинка: поворот по EXIF, уменьшение до 1920 px по длинной стороне, JPEG.
Uint8List? prepareBackground(Uint8List bytes) {
  var im = img.decodeImage(bytes);
  if (im == null) return null;
  im = img.bakeOrientation(im);
  if (im.width > 1920 || im.height > 1920) {
    im = im.width >= im.height
        ? img.copyResize(im, width: 1920, interpolation: img.Interpolation.average)
        : img.copyResize(im, height: 1920, interpolation: img.Interpolation.average);
  }
  return Uint8List.fromList(img.encodeJpg(im, quality: 84));
}

Future<void> showSettings(BuildContext context) => showDialog(context: context, builder: (_) => const SettingsDialog());

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key});
  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late final _server = TextEditingController(text: app.repo.serverUrl);
  late final _retention = TextEditingController(text: '${(app.repo.global['retention_days'] as num?)?.toInt() ?? 30}');
  late final _tz = TextEditingController(text: (app.repo.global['tz'] ?? '').toString());
  Map<String, dynamic>? _connect;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (!app.repo.isLocal && app.repo.isAdmin) _loadConnect();
  }

  Future<void> _pickColor(String key, String title, Color def, List<String> presets) async {
    final v = await pickColor(context, title: title, initial: parseHex(app.repo.setting<String>(key, ''), def), presets: presets, canReset: true);
    if (v != null) await app.repo.setSetting(key, v);
  }

  /// Цвет виджета хранится на устройстве; пустое значение возвращает цвет системы.
  Future<void> _pickWidgetColor(String key, String title, Color def, List<String> presets) async {
    final v = await pickColor(context, title: title, initial: parseHex(app.repo.kv[key], def), presets: presets, canReset: true);
    if (v == null) return;
    await app.repo.setLocal(key, v.isEmpty ? null : v);
    await app.platform.refresh(app.repo);
  }

  /// Перенести в виджет текущие цвета приложения.
  Future<void> _widgetLikeApp() async {
    final cs = Theme.of(context).colorScheme;
    final colors = [cs.surface, borderOf(context), cs.onSurface, cs.primary];
    for (var i = 0; i < widgetColorKeys.length; i++) {
      await app.repo.setLocal(widgetColorKeys[i], toHex(colors[i]));
    }
    await app.platform.refresh(app.repo);
  }

  Future<void> _widgetReset() async {
    // сбрасывается только оформление; выбор «все / только свои» остаётся
    for (final k in [...widgetColorKeys, 'w_alpha']) {
      await app.repo.setLocal(k, null);
    }
    await app.platform.refresh(app.repo);
  }

  Future<void> _pickBackground() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (x == null) return;
    setState(() => _busy = true);
    try {
      final jpeg = await compute(prepareBackground, await x.readAsBytes());
      if (jpeg == null) throw Exception('не картинка');
      await app.repo.setLocal('bg_image', base64Encode(jpeg));
    } catch (_) {
      if (mounted) toast(context, 'Не удалось прочитать картинку');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    for (final c in [_server, _retention, _tz]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadConnect() async {
    try {
      final r = await app.sync.call('GET', '/v1/admin/connect-info');
      if (r.ok && mounted) setState(() => _connect = r.json);
    } catch (_) {}
  }

  Future<void> _changeAvatar() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024, maxHeight: 1024);
    if (x == null) return;
    setState(() => _busy = true);
    try {
      final src = img.decodeImage(await x.readAsBytes());
      if (src == null) throw Exception('не картинка');
      // квадрат 256px, JPEG; сервер сделает из него превью
      final jpeg = Uint8List.fromList(img.encodeJpg(img.copyResizeCropSquare(src, size: 256), quality: 88));
      final err = await app.sync.uploadAvatar(jpeg);
      if (mounted) toast(context, err ?? 'Аватарка обновлена');
    } catch (_) {
      if (mounted) toast(context, 'Не удалось прочитать картинку');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveAdmin() async {
    final days = int.tryParse(_retention.text.trim());
    if (days == null || days < 1 || days > 3650) {
      toast(context, 'Срок жизни — от 1 до 3650 дней');
      return;
    }
    try {
      final r = await app.sync.call('PUT', '/v1/admin/settings', body: {'retention_days': days, 'tz': _tz.text.trim()});
      if (!mounted) return;
      toast(context, r.ok ? 'Сохранено' : r.error);
      if (r.ok) app.sync.sync();
    } catch (_) {
      if (mounted) toast(context, 'Нет связи с сервером');
    }
  }

  /// Локальный режим → сервер: экран подключения; задачи этого устройства переедут на сервер.
  Future<void> _connectServer() async {
    final nav = Navigator.of(context);
    nav.pop();
    await nav.push(MaterialPageRoute<void>(builder: (_) => const LoginScreen(fromLocal: true)));
  }

  /// Выйти из пользователя (сервер) — снова экран входа; задачи этого устройства убираются.
  Future<void> _signOut() async {
    if (!await confirm(context, 'Выйти?', text: 'Задачи останутся на сервере. С этого устройства они будут убраны до следующего входа.', ok: 'Выйти')) return;
    if (!mounted) return;
    Navigator.pop(context);
    await app.repo.signOut();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([app.repo, app.sync]),
      builder: (context, _) {
        final repo = app.repo;
        final me = repo.meUser;
        final muted = mutedOf(context);
        final dark = Theme.of(context).brightness == Brightness.dark;
        final bg = backgroundBytes(repo);
        final cs = Theme.of(context).colorScheme;
        // данные подключения отдаёт сервер; если он их не знает, берём те, по которым подключено это устройство
        var connectUrl = (_connect?['url'] ?? '').toString();
        if (connectUrl.isEmpty) connectUrl = isWebTransport ? Uri.base.origin : repo.serverUrl;
        var connectKey = (_connect?['key'] ?? '').toString();
        if (connectKey.isEmpty && repo.accessKey.isNotEmpty) connectKey = [repo.accessKey, if (repo.pin.isNotEmpty) repo.pin].join('.');
        Widget title(String s) => Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 8),
          child: Text(s, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        );

        return Dialog(
          insetPadding: const EdgeInsets.all(14),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520, maxHeight: 760),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 8, 4),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text('Настройки', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                      ),
                      IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    children: [
                      // без сервера: подключиться к серверу можно в любой момент
                      if (repo.isLocal)
                        Plate(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Без сервера', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                              const SizedBox(height: 2),
                              Text(
                                'Задачи хранятся только на этом устройстве. После подключения к серверу они переедут туда, '
                                'появятся синхронизация и совместная работа.',
                                style: TextStyle(fontSize: 12, color: muted),
                              ),
                              const SizedBox(height: 10),
                              FilledButton.tonalIcon(
                                onPressed: _connectServer,
                                icon: const Icon(Icons.cloud_outlined, size: 18),
                                label: const Text('Подключиться к серверу'),
                              ),
                            ],
                          ),
                        )
                      else ...[
                        // пользователь
                        Plate(
                          child: Row(
                            children: [
                              InkWell(
                                customBorder: const CircleBorder(),
                                onTap: (_busy || repo.detached) ? null : _changeAvatar,
                                child: Stack(
                                  children: [
                                    UserAvatar(me, size: 56),
                                    Positioned(
                                      right: 0,
                                      bottom: 0,
                                      child: CircleAvatar(
                                        radius: 10,
                                        backgroundColor: Theme.of(context).colorScheme.primary,
                                        child: Icon(Icons.edit, size: 12, color: Theme.of(context).colorScheme.onPrimary),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(me?.name ?? '—', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                                    Text(
                                      repo.detached
                                          ? 'Пользователь удалён на сервере: синхронизация остановлена'
                                          : (repo.isAdmin ? 'Администратор' : 'Пользователь'),
                                      style: TextStyle(fontSize: 12, color: muted),
                                    ),
                                  ],
                                ),
                              ),
                              OutlinedButton(onPressed: () => _switchUser(context), child: const Text('Сменить')),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            if (!repo.detached)
                              OutlinedButton.icon(
                                onPressed: () => showChangePassword(context),
                                icon: const Icon(Icons.key_outlined, size: 18),
                                label: const Text('Пароль'),
                              ),
                            if (repo.isAdmin && !repo.detached)
                              OutlinedButton.icon(
                                onPressed: () => showUsers(context),
                                icon: const Icon(Icons.group_outlined, size: 18),
                                label: const Text('Пользователи'),
                              ),
                            TextButton.icon(onPressed: _signOut, icon: const Icon(Icons.logout, size: 18), label: const Text('Выйти')),
                          ],
                        ),
                      ],

                      title('Внешний вид'),
                      SegmentedButton<String>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: 'system', label: Text('Как в системе')),
                          ButtonSegment(value: 'light', label: Text('Светлая')),
                          ButtonSegment(value: 'dark', label: Text('Тёмная')),
                        ],
                        selected: {repo.setting<String>('theme', 'system')},
                        onSelectionChanged: (s) => repo.setSetting('theme', s.first),
                      ),
                      const SizedBox(height: 12),
                      Plate(
                        padding: EdgeInsets.zero,
                        child: Column(
                          children: [
                            _ColorRow(
                              label: 'Акцентный цвет',
                              color: parseHex(repo.setting<String>('accent', ''), defaultAccent),
                              onTap: () => _pickColor('accent', 'Акцентный цвет', defaultAccent, accentPresets),
                            ),
                            const Divider(indent: 12),
                            _ColorRow(
                              label: 'Цвет подложек',
                              color: parseHex(repo.setting<String>(dark ? 'plate_dark' : 'plate', ''), defaultPlate(dark)),
                              onTap: () => _pickColor(dark ? 'plate_dark' : 'plate', 'Цвет подложек', defaultPlate(dark), platePresets(dark)),
                            ),
                            const Divider(indent: 12),
                            _ColorRow(
                              label: 'Цвет окантовок',
                              color: parseHex(repo.setting<String>(dark ? 'border_dark' : 'border', ''), defaultBorder(dark)),
                              onTap: () => _pickColor(dark ? 'border_dark' : 'border', 'Цвет окантовок', defaultBorder(dark), borderPresets(dark)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Plate(
                        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                if (bg != null)
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: Image.memory(bg, width: 48, height: 32, fit: BoxFit.cover, gaplessPlayback: true),
                                  )
                                else
                                  Icon(Icons.image_outlined, size: 20, color: muted),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text('Фоновая картинка'),
                                      Text('Хранится только на этом устройстве', style: TextStyle(fontSize: 12, color: muted)),
                                    ],
                                  ),
                                ),
                                if (bg != null)
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline, size: 20),
                                    tooltip: 'Убрать картинку',
                                    onPressed: () => repo.setLocal('bg_image', null),
                                  ),
                                TextButton(onPressed: _busy ? null : _pickBackground, child: Text(bg == null ? 'Выбрать' : 'Заменить')),
                              ],
                            ),
                            if (bg != null)
                              Row(
                                children: [
                                  Text('Приглушение', style: TextStyle(fontSize: 13, color: muted)),
                                  Expanded(
                                    child: Slider(
                                      value: backgroundDim(repo) * 100,
                                      max: 90,
                                      onChanged: (v) => repo.setLocal('bg_dim', v.round().toString(), persist: false),
                                      onChangeEnd: (v) => repo.setLocal('bg_dim', v.round().toString()),
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),

                      if (app.platform.hasHomeWidget) ...[
                        title('Виджет'),
                        if (!repo.isLocal) ...[
                          SegmentedButton<String>(
                            showSelectedIcon: false,
                            segments: const [
                              ButtonSegment(value: 'all', label: Text('Все задачи')),
                              ButtonSegment(value: 'mine', label: Text('Только свои')),
                            ],
                            selected: {widgetMineOnly(repo) ? 'mine' : 'all'},
                            onSelectionChanged: (s) async {
                              await repo.setLocal('w_scope', s.first == 'mine' ? 'mine' : null);
                              await app.platform.refresh(repo);
                            },
                          ),
                          const SizedBox(height: 10),
                        ],
                        Text(
                          'Незаданные цвета берутся из палитры системы и меняются вместе со светлой и тёмной темой.',
                          style: TextStyle(fontSize: 12, color: muted),
                        ),
                        const SizedBox(height: 8),
                        Plate(
                          padding: EdgeInsets.zero,
                          child: Column(
                            children: [
                              for (final (i, (key, label, def, presets)) in [
                                ('w_bg', 'Фон', cs.surface, platePresets(dark)),
                                ('w_border', 'Окантовка', borderOf(context), borderPresets(dark)),
                                ('w_text', 'Текст', cs.onSurface, const ['#2B2A26', '#000000', '#EDE9E0', '#FFFFFF']),
                                ('w_accent', 'Заголовок, плюс и звёздочки', cs.primary, accentPresets),
                              ].indexed) ...[
                                if (i > 0) const Divider(indent: 12),
                                _ColorRow(
                                  label: label,
                                  color: parseHex(repo.kv[key], def),
                                  note: (repo.kv[key] ?? '').isEmpty ? 'Системный' : null,
                                  onTap: () => _pickWidgetColor(key, 'Виджет: ${label.toLowerCase()}', def, presets),
                                ),
                              ],
                              const Divider(indent: 12),
                              Padding(
                                padding: const EdgeInsets.only(left: 12),
                                child: Row(
                                  children: [
                                    const Text('Непрозрачность фона'),
                                    Expanded(
                                      child: Slider(
                                        value: widgetAlpha(repo).toDouble(),
                                        max: 100,
                                        onChanged: (v) => repo.setLocal('w_alpha', v.round().toString(), persist: false),
                                        onChangeEnd: (v) async {
                                          await repo.setLocal('w_alpha', v.round().toString());
                                          await app.platform.refresh(repo);
                                        },
                                      ),
                                    ),
                                    SizedBox(
                                      width: 44,
                                      child: Text('${widgetAlpha(repo)} %', style: TextStyle(fontSize: 12, color: muted)),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          children: [
                            OutlinedButton(onPressed: _widgetLikeApp, child: const Text('Как в приложении')),
                            TextButton(onPressed: _widgetReset, child: const Text('Сбросить')),
                          ],
                        ),
                      ],

                      title('Уведомления'),
                      Plate(
                        onTap: () async {
                          final t = await pickTime(context, repo.deadlineTime);
                          if (t != null) repo.setSetting('deadline_time', t);
                        },
                        child: Row(
                          children: [
                            const Icon(Icons.schedule, size: 20),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(isWebTransport ? 'Стандартное время уведомлений по сегодняшним задачам (на ПК и телефоне)' : 'Стандартное время уведомлений по сегодняшним задачам'),
                            ),
                            Text(repo.deadlineTime, style: const TextStyle(fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),

                      title('Основной список'),
                      SelectField(
                        helper: 'Открывается при запуске',
                        text: app.sectionTitle(_homeValue(repo)),
                        onTap: () async {
                          final v = await pickOption<String>(
                            context,
                            title: 'Основной список',
                            current: _homeValue(repo),
                            options: [
                              const Option(secToday, 'Сегодняшний день', leading: Icon(Icons.wb_sunny_outlined, size: 20)),
                              const Option(secImportant, 'Важные', leading: Icon(Icons.star_border, size: 20)),
                              const Option(secSchedule, 'Планирование', leading: Icon(Icons.date_range_outlined, size: 20)),
                              const Option(secTasks, 'Задачи', leading: Icon(Icons.home_outlined, size: 20)),
                              const Option(secPrivate, 'Мои дела', leading: Icon(Icons.lock_outline, size: 20)),
                              for (final l in repo.visibleLists)
                                Option(l.id, l.name.isEmpty ? 'Без названия' : l.name, leading: const Icon(Icons.list_alt_outlined, size: 20)),
                            ],
                          );
                          if (v != null) repo.setSetting('home_list', v);
                        },
                      ),

                      if (!repo.isLocal)
                        Padding(
                          padding: const EdgeInsets.only(top: 14),
                          child: Text(_syncInfo(), style: TextStyle(fontSize: 12, color: muted)),
                        ),

                      // адрес сервера и ключ доступа видны только администраторам
                      if (!repo.isLocal && repo.isAdmin && connectUrl.isNotEmpty) ...[
                        title('Подключение приложений'),
                        Text(
                          'Их вводят при первом запуске приложения на ПК и телефоне; в браузере — только ключ.',
                          style: TextStyle(fontSize: 12, color: muted),
                        ),
                        const SizedBox(height: 8),
                        _CopyRow(label: 'Адрес сервера', value: connectUrl),
                        const SizedBox(height: 6),
                        _CopyRow(label: 'Ключ доступа', value: connectKey),
                      ],
                      if (!repo.isLocal && repo.isAdmin && !isWebTransport) ...[
                        const SizedBox(height: 12),
                        Text('Адрес сервера на этом устройстве', style: TextStyle(fontSize: 13, color: muted)),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _server,
                                decoration: const InputDecoration(hintText: 'https://адрес:порт'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.tonal(
                              onPressed: () async {
                                await repo.setKv('server_url', normalizeUrl(_server.text));
                                final ok = await app.sync.sync();
                                if (context.mounted) toast(context, ok ? 'Сервер доступен' : 'Не удалось подключиться');
                              },
                              child: const Text('Сохранить'),
                            ),
                          ],
                        ),
                      ],

                      if (!repo.isLocal && repo.isAdmin) ...[
                        title('Администратор'),
                        Plate(
                          padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
                          child: Row(
                            children: [
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Режим администратора'),
                                    Text(
                                      'Можно править любые общие задачи и списки. Чужие приватные задачи не видны и в этом режиме.',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                              Switch(value: repo.setting<bool>('admin_mode', false), onChanged: (v) => repo.setSetting('admin_mode', v)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _retention,
                                keyboardType: TextInputType.number,
                                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                decoration: const InputDecoration(labelText: 'Срок жизни завершённых, дней', helperText: 'Потом удаляются с сервера'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _tz,
                                decoration: const InputDecoration(labelText: 'Часовой пояс', hintText: 'Europe/Moscow', helperText: 'Пусто — по устройству'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: FilledButton.tonal(onPressed: _saveAdmin, child: const Text('Сохранить параметры сервера')),
                        ),
                      ],
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

  String _homeValue(Repo repo) {
    final h = repo.homeSection;
    if (isBuiltinSection(h)) return h;
    return repo.visibleLists.any((l) => l.id == h) ? h : secToday;
  }

  String _syncInfo() {
    final s = app.sync;
    final ok = s.lastOk;
    final last = ok == null ? 'ещё не было' : '${fmtTime(ok.hour, ok.minute)}';
    return 'Последняя синхронизация: $last${s.lastError.isEmpty ? '' : ' · нет связи'}';
  }

  Future<void> _switchUser(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Сменить пользователя'),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Задачи прежнего пользователя будут убраны с этого устройства (на сервере они останутся).',
                  style: TextStyle(fontSize: 12, color: mutedOf(context)),
                ),
                const SizedBox(height: 12),
                UserPicker(onDone: () => Navigator.pop(c)),
              ],
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Отмена'))],
      ),
    );
    if (context.mounted && !isBuiltinSection(app.section) && !app.repo.lists.containsKey(app.section)) app.openSection(secToday);
  }
}

/// Строка с образцом цвета; по нажатию открывается палитра.
class _ColorRow extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;
  final String? note; // подпись вместо кода цвета, когда свой цвет не задан
  const _ColorRow({required this.label, required this.color, required this.onTap, this.note});
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(note ?? toHex(color), style: TextStyle(fontSize: 12, color: mutedOf(context))),
          const SizedBox(width: 10),
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: note == null ? color : Colors.transparent,
              shape: BoxShape.circle,
              border: Border.all(color: borderOf(context), width: 1.5),
            ),
          ),
        ],
      ),
    ),
  );
}

class _CopyRow extends StatelessWidget {
  final String label, value;
  const _CopyRow({required this.label, required this.value});
  @override
  Widget build(BuildContext context) => Plate(
    padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(fontSize: 12, color: mutedOf(context))),
              SelectableText(value, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.copy, size: 18),
          tooltip: 'Скопировать',
          onPressed: () async {
            final ok = await copyText(value);
            if (context.mounted) toast(context, ok ? 'Скопировано' : 'Не удалось скопировать: выделите текст и скопируйте вручную');
          },
        ),
      ],
    ),
  );
}
