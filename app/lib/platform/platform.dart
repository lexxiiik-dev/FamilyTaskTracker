// Платформенные возможности: уведомления, трей, фоновая синхронизация, виджет.
import 'package:flutter/widgets.dart';

import '../app.dart';
import '../core/repo.dart';
import 'platform_stub.dart' if (dart.library.io) 'platform_io.dart' if (dart.library.js_interop) 'platform_web.dart' as impl;

abstract class PlatformHooks {
  /// Имя устройства для списка устройств на сервере.
  String get deviceName;

  /// Период синхронизации, когда окно неактивно (null — таймер не нужен).
  Duration? get backgroundPeriod;

  /// true — активность окна определяет сама платформа (трей Windows), а не жизненный цикл Flutter.
  bool get managesActivity;

  /// true — на платформе есть виджет рабочего стола (Android): в настройках показывается его оформление.
  bool get hasHomeWidget;

  /// До запуска интерфейса. false — приложение уже запущено, этот экземпляр должен завершиться.
  Future<bool> preflight(List<String> args);

  Future<void> init(AppState app);

  /// Своя верхняя панель окна вместо системной (Windows); null — панель не нужна.
  Widget? titleBar();

  /// После синхронизации и локальных изменений: пересчитать напоминания, обновить виджет.
  Future<void> refresh(Repo repo);
}

PlatformHooks createPlatform() => impl.createPlatform();
