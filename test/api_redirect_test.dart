import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focusflow_mobile/core/api_client.dart';
import 'package:focusflow_mobile/core/api_exception.dart';
import 'package:focusflow_mobile/core/token_storage.dart';

/// What happens when something other than the backend answers.
///
/// These run against REAL sockets rather than a mocked adapter, because the
/// behaviour under test belongs to dart:io's HttpClient, not to Dio's Dart code
/// — a mock would only prove what the mock was written to do.

class _FakeStorage implements TokenStorage {
  @override
  Future<String?> getAccessToken() async => 'SECRET-TOKEN';
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not used by this test');
}

void main() {
  late HttpServer elsewhere;
  late HttpServer backend;
  late int elsewhereHits;
  late String? elsewhereSawAuth;

  setUp(() async {
    elsewhereHits = 0;
    elsewhereSawAuth = null;
    elsewhere = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    elsewhere.listen((HttpRequest r) {
      elsewhereHits++;
      elsewhereSawAuth = r.headers.value('authorization');
      r.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write('{"tasks":[]}')
        ..close();
    });
    backend = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    backend.listen((HttpRequest r) {
      r.response
        ..statusCode = 302
        ..headers.set('location', 'http://127.0.0.1:${elsewhere.port}/stolen')
        ..close();
    });
  });

  tearDown(() async {
    await elsewhere.close(force: true);
    await backend.close(force: true);
  });

  ApiClient client() => ApiClient(
        storage: _FakeStorage(),
        apiBase: 'http://127.0.0.1:${backend.port}/api/v1',
      );

  test('a redirect to another host is refused, not followed', () async {
    // The old behaviour: the hop was taken and `{"tasks":[]}` from a machine
    // that is not the backend came back as a successful response, with no error
    // anywhere. An empty task list presented as authoritative is its own harm.
    Object? thrown;
    try {
      await client().getJson('/tasks');
    } catch (e) {
      thrown = e;
    }

    expect(elsewhereHits, 0, reason: 'the other host must never be contacted');
    expect(thrown, isA<ApiException>());
    final ApiException e = thrown! as ApiException;
    expect(e.statusCode, 302);
    // The message has to name the target, or the user has nothing to act on.
    expect(e.message, contains('127.0.0.1:${elsewhere.port}'));
    expect(e.message, contains('Settings'));
  });

  test('the bearer token was never the exposure here', () async {
    // Recorded because it is easy to assume the opposite and then write a
    // confident commit message about a credential leak that does not exist.
    // dart:io drops Authorization across a cross-host redirect. Measured with
    // following left ON, which is the only way to observe it at all.
    final HttpClient raw = HttpClient()..autoUncompress = false;
    final HttpClientRequest req =
        await raw.getUrl(Uri.parse('http://127.0.0.1:${backend.port}/api/v1/tasks'));
    req.headers.set('authorization', 'Bearer SECRET-TOKEN');
    req.followRedirects = true;
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    raw.close();

    expect(elsewhereHits, 1, reason: 'with following ON the hop IS taken');
    expect(elsewhereSawAuth, isNull,
        reason: 'dart:io strips Authorization across hosts');
  });
}
