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

/// Runtime policy applied after the profile, the script, and the built-in
/// network overrides. Off by default so existing profiles keep their behavior.
class SystemExplicitOptions {
  bool privacy;
  bool chinaDirect;
  bool chinaPublicDnsDirect;
  bool lanDirect;
  bool blockCommonWebRtc;
  bool blockTunUdp;
  bool adapt;

  SystemExplicitOptions({
    this.privacy = false,
    this.chinaDirect = false,
    this.chinaPublicDnsDirect = false,
    this.lanDirect = false,
    this.blockCommonWebRtc = false,
    this.blockTunUdp = false,
    this.adapt = false,
  });

  bool get anyEnabled =>
      privacy ||
      chinaDirect ||
      chinaPublicDnsDirect ||
      lanDirect ||
      blockCommonWebRtc;

  Map<String, dynamic> toJson() => {
    'privacy': privacy,
    'chinaDirect': chinaDirect,
    'chinaPublicDnsDirect': chinaPublicDnsDirect,
    'lanDirect': lanDirect,
    'blockCommonWebRtc': blockCommonWebRtc,
    'blockTunUdp': blockTunUdp,
    'adapt': adapt,
  };

  factory SystemExplicitOptions.fromJson(Map<String, dynamic> json) {
    return SystemExplicitOptions(
      privacy: json['privacy'] == true,
      chinaDirect: json['chinaDirect'] == true,
      chinaPublicDnsDirect: json['chinaPublicDnsDirect'] == true,
      lanDirect: json['lanDirect'] == true,
      blockCommonWebRtc: json['blockCommonWebRtc'] == true,
      blockTunUdp: json['blockTunUdp'] == true,
      adapt: json['adapt'] == true,
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
    // Reject common leak-prone ports before routing exceptions; otherwise
    // an earlier DIRECT match silently wins over the enabled protection.
    if (blockCommonWebRtc) ...[
      for (final port in [3478, 5349]) ...[
        'AND,((NETWORK,UDP),(DST-PORT,$port)),REJECT',
        'AND,((NETWORK,TCP),(DST-PORT,$port)),REJECT',
      ],
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
    '180.184.1.1',
    '180.184.2.2',
    '101.226.4.6',
  ];

  static const _chinaPublicDnsIpv6 = [
    '2400:3200::1',
    '2400:3200:baba::1',
    '2402:4e00::',
    '2400:da00::6666',
  ];

  static const _chinaPublicDnsDomains = [
    'doh.pub',
    'dot.pub',
    'dns.pub',
    'dns.alidns.com',
  ];

  /// Note: the config mutations that used to live here are now applied
  /// Go-side in core/patch.go (see patchDropAutomaticDirect and the
  /// system-explicit-rules path), because the Dart full-config hook no longer
  /// exists in the typed-patch pipeline. The original Dart spec is kept in
  /// common/explicit_policy.dart for reference.

  String notificationLabel(String profileLabel) {
    if (value.privacy) return 'Bettbox';
    return profileLabel;
  }
}
