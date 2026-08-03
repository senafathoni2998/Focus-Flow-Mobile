import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// On-disk cache of successful GET responses, so the app opens and reads with no
/// network.
///
/// WHY HERE AND NOT A LOCAL DATABASE. The app already holds every task in memory
/// and filters in Dart (see visibleTasksProvider) — it never queries a store. A
/// SQLite layer would add a schema, on-device migrations and (for Drift) codegen
/// that this project deliberately avoids, in exchange for a query capability
/// nothing uses. Caching at the HTTP boundary instead covers EVERY endpoint at
/// once and needed no change to a single repository, provider or screen.
///
/// WHAT IT DOES NOT DO. This is a read cache. Mutations while offline are a
/// separate problem: replaying a queued POST is only safe once the server can
/// recognise a retry, or a flaky connection silently creates the same task
/// twice. That needs idempotency keys server-side and is deliberately not
/// pretended at here.
class ResponseCache {
  ResponseCache({Directory? directory}) : _override = directory;

  final Directory? _override;
  Directory? _dir;

  /// Namespaced per user. Without this, signing in as someone else would read
  /// the previous account's cached lists straight off disk — the same
  /// cross-account leak the in-memory providers already had to be fixed for.
  String? _scope;

  final Map<String, Object?> _memory = {};

  Future<Directory> _resolveDir() async {
    if (_override != null) return _override;
    _dir ??= Directory('${(await getApplicationDocumentsDirectory()).path}/response_cache');
    if (!await _dir!.exists()) await _dir!.create(recursive: true);
    return _dir!;
  }

  /// Point the cache at a user. Passing null (signed out) makes every read and
  /// write a no-op rather than falling back to a shared namespace.
  void setScope(String? userScope) {
    if (_scope == userScope) return;
    _scope = userScope;
    _memory.clear();
  }

  /// Cache keys must not collide across query strings: `/tasks` and
  /// `/sessions?days=7` are different resources.
  String _fileName(String key) {
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    return '${_scope}__$safe.json';
  }

  Future<void> write(String key, Object? body) async {
    if (_scope == null) return;
    _memory[key] = body;
    try {
      final dir = await _resolveDir();
      final tmp = File('${dir.path}/${_fileName(key)}.tmp');
      // Write-then-rename: a process killed mid-write would otherwise leave a
      // truncated file that reads as corrupt data rather than as no data.
      await tmp.writeAsString(jsonEncode(body), flush: true);
      await tmp.rename('${dir.path}/${_fileName(key)}');
    } catch (e) {
      debugPrint('[cache] write failed for $key: $e');
    }
  }

  Future<Object?> read(String key) async {
    if (_scope == null) return null;
    if (_memory.containsKey(key)) return _memory[key];
    try {
      final dir = await _resolveDir();
      final file = File('${dir.path}/${_fileName(key)}');
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      _memory[key] = decoded;
      return decoded;
    } catch (e) {
      // A corrupt entry must behave as a miss, not as an error that breaks the
      // screen it was meant to rescue.
      debugPrint('[cache] read failed for $key: $e');
      return null;
    }
  }

  /// Drop everything for the current scope. Called on sign-out, so the next
  /// account cannot read this one's data off disk.
  Future<void> clear() async {
    _memory.clear();
    final scope = _scope;
    if (scope == null) return;
    try {
      final dir = await _resolveDir();
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        if (entity is File && entity.uri.pathSegments.last.startsWith('${scope}__')) {
          await entity.delete();
        }
      }
    } catch (e) {
      debugPrint('[cache] clear failed: $e');
    }
  }
}
