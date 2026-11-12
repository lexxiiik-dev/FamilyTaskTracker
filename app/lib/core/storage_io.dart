import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'model.dart';
import 'storage.dart';

Storage createStorage() => SqliteStorage();

/// SQLite в режиме WAL: базу одновременно открывают приложение, фоновая синхронизация и виджет.
class SqliteStorage implements Storage {
  final String? path;
  SqliteStorage([this.path]);
  late Database _db;

  @override
  Future<void> open() async {
    var file = path;
    // TODO_DATA_DIR — отдельный каталог данных (используется тестами)
    final override = Platform.environment['TODO_DATA_DIR'];
    if (file == null && override != null && override.isNotEmpty) {
      await Directory(override).create(recursive: true);
      file = p.join(override, 'todo.sqlite');
    }
    if (file == null) {
      final dir = await getApplicationSupportDirectory();
      await Directory(dir.path).create(recursive: true);
      file = p.join(dir.path, 'todo.sqlite');
    }
    _db = sqlite3.open(file);
    _db.execute('PRAGMA journal_mode=WAL');
    _db.execute('PRAGMA busy_timeout=5000');
    _db.execute('PRAGMA synchronous=NORMAL');
    _db.execute('CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT NOT NULL)');
    _db.execute('CREATE TABLE IF NOT EXISTS ents(kind TEXT NOT NULL, id TEXT NOT NULL, j TEXT NOT NULL, PRIMARY KEY(kind, id))');
  }

  @override
  Future<Map<String, String>> loadKv() async => {for (final r in _db.select('SELECT k, v FROM kv')) r['k'] as String: r['v'] as String};

  @override
  Future<void> putKv(String k, String? v) async {
    if (v == null) {
      _db.execute('DELETE FROM kv WHERE k=?', [k]);
    } else {
      _db.execute('INSERT INTO kv(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v', [k, v]);
    }
  }

  @override
  Future<List<Ent>> loadEnts() async => [
    for (final r in _db.select('SELECT kind, j FROM ents')) Ent.fromJson(r['kind'] as String, jsonDecode(r['j'] as String) as Map<String, dynamic>),
  ];

  @override
  Future<void> putEnts(Iterable<Ent> ents) async {
    if (ents.isEmpty) return;
    final st = _db.prepare('INSERT INTO ents(kind,id,j) VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET j=excluded.j');
    _db.execute('BEGIN IMMEDIATE');
    try {
      for (final e in ents) {
        st.execute([e.kind, e.id, jsonEncode(e.toJson())]);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      st.close();
    }
  }

  @override
  Future<void> deleteEnts(Iterable<Ent> ents) async {
    for (final e in ents) {
      _db.execute('DELETE FROM ents WHERE kind=? AND id=?', [e.kind, e.id]);
    }
  }

  @override
  Future<void> close() async => _db.close();
}
