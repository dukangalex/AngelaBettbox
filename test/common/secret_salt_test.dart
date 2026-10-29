import 'dart:convert';

import 'package:bett_box/common/utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('secret obfuscation salt', () {
    test('round-trips with the current salt', () {
      final encrypted = utils.encryptSecret('p@ssw0rd');
      expect(encrypted, startsWith('ENC~'));
      expect(utils.decryptSecret(encrypted), 'p@ssw0rd');
    });

    test('still decrypts values stored by older builds', () {
      final step1 = base64.encode(utf8.encode('legacy-secret'));
      final legacy = 'ENC~${base64.encode(utf8.encode('Bettbox:$step1'))}';
      expect(utils.decryptSecret(legacy), 'legacy-secret');
    });

    test('plain text passes through unchanged', () {
      expect(utils.decryptSecret('plain'), 'plain');
      expect(utils.encryptSecret(''), '');
    });
  });
}
