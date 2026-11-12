// Запуск настоящего сервера (test/bin/todod.exe собирается из ../server) для тестов клиента.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/core/transport.dart';

/// ID пользователей выдаёт сервер: заполняются в [TestServer.withUsers].
late String uA, uB, uC;
const adminPassword = 'secret';

class TestServer {
  final Process proc;
  final String url;
  final String pin;
  final String accessKey;
  String adminToken = '';
  TestServer(this.proc, this.url, this.pin, this.accessKey);

  static final bin = Platform.environment['TODO_TEST_BIN'] ?? File('test/bin/todod.exe').absolute.path;

  /// Пустой сервер (пользователей нет). Настройки и сертификат создаёт `todod init`.
  static Future<TestServer> start(Directory dir, int port) async {
    final cfgDir = Directory('${dir.path}/p$port')..createSync(recursive: true);
    final r = await Process.run(bin, ['init', '-dir', cfgDir.path, '-data', cfgDir.path, '-port', '$port']);
    if (r.exitCode != 0) throw Exception('init: ${r.stderr}');
    final cfgFile = File('${cfgDir.path}/config.json');
    final cfg = jsonDecode(cfgFile.readAsStringSync()) as Map<String, dynamic>;
    cfg['listen'] = '127.0.0.1:$port'; // только локально: без запроса брандмауэра
    cfgFile.writeAsStringSync(jsonEncode(cfg));
    final pin = ((await Process.run(bin, ['pin', cfg['cert'] as String])).stdout as String).trim();
    final proc = await Process.start(bin, ['-config', cfgFile.path]);
    proc.stderr.drain<void>();
    proc.stdout.drain<void>();
    final s = TestServer(proc, 'https://127.0.0.1:$port', pin, cfg['access_key'] as String);
    for (var i = 0; i < 100; i++) {
      try {
        if ((await s.send('GET', '/v1/hello')).ok) return s;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw Exception('сервер не запустился');
  }

  /// Сервер с пользователями: администратор «Админ» (пароль [adminPassword]), Боб и Клара без паролей.
  static Future<TestServer> withUsers(Directory dir, int port) async {
    final s = await start(dir, port);
    final r = await s.send('POST', '/v1/setup', body: {'name': 'Админ', 'password': adminPassword, 'device': 'test'});
    expect(r.ok, isTrue, reason: r.error);
    s.adminToken = r.json['token'] as String;
    uA = r.json['user_id'] as String;
    uB = await s.addUser('Боб');
    uC = await s.addUser('Клара');
    return s;
  }

  Future<String> addUser(String name) async {
    final r = await admin('POST', '/v1/admin/users', body: {'name': name, 'password': ''});
    expect(r.ok, isTrue, reason: r.error);
    return (r.json['user'] as Map)['id'] as String;
  }

  Future<Resp> send(String method, String path, {Object? body, String token = ''}) async {
    final t = createTransport(ServerConfig(url: url, accessKey: accessKey, pin: pin, token: token));
    try {
      return await t.send(method, path, body: body);
    } finally {
      t.close();
    }
  }

  Future<Resp> admin(String method, String path, {Object? body}) => send(method, path, body: body, token: adminToken);
}
