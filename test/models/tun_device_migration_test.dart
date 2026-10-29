import 'dart:convert';

import 'package:bett_box/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _configJsonWithDevice(String device) {
  final json =
      jsonDecode(jsonEncode(Config(themeProps: defaultThemeProps).toJson()))
          as Map<String, Object?>;
  final patch = json['patchClashConfig'] as Map<String, Object?>;
  (patch['tun'] as Map<String, Object?>)['device'] = device;
  return json;
}

void main() {
  group('stored TUN device migration', () {
    test('legacy product name migrates to AngelaMihomo', () {
      final config = Config.compatibleFromJson(
        _configJsonWithDevice('Bettbox'),
      );
      expect(config.patchClashConfig.tun.device, 'AngelaMihomo');
    });

    test('current and custom device names are kept', () {
      expect(
        Config.compatibleFromJson(
          _configJsonWithDevice('AngelaMihomo'),
        ).patchClashConfig.tun.device,
        'AngelaMihomo',
      );
      expect(
        Config.compatibleFromJson(
          _configJsonWithDevice('MyTun'),
        ).patchClashConfig.tun.device,
        'MyTun',
      );
    });
  });
}
