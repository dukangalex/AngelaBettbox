import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart';
import 'package:synchronized/synchronized.dart';

extension ArchiveExt on Archive {
  Future<void> addDirectoryToArchive(String dirPath, String parentPath) async {
    final dir = Directory(dirPath);
    final entities = await dir.list(recursive: false).toList();
    for (final entity in entities) {
      final relativePath = relative(
        entity.path,
        from: parentPath,
      ).replaceAll('\\', '/');
      if (entity is File) {
        final data = await entity.readAsBytes();
        final archiveFile = ArchiveFile(relativePath, data.length, data);
        addFile(archiveFile);
      } else if (entity is Directory) {
        await addDirectoryToArchive(entity.path, parentPath);
      }
    }
  }

  void add<T>(String name, T raw) {
    final data = json.encode(raw);
    final bytes = utf8.encode(data);
    addFile(ArchiveFile(name, bytes.length, bytes));
  }
}

/// The archive decoder lazily inflates entries and does not currently verify
/// their CRC even with verify:true. Check bytes before touching live data.
List<int> readBackupFile(ArchiveFile file) {
  if (!file.isFile || file.isSymbolicLink) {
    throw FormatException('Not a regular backup file: ${file.name}');
  }
  final bytes = file.content;
  if (bytes.length != file.size ||
      (file.crc32 != null && getCrc32(bytes) != file.crc32)) {
    throw FormatException('Corrupted backup entry: ${file.name}');
  }
  return bytes;
}

// Serialize restores so two attempts cannot swap the same directory concurrently.
final _restoreLock = Lock();

/// Stage every profile before replacing the live directory. Decode errors,
/// invalid paths and staging failures leave the original files untouched.
/// This is an in-process transaction, not a crash-consistent transaction with
/// config.json. A killed process can leave the previous directory in the
/// .profile-restore-* directory; never treat that as an expendable temp file.
Future<void> restoreBackupFiles(
  Iterable<ArchiveFile> profiles,
  String homeDirPath, {
  bool replaceExisting = false,
}) => _restoreLock.synchronized(() async {
  final entries = <(String, ArchiveFile)>[];
  final seen = <String>{};
  for (final profile in profiles) {
    final name = profile.name.replaceAll('\\', '/');
    final parts = name.split('/');
    if (profile.isSymbolicLink ||
        posix.isAbsolute(name) ||
        windows.isAbsolute(name) ||
        name.contains(':') ||
        name.contains('\u0000') ||
        parts.contains('..') ||
        parts.first != 'profiles') {
      throw FormatException('Invalid profile backup path: ${profile.name}');
    }
    if (!profile.isFile || name.endsWith('/')) continue;
    final relativeName = posix.normalize(parts.skip(1).join('/'));
    if (relativeName == '.' || !seen.add(relativeName.toLowerCase())) {
      throw FormatException('Duplicate or empty profile path: $name');
    }
    entries.add((relativeName, profile));
  }

  final home = Directory(homeDirPath);
  await home.create(recursive: true);
  final target = Directory(join(home.path, 'profiles'));
  final targetType = await FileSystemEntity.type(
    target.path,
    followLinks: false,
  );
  if (targetType != FileSystemEntityType.notFound &&
      targetType != FileSystemEntityType.directory) {
    throw FileSystemException(
      'Profiles path is not a regular directory',
      target.path,
    );
  }
  final transaction = await home.createTemp('.profile-restore-');
  final staged = Directory(join(transaction.path, 'staged'));
  final previous = Directory(join(transaction.path, 'previous'));
  var keepPrevious = false;
  try {
    await staged.create();
    if (!replaceExisting && targetType == FileSystemEntityType.directory) {
      await for (final entity in target.list(
        recursive: true,
        followLinks: false,
      )) {
        final destination = join(
          staged.path,
          relative(entity.path, from: target.path),
        );
        if (entity is Directory) {
          await Directory(destination).create(recursive: true);
        } else if (entity is File) {
          await File(destination).parent.create(recursive: true);
          await entity.copy(destination);
        } else {
          // Do not traverse existing links, even if an archive targets them.
          throw FileSystemException(
            'Cannot restore over a symbolic link',
            entity.path,
          );
        }
      }
    }
    for (final (name, profile) in entries) {
      final file = File(join(staged.path, name));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(readBackupFile(profile), flush: true);
    }

    // Both renames are on the same filesystem. Keep the old directory until
    // installation succeeds, and restore it if the second rename fails.
    if (targetType == FileSystemEntityType.directory) {
      await target.rename(previous.path);
      keepPrevious = true;
    }
    try {
      await staged.rename(target.path);
    } catch (_) {
      if (keepPrevious) {
        await previous.rename(target.path);
        keepPrevious = false;
      }
      rethrow;
    }
    keepPrevious = false;
  } finally {
    // If rollback itself failed, preserve the only copy of the original data.
    if (!keepPrevious) {
      try {
        await transaction.delete(recursive: true);
      } on FileSystemException {
        // A cleanup failure must not turn an installed restore into a failure.
        // The directory contains only staged data or a redundant previous copy.
      }
    }
  }
});

class BackupPasswordException implements Exception {
  final bool wrong;

  const BackupPasswordException({required this.wrong});
}

bool isValidBackupPassword(String password) {
  return password.codeUnits.every((unit) => unit >= 0x20 && unit <= 0x7e);
}

({Archive archive, bool encrypted}) decodeBackupArchive(
  InputStream input,
  String? password,
) {
  final decoder = ZipDecoder();
  final archive = decoder.decodeStream(input, password: password);
  final encrypted = decoder.directory.fileHeaders.any(
    (header) => header.generalPurposeBitFlag & 0x1 != 0,
  );
  if (encrypted && password == null) {
    throw const BackupPasswordException(wrong: false);
  }
  final result = Archive();
  for (final file in archive.files) {
    if (!file.isFile) continue;
    try {
      result.addFile(ArchiveFile.bytes(file.name, file.content));
    } catch (_) {
      if (encrypted) throw const BackupPasswordException(wrong: true);
      rethrow;
    }
  }
  return (archive: result, encrypted: encrypted);
}
