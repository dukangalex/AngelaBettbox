import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum ProfileChainIssue {
  incomplete,
  sameNode,
  otherProfileRequired,
  unavailable,
}

enum ChainTargetKind { proxy, group }

String chainTargetKey(ChainTargetKind kind, String name) =>
    '${kind.name}\u0000$name';

class ProfileChain {
  bool enabled;
  String entry;
  ChainTargetKind entryKind;
  String landing;
  ChainTargetKind landingKind;

  /// Empty means the profile owning this chain (also the legacy v1 default).
  String landingProfileId;

  ProfileChain({
    this.enabled = false,
    this.entry = '',
    this.entryKind = ChainTargetKind.proxy,
    this.landing = '',
    this.landingKind = ChainTargetKind.proxy,
    this.landingProfileId = '',
  });

  String resolvedLandingProfileId(String currentProfileId) =>
      landingProfileId.isEmpty ? currentProfileId : landingProfileId;

  ProfileChain copyWith({
    bool? enabled,
    String? entry,
    ChainTargetKind? entryKind,
    String? landing,
    ChainTargetKind? landingKind,
    String? landingProfileId,
  }) => ProfileChain(
    enabled: enabled ?? this.enabled,
    entry: entry ?? this.entry,
    entryKind: entryKind ?? this.entryKind,
    landing: landing ?? this.landing,
    landingKind: landingKind ?? this.landingKind,
    landingProfileId: landingProfileId ?? this.landingProfileId,
  );

  ProfileChainIssue? selectionIssue({
    required String currentProfileId,
    required Set<String> entryTargets,
    required Set<String> landingTargets,
  }) {
    if (!enabled) return null;
    if (entry.trim().isEmpty || landing.trim().isEmpty) {
      return ProfileChainIssue.incomplete;
    }
    final landingSource = resolvedLandingProfileId(currentProfileId);
    if (landingSource == currentProfileId) {
      return ProfileChainIssue.otherProfileRequired;
    }
    if (!entryTargets.contains(chainTargetKey(entryKind, entry)) ||
        !landingTargets.contains(chainTargetKey(landingKind, landing))) {
      return ProfileChainIssue.unavailable;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'entry': entry,
    'entry-kind': entryKind.name,
    'landing': landing,
    'landing-kind': landingKind.name,
    if (landingProfileId.isNotEmpty) 'landing-profile-id': landingProfileId,
  };

  factory ProfileChain.fromJson(Map<String, dynamic> json) {
    ChainTargetKind parseKind(Object? value) {
      for (final kind in ChainTargetKind.values) {
        if (kind.name == value) return kind;
      }
      return ChainTargetKind.proxy;
    }

    return ProfileChain(
      enabled: json['enabled'] == true,
      entry: (json['entry'] ?? '').toString(),
      entryKind: parseKind(json['entry-kind']),
      landing: (json['landing'] ?? '').toString(),
      landingKind: parseKind(json['landing-kind']),
      landingProfileId: (json['landing-profile-id'] ?? '').toString(),
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
