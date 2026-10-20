import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/clash/core.dart';
import 'package:bett_box/clash/interface.dart';
import 'package:bett_box/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bett_box/models/models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _ValidationHandler extends ClashHandlerInterface {
  @override
  Future<String> validateConfig(
    String data, {
    String? ageSecretKey,
    SetupParams? setup,
  }) async {
    final content = setup == null
        ? data
        : await File(setup.profilePath).readAsString();
    return content.contains('INVALID') ? 'Invalid configuration fixture' : '';
  }

  @override
  Future<bool> preload() async => true;
  @override
  void reStart() {}
  @override
  bool destroy() => true;
  @override
  Future<Object?> sendMessage(String message) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory home;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    ClashCore.setHandlerForTesting(_ValidationHandler());
    home = await Directory.systemTemp.createTemp('bettbox_profiles_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => home.path,
        );
  });

  tearDownAll(() => home.delete(recursive: true));

  for (final empty in ['', ' \n\t', '\uFEFF \n']) {
    test(
      'empty subscription response preserves the existing file: ${empty.length}',
      () async {
        const profile = Profile(
          id: 'empty-update',
          autoUpdateDuration: Duration(hours: 1),
        );
        final file = File(await appPath.getProfilePath(profile.id));
        const original = 'proxies: []\nrules: []\n';
        await profile.saveFile(utf8.encode(original), validate: false);
        final stamp = DateTime(2020);
        await file.setLastModified(stamp);
        await expectLater(
          profile.saveFile(utf8.encode(empty), validate: false),
          throwsFormatException,
        );
        expect(await file.readAsString(), original);
        expect(await file.lastModified(), stamp);
        // An empty new import must not create a file either.
        const fresh = Profile(
          id: 'empty-new',
          autoUpdateDuration: Duration(hours: 1),
        );
        await expectLater(
          fresh.saveFile(utf8.encode(empty), validate: false),
          throwsFormatException,
        );
        expect(await fresh.check(), isFalse);
      },
    );
  }

  test('malformed UTF-8 preserves the original profile', () async {
    const profile = Profile(
      id: 'bad-utf8',
      autoUpdateDuration: Duration(hours: 1),
    );
    await profile.saveFile(utf8.encode('proxies: []\n'), validate: false);
    final file = File(await appPath.getProfilePath(profile.id));
    await expectLater(
      profile.saveFile(Uint8List.fromList([0xff]), validate: false),
      throwsFormatException,
    );
    expect(await file.readAsString(), 'proxies: []\n');
  });

  for (final service in [true, false]) {
    test(
      'failed validation preserves file and removes temporary files (service=$service)',
      () async {
        globalState.isService = service;
        final profile = Profile(
          id: 'validation-$service',
          autoUpdateDuration: const Duration(hours: 1),
        );
        final file = File(await appPath.getProfilePath(profile.id));
        await profile.saveFile(utf8.encode('proxies: []\n'), validate: false);
        final stamp = DateTime(2020);
        await file.setLastModified(stamp);
        for (final save in [
          () => profile.saveFile(utf8.encode('INVALID')),
          () => profile.saveFileWithString('INVALID'),
          () => profile.saveFileWithString('   '),
        ]) {
          await expectLater(save(), throwsA(anything));
          expect(await file.readAsString(), 'proxies: []\n');
          expect(await file.lastModified(), stamp);
          expect(
            await file.parent
                .list()
                .where((f) => f.path.endsWith('.tmp'))
                .toList(),
            isEmpty,
          );
        }
        // A corrected import succeeds after the failure.
        final saved = await profile.saveFile(
          utf8.encode('proxies: []\nrules: []\n'),
        );
        expect(saved.lastUpdateDate, isNotNull);
        expect(await file.readAsString(), 'proxies: []\nrules: []\n');
      },
    );
  }

  test('an unchanged update leaves the profile file untouched', () async {
    const profile = Profile(id: 'p', autoUpdateDuration: Duration(hours: 1));
    final file = File(await appPath.getProfilePath(profile.id));
    final first = utf8.encode('proxies: []\n');
    final second = utf8.encode('proxies: []\nrules: []\n');

    await profile.saveFile(first, validate: false);
    final stamp = DateTime(2020);
    await file.setLastModified(stamp);

    await profile.saveFile(first, validate: false);
    expect(await file.lastModified(), stamp);

    await profile.saveFile(second, validate: false);
    expect(await file.lastModified(), isNot(stamp));
    expect(await file.readAsString(), 'proxies: []\nrules: []\n');
  });
}
