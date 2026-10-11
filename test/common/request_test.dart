import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/request.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers every request with the smallest release payload and records where
/// it was asked.
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.requested);

  final List<Uri> requested;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.uri);
    return ResponseBody.fromString(
      '{"tag_name":"v0.0.0"}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the update check asks the repository this build ships from', () async {
    final client = Request();
    final requested = <Uri>[];
    client.dio.httpClientAdapter = _RecordingAdapter(requested);

    await client.checkForUpdate();

    // The fork's tags are the ones this build is cut from; upstream sits
    // behind them, so reading upstream would never offer an update — and
    // would hand a newer upstream build to a user of the fork's fixes.
    expect(
      requested.single.toString(),
      'https://api.github.com/repos/nizabushangtianne3/FlClash/releases/latest',
    );
  });

  test('getTextResponseForUrl propagates the typed DioException', () async {
    // flutter_test's mocked HttpClient answers every request with HTTP 400,
    // which Dio surfaces as a badResponse DioException.
    await expectLater(
      request.getTextResponseForUrl('http://127.0.0.1/anything'),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.badResponse,
        ),
      ),
    );
  });

  test('getFileResponseForUrl propagates the typed DioException', () async {
    await expectLater(
      request.getFileResponseForUrl('http://127.0.0.1/anything'),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.badResponse,
        ),
      ),
    );
  });

  test('both clients wait with a timeout', () {
    final client = Request();

    expect(client.dio.options.connectTimeout, isNotNull);
    expect(client.dio.options.receiveTimeout, isNotNull);
    expect(client.clashDio.options.connectTimeout, isNotNull);
    expect(client.clashDio.options.receiveTimeout, isNotNull);
  });

  test(
    'a subscription that stops answering fails instead of hanging',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      server.listen(sockets.add);
      addTearDown(() async {
        for (final socket in sockets) {
          socket.destroy();
        }
        await server.close();
      });
      final client = Request(receiveTimeout: const Duration(milliseconds: 300));
      final stopwatch = Stopwatch()..start();

      await HttpOverrides.runZoned(() async {
        await expectLater(
          client.getFileResponseForUrl('http://127.0.0.1:${server.port}/sub'),
          throwsA(isA<DioException>()),
        );
      }, createHttpClient: (context) => HttpClient(context: context));
      stopwatch.stop();

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
    },
  );
}
