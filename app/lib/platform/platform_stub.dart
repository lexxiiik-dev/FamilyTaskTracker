import 'package:flutter/widgets.dart';

import '../app.dart';
import '../core/repo.dart';
import 'platform.dart';

PlatformHooks createPlatform() => NoopPlatform();

class NoopPlatform implements PlatformHooks {
  @override
  String get deviceName => 'device';
  @override
  Duration? get backgroundPeriod => null;
  @override
  bool get managesActivity => false;
  @override
  bool get hasHomeWidget => false;
  @override
  Future<bool> preflight(List<String> args) async => true;
  @override
  Future<void> init(AppState app) async {}
  @override
  Widget? titleBar() => null;
  @override
  Future<void> refresh(Repo repo) async {}
}
