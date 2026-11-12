// Палитра выбора цвета: поле «насыщенность × яркость», полоса оттенков, готовые цвета и код #RRGGBB.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'common.dart';

/// Возвращает цвет в виде #RRGGBB, пустую строку для «по умолчанию» или null, если выбор отменён.
Future<String?> pickColor(BuildContext context, {required String title, required Color initial, List<String> presets = const [], bool canReset = false}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _ColorDialog(title: title, initial: initial, presets: presets, canReset: canReset),
    );

class _ColorDialog extends StatefulWidget {
  final String title;
  final Color initial;
  final List<String> presets;
  final bool canReset;
  const _ColorDialog({required this.title, required this.initial, required this.presets, required this.canReset});
  @override
  State<_ColorDialog> createState() => _ColorDialogState();
}

class _ColorDialogState extends State<_ColorDialog> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);
  late final _hex = TextEditingController(text: toHex(widget.initial));

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _set(HSVColor c) {
    setState(() => _hsv = c);
    _hex.text = toHex(c.toColor());
  }

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();
    final border = borderOf(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 300,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // насыщенность по горизонтали, яркость по вертикали
              LayoutBuilder(
                builder: (c, box) {
                  final w = box.maxWidth;
                  const h = 170.0;
                  void at(Offset p) => _set(_hsv.withSaturation((p.dx / w).clamp(0.0, 1.0)).withValue(1 - (p.dy / h).clamp(0.0, 1.0)));
                  return GestureDetector(
                    key: const ValueKey('color-field'),
                    behavior: HitTestBehavior.opaque,
                    onPanDown: (d) => at(d.localPosition),
                    onPanUpdate: (d) => at(d.localPosition),
                    child: SizedBox(
                      width: w,
                      height: h,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned.fill(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: DecoratedBox(
                                decoration: BoxDecoration(gradient: LinearGradient(colors: [Colors.white, HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor()])),
                                child: const DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [Colors.transparent, Colors.black],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: _hsv.saturation * w - 9,
                            top: (1 - _hsv.value) * h - 9,
                            child: _Thumb(color: color),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 14),
              // оттенок
              LayoutBuilder(
                builder: (c, box) {
                  final w = box.maxWidth;
                  void at(Offset p) => _set(_hsv.withHue((p.dx / w).clamp(0.0, 1.0) * 359.99));
                  return GestureDetector(
                    key: const ValueKey('color-hue'),
                    behavior: HitTestBehavior.opaque,
                    onPanDown: (d) => at(d.localPosition),
                    onPanUpdate: (d) => at(d.localPosition),
                    child: SizedBox(
                      width: w,
                      height: 18,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(9),
                                gradient: LinearGradient(colors: [for (var i = 0; i <= 6; i++) HSVColor.fromAHSV(1, i * 60.0 % 360, 1, 1).toColor()]),
                              ),
                            ),
                          ),
                          Positioned(
                            left: _hsv.hue / 360 * w - 9,
                            top: 0,
                            child: _Thumb(color: HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor()),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: border),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _hex,
                      decoration: const InputDecoration(labelText: 'Код цвета'),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[#0-9a-fA-F]')), LengthLimitingTextInputFormatter(7)],
                      onChanged: (v) {
                        if (RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(v)) setState(() => _hsv = HSVColor.fromColor(parseHex(v, color)));
                      },
                    ),
                  ),
                ],
              ),
              if (widget.presets.isNotEmpty) ...[
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final p in widget.presets)
                      InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => _set(HSVColor.fromColor(parseHex(p, color))),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: parseHex(p, color),
                            shape: BoxShape.circle,
                            border: Border.all(color: toHex(color) == p ? Theme.of(context).colorScheme.onSurface : border, width: toHex(color) == p ? 2.5 : 1),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actionsOverflowButtonSpacing: 4,
      actions: [
        if (widget.canReset) TextButton(onPressed: () => Navigator.pop(context, ''), child: const Text('По умолчанию')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(context, toHex(color)), child: const Text('Готово')),
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  final Color color;
  const _Thumb({required this.color});
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2.5),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 3)],
      ),
    ),
  );
}
