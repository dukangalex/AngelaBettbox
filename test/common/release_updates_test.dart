import 'dart:convert';
import 'dart:typed_data';

import 'package:bett_box/common/constant.dart';
import 'package:bett_box/common/release_updates.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class StubAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions) respond;
  StubAdapter(this.respond);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) => respond(options);
  @override
  void close({bool force = false}) {}
}

void main() {
  const repo = 'dukangalex/AngelaMihomo';
  const tag = 'v1.19.6-chain.2';
  const page = 'https://github.com/$repo/releases/tag/$tag';
  const suffix = 'linux-amd64-compatible.tar.gz';
  late Dio dio;
  late ReleaseUpdates updates;
  setUp(() {
    dio = Dio();
    updates = ReleaseUpdates(repository: repo, client: dio);
  });

  Map<String, dynamic> release({
    String name = 'AngelaBettbox-1.19.6-chain.2-$suffix',
  }) => {
    'tag_name': tag,
    'assets': [
      {
        'name': name,
        'browser_download_url':
            'https://github.com/$repo/releases/download/$tag/$name',
      },
    ],
  };

  test('fork checks its own repository rather than upstream', () {
    expect(repository, repo);
  });
  test(
    'reads stable metadata including real asset names and release notes',
    () async {
      dio.httpClientAdapter = StubAdapter((options) async {
        expect(
          options.uri.toString(),
          'https://api.github.com/repos/$repo/releases/latest',
        );
        return ResponseBody.fromString(
          jsonEncode({
            ...release(),
            'body': '- Fixed update checks',
            'html_url': 'https://unrelated.example',
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });
      final data = (await updates.latest())!;
      expect(data['html_url'], page);
      expect(data['body'], '- Fixed update checks');
      expect(
        updates.downloadUrl(data, assetSuffix: suffix),
        contains('/AngelaBettbox-1.19.6-chain.2-$suffix'),
      );
    },
  );
  for (final invalid in [
    <String, dynamic>{'draft': true, 'tag_name': tag},
    {'prerelease': true, 'tag_name': tag},
    {'tag_name': ''},
    {'tag_name': 123},
  ]) {
    test('rejects invalid or non-stable metadata $invalid', () async {
      dio.httpClientAdapter = StubAdapter(
        (_) async => ResponseBody.fromString(
          jsonEncode(invalid),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
      expect(await updates.latest(), isNull);
    });
  }
  for (final location in [page, '/$repo/releases/tag/$tag']) {
    test('API rate limit falls back to stable redirect: $location', () async {
      var calls = 0;
      dio.httpClientAdapter = StubAdapter((options) async {
        calls++;
        if (calls == 1) return ResponseBody.fromString('rate limited', 403);
        expect(options.followRedirects, isFalse);
        expect(
          options.uri.toString(),
          'https://github.com/$repo/releases/latest',
        );
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': [location],
          },
        );
      });
      final data = (await updates.latest())!;
      expect(calls, 2);
      expect(data['tag_name'], tag);
      expect(updates.downloadUrl(data, assetSuffix: suffix), page);
    });
  }
  for (final location in [
    'https://example.com/$repo/releases/tag/$tag',
    'https://github.com/other/repo/releases/tag/$tag',
    '/$repo/releases',
    '/$repo/releases/tag/',
    'http://github.com/$repo/releases/tag/$tag',
  ]) {
    test(
      'rejects unrelated or malformed fallback location $location',
      () async {
        var calls = 0;
        dio.httpClientAdapter = StubAdapter(
          (_) async => ++calls == 1
              ? ResponseBody.fromString('', 403)
              : ResponseBody.fromString(
                  '',
                  302,
                  headers: {
                    'location': [location],
                  },
                ),
        );
        expect(await updates.latest(), isNull);
      },
    );
  }
  test('accepts existing Bettbox build names without renaming them', () {
    final data = release(name: 'Bettbox-1.19.6-chain.2-$suffix');
    expect(
      updates.downloadUrl(data, assetSuffix: suffix),
      endsWith('/Bettbox-1.19.6-chain.2-$suffix'),
    );
  });
  test(
    'missing platform, missing assets or empty suffix opens exact release page',
    () {
      expect(
        updates.downloadUrl(release(), assetSuffix: 'android-arm64.apk'),
        page,
      );
      expect(updates.downloadUrl({'tag_name': tag}, assetSuffix: suffix), page);
      expect(updates.downloadUrl(release()), page);
    },
  );
  test('never picks debug preview or another architecture as a substitute', () {
    expect(
      updates.downloadUrl(
        release(
          name:
              'AngelaBettbox-1.19.6-chain.2-android-universal-debug-preview.apk',
        ),
        assetSuffix: 'android-universal.apk',
      ),
      page,
    );
    expect(
      updates.downloadUrl(
        release(
          name: 'AngelaBettbox-1.19.6-chain.2-linux-arm64-compatible.tar.gz',
        ),
        assetSuffix: suffix,
      ),
      page,
    );
  });
  test(
    'ambiguous assets use release page rather than selecting arbitrarily',
    () {
      final data = release();
      (data['assets'] as List).add(
        (release(name: 'Bettbox-1.19.6-chain.2-$suffix')['assets'] as List)
            .single,
      );
      expect(updates.downloadUrl(data, assetSuffix: suffix), page);
    },
  );
  for (final bad in [
    'https://example.com/download.apk',
    'https://github.com/$repo/releases/download/old/file.apk',
    'http://github.com/$repo/releases/download/$tag/AngelaBettbox-1.19.6-chain.2-$suffix',
  ]) {
    test('rejects asset URL outside exact release: $bad', () {
      final data = release();
      (data['assets'] as List).single['browser_download_url'] = bad;
      expect(updates.downloadUrl(data, assetSuffix: suffix), page);
    });
  }
}
