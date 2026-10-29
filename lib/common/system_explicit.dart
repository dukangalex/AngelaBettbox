import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:bett_box/enum/enum.dart';

/// Persist the selected options before rebuilding the active runtime config.
/// Updating general core settings alone does not apply routing rules.
Future<void> saveAndReloadSystemExplicit({
  required Future<void> Function() save,
  required Future<bool> Function() reload,
}) async {
  await save();
  if (!await reload()) {
    throw StateError('No active profile was applied');
  }
}

/// These rules are evaluated only in Mihomo's rule mode. Reject an
/// incompatible configuration rather than silently weakening the enabled rules
/// or changing the user's unrelated global/direct routing semantics.
bool systemExplicitModeCompatible(SystemExplicitOptions options, Mode mode) =>
    !options.anyEnabled || mode == Mode.rule;

void requireSystemExplicitMode(SystemExplicitOptions options, Mode mode) {
  if (!systemExplicitModeCompatible(options, mode)) {
    throw StateError(
      'System explicit routing requires rule mode. Switch to rule mode or turn off all system explicit routing options.',
    );
  }
}

/// The QUIC block (VpnProps.disableQuic) and the system-explicit China
/// direct routing share one China determination: QUIC to China destinations
/// is exempt whenever either the VPN-prop China exclusion or the explicit
/// China-direct option is on, because both describe the same traffic class
/// (GEOSITE geolocation-cn / GEOIP CN) and only one rule set may own it.
/// The Russian-locale guard mirrors the existing prepend-rule behaviour,
/// where geolocation-cn does not carry the same meaning.
bool quicBlockExemptsChina({
  required bool vpnExcludeChina,
  required bool chinaDirect,
  required bool isRussian,
}) => !isRussian && (vpnExcludeChina || chinaDirect);

/// Runtime policy applied after the profile, the script, and the built-in
/// network overrides. Off by default so existing profiles keep their behavior.
class SystemExplicitOptions {
  bool privacy;
  bool chinaDirect;
  bool chinaPublicDnsDirect;
  bool lanDirect;
  bool blockCommonWebRtc;
  bool blockAds;

  SystemExplicitOptions({
    this.privacy = false,
    this.chinaDirect = false,
    this.chinaPublicDnsDirect = false,
    this.lanDirect = false,
    this.blockCommonWebRtc = false,
    this.blockAds = false,
  });

  bool get anyEnabled =>
      privacy ||
      chinaDirect ||
      chinaPublicDnsDirect ||
      lanDirect ||
      blockCommonWebRtc ||
      blockAds;

  Map<String, dynamic> toJson() => {
    'privacy': privacy,
    'chinaDirect': chinaDirect,
    'chinaPublicDnsDirect': chinaPublicDnsDirect,
    'lanDirect': lanDirect,
    'blockCommonWebRtc': blockCommonWebRtc,
    'blockAds': blockAds,
  };

  factory SystemExplicitOptions.fromJson(Map<String, dynamic> json) {
    return SystemExplicitOptions(
      privacy: json['privacy'] == true,
      chinaDirect: json['chinaDirect'] == true,
      chinaPublicDnsDirect: json['chinaPublicDnsDirect'] == true,
      lanDirect: json['lanDirect'] == true,
      blockCommonWebRtc: json['blockCommonWebRtc'] == true,
      blockAds: json['blockAds'] == true,
    );
  }

  /// Runtime-only routing/security rules, applied ahead of profile-owned rules.
  /// Public resolver direct routing is deliberately a separate opt-in.
  List<String> buildRuntimeRulesForMode(Mode mode) =>
      mode == Mode.rule ? buildRuntimeRules() : const [];

  List<String> buildRuntimeRules() => [
    if (privacy) ...[
      'AND,((NETWORK,UDP),(DST-PORT,5353)),REJECT',
      'AND,((NETWORK,UDP),(DST-PORT,5355)),REJECT',
      'AND,((NETWORK,UDP),(DST-PORT,1900)),REJECT',
    ],
    if (blockAds) 'GEOSITE,category-ads-all,REJECT',
    // Reject WebRTC/STUN/TURN before routing exceptions; otherwise an
    // earlier DIRECT match silently wins over the enabled protection.
    // Domain rules cover STUN/TURN endpoints on any port; the UDP port
    // ranges cover the well-known allocation/relay ports.
    if (blockCommonWebRtc) ...[
      'DOMAIN-KEYWORD,stun,REJECT',
      'DOMAIN-KEYWORD,turn,REJECT',
      'DOMAIN-SUFFIX,stun.l.google.com,REJECT',
      for (final range in ['3478-3480', '5349-5355', '19302-19305'])
        'AND,((NETWORK,UDP),(DST-PORT,$range)),REJECT',
    ],
    // This opt-in precedes broad China routing so its exceptional intent is
    // visible and independently replaces matching profile DNS routes.
    if (chinaPublicDnsDirect) ...[
      for (final address in SystemExplicitStore._chinaPublicDnsIpv4)
        'IP-CIDR,$address/32,DIRECT,no-resolve',
      for (final address in SystemExplicitStore._chinaPublicDnsIpv6)
        'IP-CIDR6,$address/128,DIRECT,no-resolve',
      for (final domain in SystemExplicitStore._chinaPublicDnsDomains)
        'DOMAIN-SUFFIX,$domain,DIRECT',
    ],
    if (chinaDirect) ...[
      'GEOSITE,geolocation-cn,DIRECT',
      'GEOIP,CN,DIRECT,no-resolve',
    ],
    if (lanDirect) ...[
      'GEOSITE,private,DIRECT',
      'GEOIP,private,DIRECT,no-resolve',
      'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve',
      'IP-CIDR,172.16.0.0/12,DIRECT,no-resolve',
      'IP-CIDR,192.168.0.0/16,DIRECT,no-resolve',
      'IP-CIDR,169.254.0.0/16,DIRECT,no-resolve',
      'IP-CIDR,127.0.0.0/8,DIRECT,no-resolve',
      'IP-CIDR6,::1/128,DIRECT,no-resolve',
      'IP-CIDR6,fc00::/7,DIRECT,no-resolve',
      'IP-CIDR6,fe80::/10,DIRECT,no-resolve',
      'DOMAIN-SUFFIX,local,DIRECT',
      'DOMAIN-SUFFIX,lan,DIRECT',
      'DOMAIN-SUFFIX,home.arpa,DIRECT',
    ],
  ];
}

class SystemExplicitStore {
  SystemExplicitStore._();

  static final instance = SystemExplicitStore._();
  static const _key = 'system_explicit_v1';

  SystemExplicitOptions value = SystemExplicitOptions();
  Future<void>? _loading;

  Future<void> ensureLoaded() {
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        value = SystemExplicitOptions.fromJson(decoded.cast<String, dynamic>());
      }
    } catch (_) {}
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(value.toJson()));
  }

  static const _chinaPublicDnsIpv4 = [
    '223.5.5.5',
    '223.6.6.6',
    '119.29.29.29',
    '1.12.12.12',
    '120.53.53.53',
    '180.76.76.76',
    '114.114.114.114',
    '114.114.115.115',
    '114.114.114.119',
    '114.114.115.119',
    '114.114.114.110',
    '114.114.115.110',
    '180.184.1.1',
    '180.184.2.2',
    '101.226.4.6',
    '218.30.118.6',
    '123.125.81.6',
    '140.207.198.6',
    '1.2.4.8',
    '210.2.4.8',
    '52.80.66.66',
    '117.50.22.22',
    '117.50.10.10',
    '52.80.52.52',
    '117.50.60.30',
    '52.80.60.30',
  ];

  static const _chinaPublicDnsIpv6 = [
    '2400:3200::1',
    '2400:3200:baba::1',
    '2402:4e00::',
    '2402:4e00:1::',
    '2400:da00::6666',
    '2400:7fc0:849e:200::4',
    '2404:c2c0:85d8:901::4',
    '2400:7fc0:849e:200::8',
    '2404:c2c0:85d8:901::8',
  ];

  static const _chinaPublicDnsDomains = [
    'alidns.com',
    'doh.pub',
    'dot.pub',
    '360.cn',
    'onedns.net',
  ];

  /// Note: the config mutations that used to live here are now applied
  /// Go-side in core/patch.go (see the system-explicit-rules path), because
  /// the Dart full-config hook no longer exists in the typed-patch pipeline.
  /// The original Dart spec is kept in common/explicit_policy.dart for
  /// reference.

  String notificationLabel(String profileLabel) {
    if (value.privacy) return 'Angela Mihomo';
    return profileLabel;
  }
}
