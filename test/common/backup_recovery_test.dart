import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:bett_box/common/backup_recovery.dart';

void main() {
  late Directory home;
  File file(String name) => File(p.join(home.path, name));
  Future<void> mirror(String? value) async {
    await file('mirror.txt').writeAsString(value ?? '<absent>', flush: true);
  }

  Future<void> oldState() async {
    expect(await file('profiles/old.yaml').readAsString(), 'old-profile');
    expect(await file('profiles/new.yaml').exists(), isFalse);
    expect(await file('config.json').readAsString(), 'old-config');
    expect(await file('scripts/old.js').readAsString(), 'old-script');
    expect(await file('scripts/new.js').exists(), isFalse);
    expect(await file('mirror.txt').readAsString(), 'old-mirror');
  }

  Future<Process> worker(String phase, String expected) async {
    final child = await Process.start('dart', [
      '--packages=.dart_tool/package_config.json',
      'test/fixtures/backup_crash_worker.dart',
      home.path,
      phase,
    ]);
    final errors = StringBuffer();
    child.stderr.transform(utf8.decoder).listen(errors.write);
    try {
      final label = await child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 20));
      expect(label, expected);
    } catch (error) {
      child.kill(ProcessSignal.sigkill);
      fail('worker failed: $error $errors');
    }
    return child;
  }

  Future<void> kill(Process child) async {
    expect(child.kill(ProcessSignal.sigkill), isTrue);
    await child.exitCode;
  }

  setUp(() async {
    home = await Directory.systemTemp.createTemp('backup_crash_test_');
    await file('profiles/old.yaml').create(recursive: true);
    await file('profiles/old.yaml').writeAsString('old-profile');
    await file('scripts/old.js').create(recursive: true);
    await file('scripts/old.js').writeAsString('old-script');
    await file('config.json').writeAsString('old-config');
    await file('mirror.txt').writeAsString('old-mirror');
    await file('unrelated.txt').writeAsString('untouched');
  });
  tearDown(() => home.delete(recursive: true));

  test(
    'reproduces old restore kill window: new profiles with old config',
    () async {
      await kill(await worker('baseline', 'profiles'));
      expect(await file('profiles/old.yaml').readAsString(), 'new-profile');
      expect(await file('config.json').readAsString(), 'old-config');
    },
    skip: !Platform.isLinux,
  );

  for (final phase in [
    'gap',
    'scripts',
    'profiles',
    'mirror',
    'config',
    'saved',
  ]) {
    test(
      'SIGKILL at $phase recovers old profiles, config and mirror on restart',
      () async {
        await kill(await worker(phase, phase));
        await recoverInterruptedBackup(home.path, mirror);
        await oldState();
        expect(await file('unrelated.txt').readAsString(), 'untouched');
        await recoverInterruptedBackup(home.path, mirror);
        await oldState();
      },
      skip: !Platform.isLinux,
    );
  }

  test(
    'SIGKILL during rollback is recoverable again without losing snapshot',
    () async {
      await kill(await worker('saved', 'saved'));
      await kill(await worker('rollback', 'rollback-mirror'));
      await recoverInterruptedBackup(home.path, mirror);
      await oldState();
    },
    skip: !Platform.isLinux,
  );

  test('a committed import survives restart without rolling back', () async {
    await kill(await worker('success', 'committed'));
    await recoverInterruptedBackup(home.path, mirror);
    expect(await file('profiles/old.yaml').readAsString(), 'new-profile');
    expect(await file('config.json').readAsString(), 'new-config');
    expect(await file('mirror.txt').readAsString(), 'new-mirror');
  }, skip: !Platform.isLinux);

  test('absent old files and absent mirror are restored as absent', () async {
    await Directory(p.join(home.path, 'profiles')).delete(recursive: true);
    await file('config.json').delete();
    await expectLater(
      withBackupRecovery(
        homePath: home.path,
        configMirror: null,
        importBackup: () async {
          await file('profiles/new.yaml').create(recursive: true);
          await file('config.json').writeAsString('new');
          throw StateError('interrupted');
        },
      ),
      throwsStateError,
    );
    await recoverInterruptedBackup(home.path, mirror);
    expect(await Directory(p.join(home.path, 'profiles')).exists(), isFalse);
    expect(await file('config.json').exists(), isFalse);
    expect(await file('mirror.txt').readAsString(), '<absent>');
  });

  test(
    'failed mirror rollback keeps journal and blocks another import',
    () async {
      await expectLater(
        withBackupRecovery(
          homePath: home.path,
          configMirror: 'old-mirror',
          importBackup: () async {
            await file('config.json').writeAsString('bad');
            throw StateError('save failed');
          },
        ),
        throwsStateError,
      );
      await expectLater(
        recoverInterruptedBackup(home.path, (_) async {
          throw StateError('mirror unavailable');
        }),
        throwsStateError,
      );
      var called = false;
      await expectLater(
        withBackupRecovery(
          homePath: home.path,
          configMirror: 'wrong',
          importBackup: () async {
            called = true;
          },
        ),
        throwsStateError,
      );
      expect(called, isFalse);
      await recoverInterruptedBackup(home.path, mirror);
      await oldState();
    },
  );

  test('snapshot symlinks are rejected without invoking import', () async {
    await Link(
      p.join(home.path, 'profiles', 'link'),
    ).create(file('unrelated.txt').path);
    var called = false;
    await expectLater(
      withBackupRecovery(
        homePath: home.path,
        configMirror: 'old-mirror',
        importBackup: () async {
          called = true;
        },
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(called, isFalse);
    await oldState();
  }, skip: Platform.isWindows);

  test('committed journal cleanup never rolls back saved data', () async {
    await expectLater(
      withBackupRecovery(
        homePath: home.path,
        configMirror: 'old-mirror',
        importBackup: () async {
          await file('config.json').writeAsString('committed-new');
          throw StateError('simulate stop immediately before commit marker');
        },
      ),
      throwsStateError,
    );
    // Same durable state as death after marker rename but before cleanup.
    await file('.backup-recovery/committed').writeAsString('1', flush: true);
    await recoverInterruptedBackup(home.path, (_) async {
      fail('committed data must not restore old preference mirror');
    });
    expect(await file('config.json').readAsString(), 'committed-new');
    expect(
      await Directory(p.join(home.path, '.backup-recovery')).exists(),
      isFalse,
    );
  });

  test(
    'snapshot script links stop recovery before changing live data',
    () async {
      await expectLater(
        withBackupRecovery(
          homePath: home.path,
          configMirror: 'old-mirror',
          importBackup: () async {
            throw StateError('interrupted');
          },
        ),
        throwsStateError,
      );
      await Link(
        p.join(home.path, '.backup-recovery/scripts/link'),
      ).create(file('unrelated.txt').path);
      await expectLater(
        recoverInterruptedBackup(home.path, mirror),
        throwsA(isA<FileSystemException>()),
      );
      await oldState();
    },
    skip: Platform.isWindows,
  );

  test('successive imports need no restart', () async {
    for (var i = 0; i < 2; i++) {
      await withBackupRecovery(
        homePath: home.path,
        configMirror: 'old-mirror',
        importBackup: () async {
          await file('config.json').writeAsString('new-$i');
        },
      );
    }
    expect(await file('config.json').readAsString(), 'new-1');
    expect(
      await Directory(p.join(home.path, '.backup-recovery')).exists(),
      isFalse,
    );
  });

  test(
    'corrupt pending journal stops recovery and preserves live files',
    () async {
      await file('.backup-recovery/manifest.json').create(recursive: true);
      await file('.backup-recovery/manifest.json').writeAsString('{}');
      await expectLater(
        recoverInterruptedBackup(home.path, mirror),
        throwsFormatException,
      );
      await oldState();
    },
  );
}
