import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'package:bett_box/common/archive.dart';
import 'package:bett_box/common/backup_recovery.dart';

Future<void> pause(String label) async {
  stdout.writeln(label);
  await stdout.flush();
  await Completer<void>().future;
}

Future<void> main(List<String> args) async {
  final home = args[0];
  final phase = args[1];
  final mirror = File(p.join(home, 'mirror.txt'));
  if (phase == 'rollback') {
    await recoverInterruptedBackup(home, (value) async {
      await mirror.writeAsString(value ?? '<absent>', flush: true);
      await pause('rollback-mirror');
    });
    return;
  }
  Future<void> operation() async {
    if (phase == 'gap') {
      // Same rename gap as restoreBackupFiles, deterministically injected.
      await Directory(
        p.join(home, 'profiles'),
      ).rename(p.join(home, 'removed-profiles'));
      await pause('gap');
    }
    await File(
      p.join(home, 'scripts', 'old.js'),
    ).writeAsString('new-script', flush: true);
    await File(
      p.join(home, 'scripts', 'new.js'),
    ).writeAsString('new-only', flush: true);
    if (phase == 'scripts') await pause('scripts');
    await restoreBackupFiles(
      [
        ArchiveFile.string('profiles/old.yaml', 'new-profile'),
        ArchiveFile.string('profiles/new.yaml', 'new-only'),
      ],
      home,
      replaceExisting: true,
    );
    if (phase == 'baseline' || phase == 'profiles') await pause('profiles');
    await mirror.writeAsString('new-mirror', flush: true);
    if (phase == 'mirror') await pause('mirror');
    await File(
      p.join(home, 'config.json'),
    ).writeAsString('{partial', flush: true);
    if (phase == 'config') await pause('config');
    await File(
      p.join(home, 'config.json'),
    ).writeAsString('new-config', flush: true);
    if (phase == 'saved') await pause('saved');
  }

  if (phase == 'baseline') {
    await operation();
  } else {
    await withBackupRecovery(
      homePath: home,
      configMirror: await mirror.readAsString(),
      importBackup: operation,
    );
    await pause('committed');
  }
}
