// Связь с сервером.
//   Windows/Android: HTTPS. Если в ключе доступа есть отпечаток ключа сервера (самоподписанный
//   сертификат), проверяется только он, без имени хоста; иначе — обычная проверка сертификата.
//   Веб: страницу отдаёт сам сервер, запросы идут на тот же адрес.
import 'dart:convert';
import 'dart:typed_data';

import 'transport_stub.dart' if (dart.library.io) 'transport_io.dart' if (dart.library.js_interop) 'transport_web.dart' as impl;

class Resp {
  final int status;
  final Uint8List body;
  Resp(this.status, this.body);
  bool get ok => status == 200;
  Map<String, dynamic> get json {
    try {
      final v = jsonDecode(utf8.decode(body));
      return v is Map<String, dynamic> ? v : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  String get error => (json['error'] ?? 'HTTP $status').toString();
}

class ServerConfig {
  final String url; // https://1.2.3.4:8443 (в вебе — адрес страницы)
  final String accessKey;
  final String pin;
  final String token;
  const ServerConfig({this.url = '', this.accessKey = '', this.pin = '', this.token = ''});
}

abstract class Transport {
  /// [path] начинается с /v1/...; [body] — Map/List (JSON) или Uint8List (как есть).
  Future<Resp> send(String method, String path, {Object? body});
  void close();
}

Transport createTransport(ServerConfig cfg) => impl.createTransport(cfg);

/// true — приложение работает в браузере (сервер — тот же адрес, что и страница).
bool get isWebTransport => impl.isWeb;

/// «Ключ доступа», который вводит пользователь: `<ключ>.<отпечаток ключа сервера>` или просто `<ключ>`
/// (сервер за обратным прокси с обычным сертификатом).
(String key, String pin) splitAccessKey(String s) {
  final i = s.trim().indexOf('.');
  if (i < 0) return (s.trim(), '');
  return (s.trim().substring(0, i), s.trim().substring(i + 1));
}

String normalizeUrl(String s) {
  s = s.trim();
  if (s.isEmpty) return s;
  if (!s.contains('://')) s = 'https://$s';
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}
