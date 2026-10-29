import 'dart:convert';

import 'package:bett_box/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _configJsonWithGeo(Map<String, String> geoXUrl) {
  final json =
      jsonDecode(
            jsonEncode(Config(themeProps: defaultThemeProps).toJson()),
          )
          as Map<String, Object?>;
  final patch = json['patchClashConfig'] as Map<String, Object?>;
  patch['geox-url'] = geoXUrl;
  return json;
}

void main() {
  group('stored geo URL migration', () {
    test('legacy mirror URLs migrate to the official source', () {
      final config = Config.compatibleFromJson(
        _configJsonWithGeo({
          'mmdb':
              'https://github.com/appshubcc/bett-rules/releases/download/latest/geoip.metadb',
          'asn':
              'https://github.com/appshubcc/bett-rules/releases/download/latest/GeoLite2-ASN.mmdb',
          'geosite':
              'https://github.com/appshubcc/bett-rules/releases/download/latest/geosite.dat',
        }),
      );
      final geo = config.patchClashConfig.geoXUrl;
      expect(
        geo.mmdb,
        'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb',
      );
      expect(
        geo.asn,
        'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb',
      );
      expect(
        geo.geosite,
        'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat',
      );
    });

    test('custom URLs are left untouched', () {
      final config = Config.compatibleFromJson(
        _configJsonWithGeo({
          'mmdb': 'https://example.com/geoip.metadb',
          'asn':
              'https://github.com/appshubcc/bett-rules/releases/download/latest/GeoLite2-ASN.mmdb',
          'geosite': 'https://example.com/geosite.dat',
        }),
      );
      final geo = config.patchClashConfig.geoXUrl;
      expect(geo.mmdb, 'https://example.com/geoip.metadb');
      expect(
        geo.asn,
        'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb',
      );
      expect(geo.geosite, 'https://example.com/geosite.dat');
    });
  });
}
