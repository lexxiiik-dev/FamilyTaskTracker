import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'transport.dart';

const isWeb = true;
Transport createTransport(ServerConfig cfg) => WebTransport(cfg);

/// Веб-клиент ходит к серверу, который его отдал: `<адрес страницы>/v1/...`.
class WebTransport implements Transport {
  final ServerConfig cfg;
  final _hc = http.Client();
  WebTransport(this.cfg);

  @override
  Future<Resp> send(String method, String path, {Object? body}) async {
    final req = http.Request(method, Uri.base.resolve(path));
    req.headers['X-Access-Key'] = cfg.accessKey;
    if (cfg.token.isNotEmpty) req.headers['Authorization'] = 'Bearer ${cfg.token}';
    if (body is Uint8List) {
      req.headers['Content-Type'] = 'application/octet-stream';
      req.bodyBytes = body;
    } else if (body != null) {
      req.headers['Content-Type'] = 'application/json; charset=utf-8';
      req.bodyBytes = utf8.encode(jsonEncode(body));
    }
    final resp = await http.Response.fromStream(await _hc.send(req).timeout(const Duration(seconds: 30)));
    return Resp(resp.statusCode, resp.bodyBytes);
  }

  @override
  void close() => _hc.close();
}
