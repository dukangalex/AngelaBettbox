import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/linux_system_dns.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temporary;
  late File record;
  late List<List<String>> calls;
  late List<String> warnings;
  late String resolvConf;
  late String route;
  late Future<ProcessResult> Function(String, List<String>) runner;
  late LinuxSystemDns dns;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('bettbox-dns-test-');
    record = File('${temporary.path}/dns.json');
    calls = [];
    warnings = [];
    resolvConf = 'nameserver 192.0.2.53\n';
    route = 'default via 192.0.2.1 dev fixture-eth proto dhcp metric 100\n';
    runner = (command, args) async =>
        ProcessResult(0, 0, command == 'ip' ? route : '', '');
    dns = LinuxSystemDns(
      backupFile: () async => record,
      run: (command, args) async {
        calls.add([command, ...args]);
        return runner(command, args);
      },
      readResolvConf: () async => resolvConf,
      warn: warnings.add,
    );
  });
  tearDown(() async => temporary.delete(recursive: true));

  Future<void> obligation([String device = 'old-eth']) =>
      record.writeAsString(jsonEncode({'device': device}), flush: true);

  test(
    'setup persists device before command and successful restore clears it',
    () async {
      runner = (command, args) async {
        if (command == 'nmcli' && args[1] == 'modify') {
          expect(jsonDecode(await record.readAsString()), {
            'device': 'fixture-eth',
          });
        }
        return ProcessResult(0, 0, command == 'ip' ? route : '', '');
      };
      expect(await dns.updateDns(false), isTrue);
      expect(await record.exists(), isTrue);
      expect(calls.last, [
        'nmcli',
        'device',
        'modify',
        'fixture-eth',
        'ipv4.dns',
        '223.5.5.5',
      ]);
      expect(await dns.updateDns(true), isTrue);
      expect(await record.exists(), isFalse);
      expect(calls.last, ['nmcli', 'device', 'reapply', 'fixture-eth']);
    },
  );

  test('restore without obligation does not invoke commands', () async {
    expect(await dns.updateDns(true), isTrue);
    expect(calls, isEmpty);
  });

  for (final failure in ['nonzero', 'missing-command', 'exception']) {
    test(
      'restore $failure retains bytes and blocks new network override',
      () async {
        await obligation();
        final original = await record.readAsBytes();
        runner = (command, args) async {
          if (failure == 'missing-command') {
            throw ProcessException(command, args);
          }
          if (failure == 'exception') throw StateError('fixture failure');
          return ProcessResult(0, 10, '', 'fixture reapply failure');
        };
        expect(await dns.updateDns(false), isFalse);
        expect(await record.readAsBytes(), original);
        expect(calls, [
          ['nmcli', 'device', 'reapply', 'old-eth'],
        ]);
        expect(warnings, isNotEmpty);
        runner = (command, args) async => ProcessResult(0, 0, '', '');
        expect(await dns.updateDns(true), isTrue);
        expect(await record.exists(), isFalse);
      },
    );
  }

  for (final failure in ['nonzero', 'missing-command']) {
    test('setup $failure retains obligation for explicit recovery', () async {
      runner = (command, args) async {
        if (command == 'ip') return ProcessResult(0, 0, route, '');
        if (failure == 'missing-command') throw ProcessException(command, args);
        return ProcessResult(0, 10, '', 'fixture modify failure');
      };
      expect(await dns.updateDns(false), isFalse);
      expect(jsonDecode(await record.readAsString()), {
        'device': 'fixture-eth',
      });
      runner = (command, args) async => ProcessResult(0, 0, '', '');
      expect(await dns.updateDns(true), isTrue);
      expect(await record.exists(), isFalse);
    });
  }

  test(
    'network switch restores old device before recording new device',
    () async {
      await obligation();
      expect(await dns.updateDns(false), isTrue);
      expect(calls.first, ['nmcli', 'device', 'reapply', 'old-eth']);
      expect(calls[1].first, 'ip');
      expect(jsonDecode(await record.readAsString()), {
        'device': 'fixture-eth',
      });
    },
  );

  test('resolved stub skips override after cleaning old obligation', () async {
    await obligation();
    resolvConf = '# comment\n nameserver 127.0.0.53\n';
    expect(await dns.updateDns(false), isTrue);
    expect(calls, [
      ['nmcli', 'device', 'reapply', 'old-eth'],
    ]);
    expect(await record.exists(), isFalse);
  });

  test('non-stub similar address is not treated as resolved stub', () async {
    resolvConf = 'nameserver 127.0.0.530\n';
    expect(await dns.updateDns(false), isTrue);
    expect(calls.last[2], 'modify');
  });

  for (final content in ['not json', '{}', '{"device":""}', '[]']) {
    test('invalid obligation $content retained without commands', () async {
      await record.writeAsString(content);
      expect(await dns.updateDns(false), isFalse);
      expect(await record.readAsString(), content);
      expect(calls, isEmpty);
    });
  }

  for (final missingRoute in [false, true]) {
    test(
      'unavailable default route ($missingRoute) does not modify DNS',
      () async {
        runner = (command, args) async =>
            ProcessResult(0, missingRoute ? 0 : 1, '', 'fixture');
        expect(await dns.updateDns(false), isFalse);
        expect(calls.length, 1);
        expect(calls.single.first, 'ip');
        expect(await record.exists(), isFalse);
      },
    );
  }

  test('unreadable resolver file fails closed without commands', () async {
    final manager = LinuxSystemDns(
      backupFile: () async => record,
      run: (command, args) async => throw StateError('must not invoke process'),
      readResolvConf: () async => throw const FileSystemException('fixture'),
    );
    expect(await manager.updateDns(false), isFalse);
    expect(await record.exists(), isFalse);
  });

  test('cannot persist obligation: no DNS mutation', () async {
    final parentFile = File('${temporary.path}/not-directory');
    await parentFile.writeAsString('fixture');
    final manager = LinuxSystemDns(
      backupFile: () async => File('${parentFile.path}/dns.json'),
      run: (command, args) async {
        calls.add([command, ...args]);
        return ProcessResult(0, 0, route, '');
      },
      readResolvConf: () async => resolvConf,
    );
    expect(await manager.updateDns(false), isFalse);
    expect(calls.every((c) => c.first != 'nmcli'), isTrue);
  });

  test(
    'concurrent set/restore serialize and leave no lost obligation',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      runner = (command, args) async {
        if (command == 'nmcli' && args[1] == 'modify') {
          entered.complete();
          await release.future;
        }
        return ProcessResult(0, 0, command == 'ip' ? route : '', '');
      };
      final setup = dns.updateDns(false);
      await entered.future;
      final restore = dns.updateDns(true);
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((c) => c.contains('reapply')), isEmpty);
      release.complete();
      expect(await setup, isTrue);
      expect(await restore, isTrue);
      expect(await record.exists(), isFalse);
      expect(calls.last, ['nmcli', 'device', 'reapply', 'fixture-eth']);
    },
  );

  test('restart with durable record recovers exact recorded device', () async {
    await obligation('device-with spaces;not-shell');
    expect(await dns.updateDns(true), isTrue);
    expect(calls.single, [
      'nmcli',
      'device',
      'reapply',
      'device-with spaces;not-shell',
    ]);
    expect(await record.exists(), isFalse);
  });
}
