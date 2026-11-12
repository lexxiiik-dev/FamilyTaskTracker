import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'transport.dart';

const isWeb = false;
Transport createTransport(ServerConfig cfg) => IoTransport(cfg);

/// Отпечаток открытого ключа: base64url(SHA-256(SubjectPublicKeyInfo)) из DER-сертификата.
String spkiPin(Uint8List der) {
  // минимальный разбор ASN.1: Certificate -> tbsCertificate -> 7-й элемент (после необязательной версии)
  (int tag, int start, int end, int next) tlv(int pos) {
    final tag = der[pos];
    var len = der[pos + 1];
    var p = pos + 2;
    if (len & 0x80 != 0) {
      final n = len & 0x7f;
      len = 0;
      for (var i = 0; i < n; i++) {
        len = (len << 8) | der[p++];
      }
    }
    return (tag, p, p + len, p + len);
  }

  final cert = tlv(0);
  final tbs = tlv(cert.$2);
  var pos = tbs.$2;
  var idx = 0;
  while (pos < tbs.$3) {
    final el = tlv(pos);
    if (el.$1 == 0xA0) {
      pos = el.$4; // [0] версия
      continue;
    }
    if (idx == 5) {
      final spki = Uint8List.sublistView(der, pos, el.$3);
      return base64Url.encode(sha256.convert(spki).bytes).replaceAll('=', '');
    }
    idx++;
    pos = el.$4;
  }
  throw const FormatException('в сертификате не найден открытый ключ');
}

class IoTransport implements Transport {
  final ServerConfig cfg;
  late final HttpClient _hc;

  IoTransport(this.cfg) {
    if (cfg.pin.isEmpty) {
      // обычный сертификат (сервер за прокси): проверка системными центрами сертификации
      _hc = HttpClient()
        ..connectionTimeout = const Duration(seconds: 12)
        ..idleTimeout = const Duration(seconds: 20);
      return;
    }
    // пустой контекст: системным центрам сертификации не доверяем, только закреплённому ключу
    _hc = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = const Duration(seconds: 12)
      ..idleTimeout = const Duration(seconds: 20)
      ..badCertificateCallback = (cert, host, port) {
        try {
          return spkiPin(cert.der) == cfg.pin;
        } catch (_) {
          return false;
        }
      };
  }

  @override
  Future<Resp> send(String method, String path, {Object? body}) async {
    final req = await _hc.openUrl(method, Uri.parse(cfg.url + path)).timeout(const Duration(seconds: 15));
    req.headers.set('X-Access-Key', cfg.accessKey);
    if (cfg.token.isNotEmpty) req.headers.set('Authorization', 'Bearer ${cfg.token}');
    if (body is Uint8List) {
      req.headers.contentType = ContentType.binary;
      req.add(body);
    } else if (body != null) {
      req.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
      req.add(utf8.encode(jsonEncode(body)));
    }
    final resp = await req.close().timeout(const Duration(seconds: 45));
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in resp.timeout(const Duration(seconds: 45))) {
      bytes.add(chunk);
    }
    return Resp(resp.statusCode, bytes.takeBytes());
  }

  @override
  void close() => _hc.close(force: true);
}
