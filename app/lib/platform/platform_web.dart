import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import '../app.dart';
import '../core/repo.dart';
import 'platform.dart';

PlatformHooks createPlatform() => WebPlatform();

/// Веб-версия: уведомлений нет (чтобы не дублировать уведомления с ПК и телефона).
class WebPlatform implements PlatformHooks {
  String _themeColor = '';

  @override
  String get deviceName => 'web';
  @override
  Duration? get backgroundPeriod => null;
  @override
  bool get managesActivity => false;
  @override
  bool get hasHomeWidget => false;
  @override
  Future<bool> preflight(List<String> args) async => true;
  @override
  Future<void> init(AppState app) async {
    app.repo.addListener(() => _applyThemeColor(app.repo));
    _applyThemeColor(app.repo);
  }

  /// Адресная строка браузера на телефоне красится в акцентный цвет пользователя.
  /// Пока пользователь не известен (экран входа), строка не красится вовсе.
  void _applyThemeColor(Repo repo) {
    final accent = repo.setting<String>('accent', '');
    final color = !repo.loggedIn ? '' : (RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(accent) ? accent : '#3F6B4A');
    if (color == _themeColor) return;
    _themeColor = color;
    var meta = web.document.querySelector('meta[name="theme-color"]');
    if (color.isEmpty) {
      meta?.remove();
      return;
    }
    if (meta == null) {
      meta = web.document.createElement('meta')..setAttribute('name', 'theme-color');
      web.document.head!.append(meta);
    }
    meta.setAttribute('content', color);
  }

  @override
  Widget? titleBar() => null;
  @override
  Future<void> refresh(Repo repo) async {}
}
