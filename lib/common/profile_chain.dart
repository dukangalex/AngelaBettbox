import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum ProfileChainIssue { incomplete, sameNode, unavailable }

class ProfileChain {
  bool enabled;
  String entry;
  String landing;

  ProfileChain({this.enabled = false, this.entry = '', this.landing = ''});

  ProfileChain copyWith({bool? enabled, String? entry, String? landing}) =>
      ProfileChain(
        enabled: enabled ?? this.enabled,
        entry: entry ?? this.entry,
        landing: landing ?? this.landing,
      );

  ProfileChainIssue? selectionIssue(Iterable<String> names) {
    if (!enabled) return null;
    if (entry.trim().isEmpty || landing.trim().isEmpty) {
      return ProfileChainIssue.incomplete;
    }
    if (entry == landing) return ProfileChainIssue.sameNode;
    if (!names.contains(entry) || !names.contains(landing)) {
      return ProfileChainIssue.unavailable;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'entry': entry,
    'landing': landing,
  };

  factory ProfileChain.fromJson(Map<String, dynamic> json) {
    return ProfileChain(
      enabled: json['enabled'] == true,
      entry: (json['entry'] ?? '').toString(),
      landing: (json['landing'] ?? '').toString(),
    );
  }
}

/// Per-profile chain. The subscription file itself is not rewritten.
class ProfileChainStore {
  ProfileChainStore._();

  static final instance = ProfileChainStore._();
  static const _key = 'profile_chain_v1';

  final Map<String, ProfileChain> byProfile = {};
  Future<void>? _loading;

  Future<void> ensureLoaded() {
    return _loading ??= _load();
  }

  ProfileChain of(String profileId) {
    return byProfile.putIfAbsent(profileId, ProfileChain.new);
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      decoded.forEach((key, value) {
        if (value is Map) {
          byProfile[key.toString()] = ProfileChain.fromJson(
            value.cast<String, dynamic>(),
          );
        }
      });
    } catch (_) {}
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(
      _key,
      jsonEncode({
        for (final entry in byProfile.entries) entry.key: entry.value.toJson(),
      }),
    );
    if (!saved) throw StateError('Could not save chain settings');
  }

  /// Note: the config mutation that used to live here is now applied
  /// Go-side in core/patch.go (see patchChainPolicy), because the Dart
  /// full-config hook no longer exists in the typed-patch pipeline.
  /// The original Dart spec is kept in common/explicit_policy.dart
  /// for reference.
}
