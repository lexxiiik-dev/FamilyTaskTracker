// Локальная база устройства. На Windows и Android — SQLite, в браузере — IndexedDB.
import 'model.dart';
import 'storage_stub.dart' if (dart.library.io) 'storage_io.dart' if (dart.library.js_interop) 'storage_web.dart' as impl;

abstract class Storage {
  Future<void> open();
  Future<Map<String, String>> loadKv();
  Future<void> putKv(String k, String? v);
  Future<List<Ent>> loadEnts();
  Future<void> putEnts(Iterable<Ent> ents);
  Future<void> deleteEnts(Iterable<Ent> ents);
  Future<void> close();
}

Storage openPlatformStorage() => impl.createStorage();

/// Хранилище в памяти — для тестов.
class MemoryStorage implements Storage {
  final Map<String, String> kv = {};
  final Map<String, Map<String, dynamic>> ents = {};
  @override
  Future<void> open() async {}
  @override
  Future<Map<String, String>> loadKv() async => {...kv};
  @override
  Future<void> putKv(String k, String? v) async => v == null ? kv.remove(k) : kv[k] = v;
  @override
  Future<List<Ent>> loadEnts() async => [for (final e in ents.entries) Ent.fromJson(e.key.split(':').first, e.value)];
  @override
  Future<void> putEnts(Iterable<Ent> list) async {
    for (final e in list) {
      ents['${e.kind}:${e.id}'] = e.copy().toJson();
    }
  }

  @override
  Future<void> deleteEnts(Iterable<Ent> list) async {
    for (final e in list) {
      ents.remove('${e.kind}:${e.id}');
    }
  }

  @override
  Future<void> close() async {}
}
