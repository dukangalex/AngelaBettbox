import 'package:bett_box/common/system_explicit.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'explicit routing rejects global/direct without modifying their mode',
    () {
      for (final options in [
        SystemExplicitOptions(privacy: true),
        SystemExplicitOptions(chinaDirect: true),
        SystemExplicitOptions(chinaPublicDnsDirect: true),
        SystemExplicitOptions(lanDirect: true),
        SystemExplicitOptions(blockCommonWebRtc: true),
      ]) {
        expect(systemExplicitModeCompatible(options, Mode.rule), isTrue);
        for (final mode in [Mode.global, Mode.direct]) {
          expect(systemExplicitModeCompatible(options, mode), isFalse);
          expect(
            () => requireSystemExplicitMode(options, mode),
            throwsStateError,
          );
        }
      }
    },
  );
  test('disabled options preserve the selected mode', () {
    for (final mode in Mode.values) {
      expect(
        systemExplicitModeCompatible(SystemExplicitOptions(), mode),
        isTrue,
      );
      requireSystemExplicitMode(SystemExplicitOptions(), mode);
    }
  });

  test(
    'saving explicit changes reloads the full profile after persistence',
    () async {
      final calls = <String>[];
      await saveAndReloadSystemExplicit(
        save: () async => calls.add('save'),
        reload: () async {
          calls.add('full-profile-setup');
          return true;
        },
      );
      expect(calls, ['save', 'full-profile-setup']);
    },
  );

  test('reload errors are surfaced instead of claiming success', () async {
    await expectLater(
      saveAndReloadSystemExplicit(
        save: () async {},
        reload: () async => throw StateError('reload failed'),
      ),
      throwsStateError,
    );
  });

  test('a skipped profile setup is not reported as applied', () async {
    await expectLater(
      saveAndReloadSystemExplicit(save: () async {}, reload: () async => false),
      throwsStateError,
    );
  });

  test('failed persistence never reloads the explicit rules', () async {
    var reloaded = false;
    await expectLater(
      saveAndReloadSystemExplicit(
        save: () async => throw StateError('save failed'),
        reload: () async {
          reloaded = true;
          return true;
        },
      ),
      throwsStateError,
    );
    expect(reloaded, isFalse);
  });

  test(
    'options persist without changing unrelated choices',
    () {
      final opt = SystemExplicitOptions(
        chinaPublicDnsDirect: true,
        privacy: true,
      );
      final restored = SystemExplicitOptions.fromJson(opt.toJson());
      expect(restored.chinaPublicDnsDirect, isTrue);
      expect(restored.privacy, isTrue);
      expect(restored.buildRuntimeRulesForMode(Mode.global), isEmpty);
      expect(restored.buildRuntimeRulesForMode(Mode.rule), isNotEmpty);
    },
  );
  test('all routing exceptions and filters are opt-in', () {
    final options = SystemExplicitOptions();
    expect(options.anyEnabled, isFalse);
    expect(options.buildRuntimeRules(), isEmpty);
    final legacy = SystemExplicitOptions.fromJson({
      'privacy': true,
      'adapt': true,
    });
    expect(legacy.chinaPublicDnsDirect, isFalse);
    expect(legacy.lanDirect, isFalse);
    expect(legacy.blockCommonWebRtc, isFalse);
  });

  test('China direct is the China domain and IP category only', () {
    final rules = SystemExplicitOptions(chinaDirect: true).buildRuntimeRules();
    expect(rules, [
      'GEOSITE,geolocation-cn,DIRECT',
      'GEOIP,CN,DIRECT,no-resolve',
    ]);
  });

  test('public DNS exception explicitly matches v4/v6 IPs and domains', () {
    final rules = SystemExplicitOptions(
      chinaPublicDnsDirect: true,
    ).buildRuntimeRules();
    expect(rules, contains('IP-CIDR,223.5.5.5/32,DIRECT,no-resolve'));
    expect(rules, contains('IP-CIDR6,2400:3200::1/128,DIRECT,no-resolve'));
    expect(rules, contains('DOMAIN-SUFFIX,doh.pub,DIRECT'));
    expect(rules, contains('DOMAIN-SUFFIX,alidns.com,DIRECT'));
    expect(rules, contains('DOMAIN-SUFFIX,360.cn,DIRECT'));
    expect(rules, contains('DOMAIN-SUFFIX,onedns.net,DIRECT'));
    expect(rules, contains('IP-CIDR,114.114.114.114/32,DIRECT,no-resolve'));
    expect(rules, contains('IP-CIDR,52.80.60.30/32,DIRECT,no-resolve'));
    expect(
      rules,
      contains('IP-CIDR6,2404:c2c0:85d8:901::8/128,DIRECT,no-resolve'),
    );
    // 26 IPv4 + 9 IPv6 host routes + 5 domain suffixes.
    expect(rules, hasLength(40));
    expect(rules, isNot(contains('GEOSITE,geolocation-cn,DIRECT')));
  });

  test('LAN routing covers private address and local-domain classes', () {
    final rules = SystemExplicitOptions(lanDirect: true).buildRuntimeRules();
    expect(rules, contains('GEOIP,private,DIRECT,no-resolve'));
    expect(rules, contains('IP-CIDR,192.168.0.0/16,DIRECT,no-resolve'));
    expect(rules, contains('IP-CIDR6,fc00::/7,DIRECT,no-resolve'));
    expect(rules, contains('DOMAIN-SUFFIX,home.arpa,DIRECT'));
  });

  test('WebRTC blocker covers STUN/TURN domains and UDP port ranges', () {
    final rules = SystemExplicitOptions(
      blockCommonWebRtc: true,
    ).buildRuntimeRules();
    expect(rules, [
      'DOMAIN-KEYWORD,stun,REJECT',
      'DOMAIN-KEYWORD,turn,REJECT',
      'DOMAIN-SUFFIX,stun.l.google.com,REJECT',
      'AND,((NETWORK,UDP),(DST-PORT,3478-3480)),REJECT',
      'AND,((NETWORK,UDP),(DST-PORT,5349-5355)),REJECT',
      'AND,((NETWORK,UDP),(DST-PORT,19302-19305)),REJECT',
    ]);
  });
  test('ad blocker is a single GEOSITE category rule', () {
    final rules = SystemExplicitOptions(blockAds: true).buildRuntimeRules();
    expect(rules, ['GEOSITE,category-ads-all,REJECT']);
    final restored = SystemExplicitOptions.fromJson(
      SystemExplicitOptions(blockAds: true).toJson(),
    );
    expect(restored.blockAds, isTrue);
    expect(SystemExplicitOptions.fromJson({}).blockAds, isFalse);
  });
  test('QUIC China exemption shares the China-direct determination', () {
    // Either switch alone exempts China QUIC: one traffic class, one owner.
    expect(
      quicBlockExemptsChina(
        vpnExcludeChina: true,
        chinaDirect: false,
        isRussian: false,
      ),
      isTrue,
    );
    expect(
      quicBlockExemptsChina(
        vpnExcludeChina: false,
        chinaDirect: true,
        isRussian: false,
      ),
      isTrue,
    );
    expect(
      quicBlockExemptsChina(
        vpnExcludeChina: false,
        chinaDirect: false,
        isRussian: false,
      ),
      isFalse,
    );
    expect(
      quicBlockExemptsChina(
        vpnExcludeChina: true,
        chinaDirect: true,
        isRussian: true,
      ),
      isFalse,
    );
  });
  test('port protections precede direct routing exceptions', () {
    final rules = SystemExplicitOptions(
      chinaDirect: true,
      lanDirect: true,
      chinaPublicDnsDirect: true,
      blockCommonWebRtc: true,
    ).buildRuntimeRules();
    expect(
      rules.indexOf('DOMAIN-KEYWORD,stun,REJECT'),
      lessThan(rules.indexOf('IP-CIDR,223.5.5.5/32,DIRECT,no-resolve')),
    );
    expect(
      rules.indexOf('AND,((NETWORK,UDP),(DST-PORT,3478-3480)),REJECT'),
      lessThan(rules.indexOf('GEOIP,private,DIRECT,no-resolve')),
    );
  });
}
