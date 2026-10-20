import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:bett_box/common/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

ArchiveFile entry(String name, String text) =>
    ArchiveFile(name, utf8.encode(text).length, utf8.encode(text));

void main() {
  late Directory home;
  late File original;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('backup_safety_');
    original = File(p.join(home.path, 'profiles', 'old.yaml'));
    await original.create(recursive: true);
    await original.writeAsString('original');
  });
  tearDown(() => home.delete(recursive: true));

  test(
    'a later file-directory conflict cannot partially overwrite profiles',
    () async {
      await expectLater(
        restoreBackupFiles([
          entry('profiles/old.yaml', 'replacement'),
          entry('profiles/collision', 'file'),
          entry('profiles/collision/child.yaml', 'child'),
        ], home.path),
        throwsA(anything),
      );
      expect(await original.readAsString(), 'original');
      expect(
        File(p.join(home.path, 'profiles', 'collision')).existsSync(),
        isFalse,
      );
    },
  );

  for (final name in [
    '../escape.yaml',
    'profiles/../../escape.yaml',
    '/absolute.yaml',
    r'C:\escape.yaml',
    'other.txt',
    r'profiles\..\escape.yaml',
  ]) {
    test(
      'rejects unsafe backup path $name before changing any files',
      () async {
        await expectLater(
          restoreBackupFiles([
            entry('profiles/old.yaml', 'replacement'),
            entry(name, 'bad'),
          ], home.path),
          throwsFormatException,
        );
        expect(await original.readAsString(), 'original');
      },
    );
  }

  test(
    'does not follow a pre-existing symlink outside the profiles directory',
    () async {
      final outside = await Directory.systemTemp.createTemp('backup_outside_');
      addTearDown(() => outside.delete(recursive: true));
      final victim = File(p.join(outside.path, 'victim.yaml'));
      await victim.writeAsString('outside');
      await Link(p.join(home.path, 'profiles', 'linked')).create(outside.path);
      await expectLater(
        restoreBackupFiles([
          entry('profiles/linked/victim.yaml', 'bad'),
        ], home.path),
        throwsA(anything),
      );
      expect(await victim.readAsString(), 'outside');
      expect(await original.readAsString(), 'original');
    },
    skip: Platform.isWindows,
  );

  test('UTF-8 archive entries record byte length, not character count', () {
    final archive = Archive();
    ArchiveExt(archive).add('config.json', {'label': '中文配置'});
    final file = archive.files.single;
    expect(file.size, (file.content).length);
  });
  test(
    'merge retains existing files and restores nested JSON provider caches',
    () async {
      await restoreBackupFiles([
        entry('profiles/new.yaml', 'new'),
        entry('profiles/providers/cache.json', '{"proxies":[]}'),
      ], home.path);
      expect(await original.readAsString(), 'original');
      expect(
        await File(
          p.join(home.path, 'profiles/providers/cache.json'),
        ).readAsString(),
        '{"proxies":[]}',
      );
      expect(
        await File(p.join(home.path, 'profiles/new.yaml')).readAsString(),
        'new',
      );
      expect(
        home.listSync().whereType<Directory>().map((d) => p.basename(d.path)),
        ['profiles'],
      );
    },
  );

  test(
    'override stages replacement before removing previous profiles',
    () async {
      await restoreBackupFiles(
        [entry('profiles/new.yaml', 'new')],
        home.path,
        replaceExisting: true,
      );
      expect(await original.exists(), isFalse);
      expect(
        await File(p.join(home.path, 'profiles/new.yaml')).readAsString(),
        'new',
      );
    },
  );

  test('corruption during override preserves all previous profiles', () async {
    final corrupt = entry('profiles/corrupt.yaml', 'bad')..crc32 = 0;
    await expectLater(
      restoreBackupFiles(
        [entry('profiles/old.yaml', 'replacement'), corrupt],
        home.path,
        replaceExisting: true,
      ),
      throwsFormatException,
    );
    expect(await original.readAsString(), 'original');
    expect(
      await File(p.join(home.path, 'profiles/corrupt.yaml')).exists(),
      isFalse,
    );
  });

  test('rejects duplicate normalized profile entries before writes', () async {
    await expectLater(
      restoreBackupFiles([
        entry('profiles/old.yaml', 'replacement'),
        entry('profiles/./old.yaml', 'second'),
      ], home.path),
      throwsFormatException,
    );
    expect(await original.readAsString(), 'original');
  });

  test(
    'readBackupFile validates length and CRC including UTF-8 ZIP roundtrip',
    () {
      expect(
        () => readBackupFile(ArchiveFile('config.json', 100, [1, 2])),
        throwsFormatException,
      );
      final corrupt = entry('config.json', '{}')..crc32 = 0;
      expect(() => readBackupFile(corrupt), throwsFormatException);
      final archive = Archive();
      ArchiveExt(archive).add('config.json', {'label': '中文配置'});
      final decoded = ZipDecoder().decodeBytes(ZipEncoder().encode(archive));
      expect(jsonDecode(utf8.decode(readBackupFile(decoded.files.single))), {
        'label': '中文配置',
      });
    },
  );
}
