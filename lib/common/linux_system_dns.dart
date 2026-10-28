import 'dart:convert';
import 'dart:io';

import 'package:synchronized/synchronized.dart';

typedef DnsProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// NetworkManager's device-only IPv4 DNS override. Reapply restores the saved
/// connection profile, not an arbitrary snapshot of other runtime modifications.
/// A durable device record is a cleanup obligation, removed only after reapply
/// succeeds. Failed or ambiguous operations must never overwrite that record.
class LinuxSystemDns {
  LinuxSystemDns({
    required Future<File> Function() backupFile,
    DnsProcessRunner? run,
    Future<String> Function()? readResolvConf,
    void Function(String)? warn,
  }) : _backupFile = backupFile,
       _runProcess = run ?? Process.run,
       _readResolvConf =
           readResolvConf ?? (() => File('/etc/resolv.conf').readAsString()),
       _warn = warn ?? ((_) {});

  final Future<File> Function() _backupFile;
  final DnsProcessRunner _runProcess;
  final Future<String> Function() _readResolvConf;
  final void Function(String) _warn;
  final Lock _lock = Lock();

  /// False means cleanup or setup could not be confirmed; the record is retained
  /// for the next stop, network-change, startup recovery or exit attempt.
  Future<bool> updateDns(bool restore) => _lock.synchronized(() async {
    try {
      if (!await _restoreDns()) return false;
      return restore || await _setDns();
    } catch (e) {
      _warn('Linux system DNS operation failed; cleanup record retained: $e');
      return false;
    }
  });

  Future<ProcessResult?> _run(String command, List<String> args) async {
    try {
      return await _runProcess(command, args);
    } catch (e) {
      _warn('Failed to run $command: $e');
      return null;
    }
  }

  Future<bool> _restoreDns() async {
    final file = await _backupFile();
    if (!await file.exists()) return true;
    final backup = jsonDecode(await file.readAsString());
    final device = backup is Map ? backup['device'] : null;
    if (device is! String || device.trim().isEmpty) {
      _warn('Invalid Linux system DNS cleanup record; left intact');
      return false;
    }
    final result = await _run('nmcli', ['device', 'reapply', device]);
    if (result == null || result.exitCode != 0) {
      _warn('Failed to restore Linux system DNS: ${result?.stderr}');
      return false;
    }
    await file.delete();
    return true;
  }

  Future<bool> _setDns() async {
    // Do not guess when resolv.conf cannot be read. The outer guard fails closed.
    final content = await _readResolvConf();
    if (RegExp(
      r'^\s*nameserver\s+127\.0\.0\.53\b',
      multiLine: true,
    ).hasMatch(content)) {
      return true;
    }
    final route = await _run('ip', ['route', 'show', 'default']);
    if (route == null || route.exitCode != 0) return false;
    final device = RegExp(
      r'\bdev\s+(\S+)',
    ).firstMatch(route.stdout.toString())?.group(1);
    if (device == null) return false;
    final file = await _backupFile();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode({'device': device}), flush: true);
    await temporary.rename(file.path);
    // Persist before modifying. Even a failing command may have applied part of
    // the operation; keep the obligation until explicit successful recovery.
    final result = await _run('nmcli', [
      'device',
      'modify',
      device,
      'ipv4.dns',
      '223.5.5.5',
    ]);
    if (result == null || result.exitCode != 0) {
      _warn('Failed to set Linux system DNS: ${result?.stderr}');
      return false;
    }
    return true;
  }
}
