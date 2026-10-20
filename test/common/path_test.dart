import 'dart:io';

import 'package:bett_box/common/path.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'missing Downloads support falls back to the app data directory',
    () async {
      final home = await Directory.systemTemp.createTemp('bettbox_paths_');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => home.path);
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        await home.delete(recursive: true);
      });

      final paths = AppPath();
      final data = await paths.dataDir.future;
      final downloads = await paths.downloadDir.future.timeout(
        const Duration(seconds: 5),
      );
      expect(downloads.path, data.path);
      expect(downloads.existsSync(), isTrue);
    },
    skip: !Platform.isLinux,
  );
}
