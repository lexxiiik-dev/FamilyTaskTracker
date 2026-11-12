import 'package:sembast/sembast.dart';
import 'package:sembast_web/sembast_web.dart';

import 'model.dart';
import 'storage.dart';

Storage createStorage() => IdbStorage();

/// IndexedDB в браузере: данные доступны офлайн (PWA).
class IdbStorage implements Storage {
  late Database _db;
  final _kv = StoreRef<String, String>('kv');
  final _ents = StoreRef<String, Map<String, Object?>>('ents');

  @override
  Future<void> open() async {
    _db = await databaseFactoryWeb.openDatabase('todo');
  }

  @override
  Future<Map<String, String>> loadKv() async => {for (final r in await _kv.find(_db)) r.key: r.value};

  @override
  Future<void> putKv(String k, String? v) async {
    if (v == null) {
      await _kv.record(k).delete(_db);
    } else {
      await _kv.record(k).put(_db, v);
    }
  }

  @override
  Future<List<Ent>> loadEnts() async => [
    for (final r in await _ents.find(_db)) Ent.fromJson(r.key.split(':').first, Map<String, dynamic>.from(_plain(r.value) as Map)),
  ];

  // sembast отдаёт неизменяемые коллекции — копируем в обычные
  static Object? _plain(Object? v) {
    if (v is Map) return {for (final e in v.entries) e.key as String: _plain(e.value)};
    if (v is List) return [for (final e in v) _plain(e)];
    return v;
  }

  @override
  Future<void> putEnts(Iterable<Ent> ents) async {
    if (ents.isEmpty) return;
    await _db.transaction((tx) async {
      for (final e in ents) {
        await _ents.record('${e.kind}:${e.id}').put(tx, Map<String, Object?>.from(e.copy().toJson()));
      }
    });
  }

  @override
  Future<void> deleteEnts(Iterable<Ent> ents) async {
    for (final e in ents) {
      await _ents.record('${e.kind}:${e.id}').delete(_db);
    }
  }

  @override
  Future<void> close() async => _db.close();
}
