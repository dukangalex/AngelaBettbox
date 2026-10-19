import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Runtime policy applied after the profile, the script, and the built-in
/// network overrides. Off by default so existing profiles keep their behavior.
class SystemExplicitOptions {
  bool privacy;
  bool chinaDirect;
  bool adapt;

  SystemExplicitOptions({
    this.privacy = false,
    this.chinaDirect = false,
    this.adapt = false,
  });

  bool get anyEnabled => privacy || chinaDirect;

  Map<String, dynamic> toJson() => {
    'privacy': privacy,
    'chinaDirect': chinaDirect,
    'adapt': adapt,
  };

  factory SystemExplicitOptions.fromJson(Map<String, dynamic> json) {
    return SystemExplicitOptions(
      privacy: json['privacy'] == true,
      chinaDirect: json['chinaDirect'] == true,
      adapt: json['adapt'] == true,
    );
  }
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

  /// Note: the config mutations that used to live here are now applied
  /// Go-side in core/patch.go (see patchDropAutomaticDirect and the
  /// prepend-rules path), because the Dart full-config hook no longer
  /// exists in the typed-patch pipeline. The original Dart spec is kept in
  /// common/explicit_policy.dart for reference.

  String notificationLabel(String profileLabel) {
    if (value.privacy) return 'Bettbox';
    return profileLabel;
  }
}
