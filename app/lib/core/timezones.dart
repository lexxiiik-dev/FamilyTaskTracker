// Часовые пояса: база поясов и пояс устройства. Даты задач считаются по поясу из настроек сервера,
// а если он не задан (и в локальном режиме) — по поясу устройства.
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

Future<void> initTimeZones() async {
  tzdata.initializeTimeZones();
  try {
    final info = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(info.identifier));
  } catch (_) {
    // пояс устройства неизвестен базе — остаётся UTC
  }
}
