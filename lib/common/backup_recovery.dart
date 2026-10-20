import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';

// A rollback journal for backup import, not a general storage transaction.
// Snapshots stay untouched until a commit marker exists. Recovery is repeatable
// if the process is killed while rolling back. No directory fsync is available
// here: this protects process termination, not arbitrary power/storage failure.
final _backupRecoveryLock = Lock();
const _journalName = '.backup-recovery';

typedef RestoreConfigMirror = Future<void> Function(String? value);

Future<FileSystemEntityType> _type(String path) =>
    FileSystemEntity.type(path, followLinks: false);

Future<void> _copyTree(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(followLinks: false)) {
    final target = p.join(destination.path, p.basename(entity.path));
    if (entity is Directory) {
      await _copyTree(entity, Directory(target));
    } else if (entity is File) {
      // Flush snapshots before publishing the journal (not a power-loss promise).
      await File(target).writeAsBytes(await entity.readAsBytes(), flush: true);
    } else {
      throw FileSystemException(
        'Backup recovery refuses symbolic links',
        entity.path,
      );
    }
  }
}

Future<void> _removeRegular(String path) async {
  final type = await _type(path);
  if (type == FileSystemEntityType.directory) {
    await Directory(path).delete(recursive: true);
  } else if (type == FileSystemEntityType.file) {
    await File(path).delete();
  } else if (type != FileSystemEntityType.notFound) {
    throw FileSystemException('Backup recovery refuses symbolic links', path);
  }
}

Future<void> _retire(Directory journal) async {
  final retired =
      '${journal.path}.retired-${DateTime.now().microsecondsSinceEpoch}';
  await journal.rename(retired);
  try {
    await Directory(retired).delete(recursive: true);
  } on FileSystemException {
    /* redundant snapshot; not a pending transaction */
  }
}

Future<void> _recover(
  String homePath,
  RestoreConfigMirror restoreMirror,
) async {
  final journal = Directory(p.join(homePath, _journalName));
  final type = await _type(journal.path);
  if (type == FileSystemEntityType.notFound) return;
  if (type != FileSystemEntityType.directory) {
    throw FileSystemException('Invalid backup recovery journal', journal.path);
  }
  if (await _type(p.join(journal.path, 'committed')) ==
      FileSystemEntityType.file) {
    try {
      await _retire(journal);
    } on FileSystemException {
      /* committed data remains usable; retry cleanup later */
    }
    return;
  }
  // Invalid/incomplete journals must stop startup, never silently select a mixed
  // configuration. All paths are fixed; the journal cannot supply target paths.
  final manifest =
      jsonDecode(
            await File(p.join(journal.path, 'manifest.json')).readAsString(),
          )
          as Map<String, dynamic>;
  if (manifest['version'] != 1 ||
      manifest['profiles'] is! bool ||
      manifest['scripts'] is! bool ||
      manifest['config'] is! bool ||
      (manifest['mirror'] != null && manifest['mirror'] is! String)) {
    throw const FormatException('Invalid backup recovery manifest');
  }
  // Scripts are externalized before config save, and removed scripts are
  // deleted during restore. They belong to the same rollback snapshot.
  const treeNames = ['profiles', 'scripts'];
  for (final name in treeNames) {
    if (manifest[name] == true &&
        await _type(p.join(journal.path, name)) !=
            FileSystemEntityType.directory) {
      throw FormatException('Missing backup recovery $name');
    }
  }
  final config = File(p.join(homePath, 'config.json'));
  final savedConfig = File(p.join(journal.path, 'config.json'));
  // Validate the snapshots before removing any live file.
  List<int>? configBytes;
  if (manifest['config'] == true) {
    if (await _type(savedConfig.path) != FileSystemEntityType.file) {
      throw const FormatException('Missing backup recovery config');
    }
    configBytes = await savedConfig.readAsBytes();
  }
  // Stage both trees before touching either live directory.
  for (final name in treeNames) {
    final staged = Directory(p.join(journal.path, 'rollback-$name'));
    await _removeRegular(staged.path);
    if (manifest[name] == true) {
      await _copyTree(Directory(p.join(journal.path, name)), staged);
    }
  }
  for (final name in treeNames) {
    final live = p.join(homePath, name);
    await _removeRegular(live);
    if (manifest[name] == true) {
      await Directory(p.join(journal.path, 'rollback-$name')).rename(live);
    }
  }
  await _removeRegular(config.path);
  if (configBytes != null) await config.writeAsBytes(configBytes, flush: true);
  await restoreMirror(manifest['mirror'] as String?);
  // Rename first: a kill during cleanup cannot turn a partial snapshot into a
  // pending journal. Orphaned snapshots are intentionally not swept at startup.
  await _retire(journal);
}

/// Must run before reading config.json or the shared-preferences fallback.
/// Errors propagate so startup cannot proceed with mixed data.
Future<void> recoverInterruptedBackup(
  String homePath,
  RestoreConfigMirror restoreMirror,
) => _backupRecoveryLock.synchronized(() => _recover(homePath, restoreMirror));

/// Snapshot files plus the preference fallback before a backup import changes
/// either. On failure keep the journal and refuse another import until restart.
/// The callback must report persistence failure by throwing.
Future<void> withBackupRecovery({
  required String homePath,
  required String? configMirror,
  required Future<void> Function() importBackup,
}) => _backupRecoveryLock.synchronized(() async {
  final home = Directory(homePath);
  await home.create(recursive: true);
  final journal = Directory(p.join(homePath, _journalName));
  if (await _type(journal.path) == FileSystemEntityType.directory &&
      await _type(p.join(journal.path, 'committed')) ==
          FileSystemEntityType.file) {
    await _retire(journal);
  }
  if (await _type(journal.path) != FileSystemEntityType.notFound) {
    throw StateError(
      'An interrupted backup restore is pending; restart to recover before importing again',
    );
  }
  final snapshot = await home.createTemp('.backup-snapshot-');
  var published = false;
  try {
    final profiles = Directory(p.join(homePath, 'profiles'));
    final scripts = Directory(p.join(homePath, 'scripts'));
    final config = File(p.join(homePath, 'config.json'));
    final profilesType = await _type(profiles.path);
    final configType = await _type(config.path);
    final scriptsType = await _type(scripts.path);
    if (profilesType != FileSystemEntityType.notFound &&
            profilesType != FileSystemEntityType.directory ||
        configType != FileSystemEntityType.notFound &&
            configType != FileSystemEntityType.file ||
        scriptsType != FileSystemEntityType.notFound &&
            scriptsType != FileSystemEntityType.directory) {
      throw const FileSystemException(
        'Backup recovery requires regular profiles and config',
      );
    }
    if (profilesType == FileSystemEntityType.directory) {
      await _copyTree(profiles, Directory(p.join(snapshot.path, 'profiles')));
    }
    if (scriptsType == FileSystemEntityType.directory) {
      await _copyTree(scripts, Directory(p.join(snapshot.path, 'scripts')));
    }
    if (configType == FileSystemEntityType.file) {
      await File(
        p.join(snapshot.path, 'config.json'),
      ).writeAsBytes(await config.readAsBytes(), flush: true);
    }
    await File(p.join(snapshot.path, 'manifest.json')).writeAsString(
      jsonEncode({
        'version': 1,
        'profiles': profilesType == FileSystemEntityType.directory,
        'scripts': scriptsType == FileSystemEntityType.directory,
        'config': configType == FileSystemEntityType.file,
        'mirror': configMirror,
      }),
      flush: true,
    );
    await snapshot.rename(journal.path);
    published = true;
    await importBackup();
    // Commit only after both profile installation and config save succeed.
    // Publish atomically so recovery never mistakes a partially written marker.
    final marker = File(p.join(journal.path, 'commit.tmp'));
    await marker.writeAsString('1', flush: true);
    await marker.rename(p.join(journal.path, 'committed'));
    // Once committed, cleanup must not turn a successful import into a failure.
    try {
      await _retire(journal);
    } on FileSystemException {
      /* startup retries cleanup */
    }
  } catch (error, stackTrace) {
    if (published) {
      Error.throwWithStackTrace(
        StateError(
          'Backup restore did not finish; restart the app to recover the previous state. Cause: $error',
        ),
        stackTrace,
      );
    }
    rethrow;
  } finally {
    if (!published) await snapshot.delete(recursive: true);
  }
});
