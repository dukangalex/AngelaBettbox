import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/backup_recovery.dart';
import 'package:bett_box/common/constant.dart';
import 'package:bett_box/common/path.dart';
import 'package:bett_box/common/preferences.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory home;
  late SharedPreferences store;
  final oldConfig = Config(
    themeProps: defaultThemeProps,
    profiles: [
      const Profile(id: 'old', autoUpdateDuration: Duration(hours: 1)),
    ],
  );
  final newConfig = Config(
    themeProps: defaultThemeProps,
    profiles: [
      const Profile(id: 'new', autoUpdateDuration: Duration(hours: 1)),
    ],
  );
  final oldJson = jsonEncode(oldConfig);
  final newJson = jsonEncode(newConfig);
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    home = await Directory.systemTemp.createTemp('backup_startup_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => home.path,
        );
    store = await SharedPreferences.getInstance();
    await appPath.dataDir.future;
  });
  tearDownAll(() => home.delete(recursive: true));
  setUp(() async {
    for (final entity in await home.list().toList()) {
      await entity.delete(recursive: true);
    }
    await store.clear();
  });

  for (final hasFile in [true, false]) {
    test(
      'getConfig recovers before ${hasFile ? 'file read' : 'preference fallback'}',
      () async {
        await store.setString(configKey, oldJson);
        if (hasFile) {
          await File(await appPath.appConfigPath).writeAsString(oldJson);
        }
        final oldProfile = File('${home.path}/profiles/old.yaml');
        await oldProfile.create(recursive: true);
        await oldProfile.writeAsString('old');
        await expectLater(
          withBackupRecovery(
            homePath: home.path,
            configMirror: oldJson,
            importBackup: () async {
              await oldProfile.writeAsString('new');
              await store.setString(configKey, newJson);
              await File(await appPath.appConfigPath).writeAsString(newJson);
              throw StateError('process interrupted before commit');
            },
          ),
          throwsStateError,
        );
        final loaded = await preferences.getConfig();
        expect(loaded!.profiles.single.id, 'old');
        expect(await oldProfile.readAsString(), 'old');
        expect(store.getString(configKey), oldJson);
      },
    );
  }
  test(
    'getConfig does not swallow journal failure and fall back to new preferences',
    () async {
      await store.setString(configKey, newJson);
      final manifest = File('${home.path}/.backup-recovery/manifest.json');
      await manifest.create(recursive: true);
      await manifest.writeAsString('{}');
      await expectLater(preferences.getConfig(), throwsFormatException);
      expect(store.getString(configKey), newJson);
    },
  );
}
