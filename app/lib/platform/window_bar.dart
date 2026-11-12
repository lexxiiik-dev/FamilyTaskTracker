// Верхняя панель окна Windows в оформлении приложения: системный заголовок скрыт,
// окно перетаскивается за эту панель, кнопки «свернуть / развернуть / закрыть» свои.
import 'package:flutter/material.dart';
import 'package:window_manager/legacy.dart';

class WindowBar extends StatefulWidget {
  const WindowBar({super.key});
  @override
  State<WindowBar> createState() => _WindowBarState();
}

class _WindowBarState extends State<WindowBar> with WindowListener {
  bool _max = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager
        .isMaximized()
        .then((v) {
          if (mounted) setState(() => _max = v);
        })
        .catchError((_) {});
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _max = true);
  @override
  void onWindowUnmaximize() => setState(() => _max = false);

  Future<void> _toggle() async => await windowManager.isMaximized() ? windowManager.unmaximize() : windowManager.maximize();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = cs.onSurface.withValues(alpha: 0.65);
    return Material(
      type: MaterialType.transparency,
      child: SizedBox(
        height: 34,
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => windowManager.startDragging(),
                onDoubleTap: _toggle,
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    ClipRRect(borderRadius: BorderRadius.circular(4), child: Image.asset('assets/icon.png', width: 16, height: 16)),
                    const SizedBox(width: 8),
                    Text(
                      'Задачи',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: muted),
                    ),
                  ],
                ),
              ),
            ),
            _Button(glyph: _Glyph.minimize, onTap: () => windowManager.minimize()),
            _Button(glyph: _max ? _Glyph.restore : _Glyph.maximize, onTap: _toggle),
            _Button(glyph: _Glyph.close, danger: true, onTap: () => windowManager.close()), // крестик сворачивает в трей
          ],
        ),
      ),
    );
  }
}

class _Button extends StatefulWidget {
  final _Glyph glyph;
  final bool danger;
  final VoidCallback onTap;
  const _Button({required this.glyph, required this.onTap, this.danger = false});
  @override
  State<_Button> createState() => _ButtonState();
}

class _ButtonState extends State<_Button> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final red = widget.danger && _hover;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          width: 46,
          height: 34,
          color: red ? const Color(0xFFC42B1C) : (_hover ? cs.onSurface.withValues(alpha: 0.10) : Colors.transparent),
          child: CustomPaint(painter: _GlyphPainter(widget.glyph, red ? Colors.white : cs.onSurface.withValues(alpha: 0.8))),
        ),
      ),
    );
  }
}

enum _Glyph { minimize, maximize, restore, close }

/// Значки кнопок окна нарисованы линиями, как системные: не зависят от шрифта значков.
class _GlyphPainter extends CustomPainter {
  final _Glyph glyph;
  final Color color;
  const _GlyphPainter(this.glyph, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final c = Offset(size.width / 2, size.height / 2);
    const h = 5.0; // половина стороны значка
    switch (glyph) {
      case _Glyph.minimize:
        canvas.drawLine(c + const Offset(-h, 0), c + const Offset(h, 0), p);
      case _Glyph.maximize:
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: c, width: h * 2, height: h * 2), const Radius.circular(1.5)), p);
      case _Glyph.restore:
        const d = 2.0;
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(c.dx - h, c.dy - h + d, c.dx + h - d, c.dy + h), const Radius.circular(1.5)), p);
        canvas.drawPath(
          Path()
            ..moveTo(c.dx - h + d, c.dy - h + d)
            ..lineTo(c.dx - h + d, c.dy - h)
            ..lineTo(c.dx + h, c.dy - h)
            ..lineTo(c.dx + h, c.dy + h - d)
            ..lineTo(c.dx + h - d, c.dy + h - d),
          p,
        );
      case _Glyph.close:
        canvas.drawLine(c + const Offset(-h, -h), c + const Offset(h, h), p);
        canvas.drawLine(c + const Offset(h, -h), c + const Offset(-h, h), p);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.glyph != glyph || old.color != color;
}
