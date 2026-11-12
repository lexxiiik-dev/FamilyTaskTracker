// Генерация значков приложения для всех платформ:  dart run tool/gen_icons.dart
// Значок — объёмная зелёная галочка без подложки. Android 8+ берёт адаптивный значок
// из res/mipmap-anydpi-v26 (векторный, рисуется отдельно), здесь — растровые значки остальных платформ.
import 'dart:io';
import 'dart:math';

import 'package:image/image.dart' as img;

// галочка в долях стороны: левый конец, излом, правый конец
const _a = (0.20, 0.53), _b = (0.41, 0.73), _c = (0.81, 0.30);

img.ColorRgba8 _mix(List<int> x, List<int> y, double f, [int a = 255]) =>
    img.ColorRgba8((x[0] + (y[0] - x[0]) * f).round(), (x[1] + (y[1] - x[1]) * f).round(), (x[2] + (y[2] - x[2]) * f).round(), a);

/// Галочка с переливом от тёмно-зелёного к светлому и мягкой тенью.
/// [plate] — зелёная подложка под белой галочкой (для maskable-значков веб-версии, которые система обрезает).
img.Image draw(int size, {bool plate = false}) {
  const k = 4; // рисуем крупнее и уменьшаем: сглаживание
  final s = size * k;
  final im = img.Image(width: s, height: s, numChannels: 4);
  final pad = plate ? 0.16 : (size <= 24 ? 0.0 : 0.04);
  if (plate) img.fill(im, color: img.ColorRgba8(0x3F, 0x6B, 0x4A, 255));
  final inner = s * (1 - 2 * pad), p = s * pad;
  // мелкие значки (трей, вкладка) — штрих толще, чтобы читался
  final w = inner * (size <= 24 ? 0.21 : size <= 48 ? 0.18 : 0.155);
  const dark = [0x2E, 0x6B, 0x41], light = [0x7C, 0xCF, 0x8E];

  void stroke(img.Image on, double dx, double dy, img.Color Function(double f) color, double width, {double from = 0, double to = 1}) {
    final pts = [_a, _b, _c];
    final lens = [for (var i = 0; i < 2; i++) sqrt(pow(pts[i + 1].$1 - pts[i].$1, 2) + pow(pts[i + 1].$2 - pts[i].$2, 2))];
    final total = lens[0] + lens[1];
    var done = 0.0;
    for (var i = 0; i < 2; i++) {
      final (x1, y1) = pts[i];
      final (x2, y2) = pts[i + 1];
      final steps = (lens[i] * inner).ceil();
      for (var j = 0; j <= steps; j++) {
        final f = j / steps;
        final along = (done + lens[i] * f) / total;
        if (along < from || along > to) continue;
        img.fillCircle(on,
            x: (p + inner * (x1 + (x2 - x1) * f) + dx).round(),
            y: (p + inner * (y1 + (y2 - y1) * f) + dy).round(),
            radius: (width / 2).round(),
            color: color(along));
      }
      done += lens[i];
    }
  }

  /// Полупрозрачный слой рисуется отдельно и накладывается целиком: иначе прозрачность
  /// перекрывающихся кругов накапливается и тень с бликом получаются непрозрачными.
  void layer(int alpha, void Function(img.Image l) paint) {
    final l = img.Image(width: s, height: s, numChannels: 4);
    paint(l);
    for (final px in l) {
      if (px.a > 0) px.a = px.a * alpha ~/ 255;
    }
    img.compositeImage(im, l);
  }

  if (plate) {
    stroke(im, 0, 0, (_) => img.ColorRgba8(255, 255, 255, 255), w);
  } else {
    final big = size > 32;
    if (big) layer(55, (l) => stroke(l, 0, w * 0.16, (_) => img.ColorRgba8(0x0E, 0x2A, 0x17, 255), w * 1.02)); // тень
    stroke(im, 0, 0, (f) => _mix(dark, light, f), w);
    // мягкий блик вдоль длинного плеча
    if (big) layer(60, (l) => stroke(l, -w * 0.10, -w * 0.14, (_) => img.ColorRgba8(255, 255, 255, 255), w * 0.22, from: 0.55, to: 0.88));
  }  return img.copyResize(im, width: size, height: size, interpolation: img.Interpolation.average);
}

void png(String path, img.Image im) {
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(img.encodePng(im));
}

void ico(String path, List<int> sizes) {
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(img.IcoEncoder().encodeImages([for (final s in sizes) draw(s)]));
}

void main() {
  ico('assets/tray.ico', [16, 20, 24, 32, 48]);
  ico('windows/runner/resources/app_icon.ico', [16, 24, 32, 48, 64, 128, 256]);
  png('web/favicon.png', draw(32));
  png('web/icons/Icon-192.png', draw(192));
  png('web/icons/Icon-512.png', draw(512));
  png('web/icons/Icon-maskable-192.png', draw(192, plate: true));
  png('web/icons/Icon-maskable-512.png', draw(512, plate: true));
  const mip = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192};
  for (final e in mip.entries) {
    png('android/app/src/main/res/mipmap-${e.key}/ic_launcher.png', draw(e.value));
  }
  png('assets/icon.png', draw(256));
  png('build/icon-preview.png', draw(512));
  stdout.writeln('значки созданы');
}
