import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focusflow_mobile/core/response_cache.dart';

/// The cache is what makes the app usable with no network, and its one dangerous
/// property is scoping: reading another account's data off disk would be exactly
/// the cross-account leak the in-memory providers already had to be fixed for.
void main() {
  late Directory dir;
  late ResponseCache cache;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('focusflow_cache_test');
    cache = ResponseCache(directory: dir);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('reads back what it wrote', () async {
    cache.setScope('u1');
    await cache.write('/tasks', {
      'tasks': [
        {'id': 't1'}
      ]
    });

    expect(await cache.read('/tasks'), {
      'tasks': [
        {'id': 't1'}
      ]
    });
  });

  test('an unwritten key is a miss, not an error', () async {
    cache.setScope('u1');
    expect(await cache.read('/nothing'), isNull);
  });

  test('one account cannot read another account\'s cache', () async {
    cache.setScope('u1');
    await cache.write('/tasks', {'tasks': []});

    cache.setScope('u2');

    expect(await cache.read('/tasks'), isNull);
  });

  test('does nothing at all while signed out', () async {
    cache.setScope(null);
    await cache.write('/tasks', {'tasks': []});

    expect(await cache.read('/tasks'), isNull);
    // Nothing may reach disk unscoped, or the next account would inherit it.
    expect(dir.listSync().whereType<File>(), isEmpty);
  });

  test('clear removes only the current scope, leaving other accounts alone', () async {
    cache.setScope('u1');
    await cache.write('/tasks', {'a': 1});
    cache.setScope('u2');
    await cache.write('/tasks', {'b': 2});

    cache.setScope('u1');
    await cache.clear();

    expect(await cache.read('/tasks'), isNull);
    cache.setScope('u2');
    expect(await cache.read('/tasks'), {'b': 2});
  });

  test('survives a process restart — the point of writing to disk', () async {
    cache.setScope('u1');
    await cache.write('/tasks', {'tasks': []});

    // A brand-new instance over the same directory, as on a cold start.
    final fresh = ResponseCache(directory: dir);
    fresh.setScope('u1');

    expect(await fresh.read('/tasks'), {'tasks': []});
  });

  test('a corrupt entry behaves as a miss rather than breaking the screen', () async {
    cache.setScope('u1');
    await cache.write('/tasks', {'tasks': []});

    // Truncate the file the way a process killed mid-write would.
    final file = dir.listSync().whereType<File>().first;
    await file.writeAsString('{"tasks": [');

    final fresh = ResponseCache(directory: dir);
    fresh.setScope('u1');
    expect(await fresh.read('/tasks'), isNull);
  });

  test('keeps different query strings apart', () async {
    cache.setScope('u1');
    await cache.write('/sessions?days=7', {'d': 7});
    await cache.write('/sessions?days=30', {'d': 30});

    expect(await cache.read('/sessions?days=7'), {'d': 7});
    expect(await cache.read('/sessions?days=30'), {'d': 30});
  });
}
