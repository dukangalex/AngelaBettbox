import 'dart:convert';

import 'package:bett_box/common/profile_chain.dart';

/// Builds the minimal dependency closure needed to use a target from another
/// profile without changing either saved subscription. Names are namespaced so
/// the imported graph cannot collide with the active profile.
class ProfileChainOverlay {
  const ProfileChainOverlay._();

  /// Short source marker embedded in generated names. Profile ids are
  /// timestamp-like and long; the last 6 characters keep generated group
  /// names readable while staying distinct per source profile.
  static String _nameToken(String profileId) => profileId.length > 6
      ? profileId.substring(profileId.length - 6)
      : profileId;

  static Map<String, dynamic> build({
    required String profileId,
    required Map<String, dynamic> source,
    required ChainTargetKind targetKind,
    required String targetName,
    Set<String> reservedNames = const {},
    String? providersPath,
  }) {
    final proxies = _objects(source['proxies'], 'proxy');
    final groups = _objects(source['proxy-groups'], 'group');
    final providers = _mapping(source['proxy-providers']);
    final proxyByName = _index(proxies, 'proxy');
    final groupByName = _index(groups, 'group');

    final duplicateAcrossKinds = proxyByName.keys.toSet().intersection(
      groupByName.keys.toSet(),
    );
    if (duplicateAcrossKinds.isNotEmpty) {
      throw FormatException(
        'Profile has an ambiguous proxy/group name: ${duplicateAcrossKinds.first}.',
      );
    }
    final allNames = <String>{...proxyByName.keys, ...groupByName.keys};
    final providerNames = providers.keys
        .map((value) => value.toString())
        .toSet();
    final targetExists = targetKind == ChainTargetKind.proxy
        ? proxyByName.containsKey(targetName)
        : groupByName.containsKey(targetName);
    if (!targetExists) {
      throw FormatException(
        'The selected ${targetKind.name} is no longer in this profile.',
      );
    }

    final prefix = '[chain ${_nameToken(profileId)}] ';
    final used = <String>{...allNames, ...providerNames, ...reservedNames};
    final renamed = <String, String>{};
    String mapped(String kind, String original) =>
        renamed.putIfAbsent('$kind\u0000$original', () {
          var candidate = '$prefix$original';
          for (var i = 2; used.contains(candidate); i++) {
            candidate = '$prefix$original ($i)';
          }
          used.add(candidate);
          return candidate;
        });
    final importedProxies = <Map<String, dynamic>>[];
    final importedGroups = <Map<String, dynamic>>[];
    final importedProviders = <String, Map<String, dynamic>>{};
    final visitedProxies = <String>{};
    final visitingGroups = <String>{};
    final visitedGroups = <String>{};
    final importedProviderNames = <String>{};

    void addProxy(String name) {
      final proxy = proxyByName[name];
      if (proxy == null) {
        throw FormatException('Group references missing proxy "$name".');
      }
      final proxyType = proxy['type']?.toString().toLowerCase();
      if (proxyType == 'direct' ||
          proxyType == 'pass' ||
          proxyType == 'compatible') {
        throw FormatException('Proxy "$name" can bypass the selected chain.');
      }
      if (!visitedProxies.add(name)) return;
      // App-chain selection explicitly owns this same function for the
      // imported exit graph. Drop the source chain only from this copy; the
      // saved subscription remains unchanged and unrelated fields survive.
      final copy = _cloneMap(proxy)..remove('dialer-proxy');
      copy['name'] = mapped('proxy', name);
      importedProxies.add(copy);
    }

    void addProvider(String name) {
      final provider = providers[name];
      if (provider is! Map) {
        throw FormatException('Group references missing provider "$name".');
      }
      if (!importedProviderNames.add(name)) return;
      final copied = _cloneMap(provider);
      final override = copied['override'];
      final overrideMap = override == null
          ? <String, dynamic>{}
          : _asStringMap(override);
      // Static provider chain setting is the same feature and is replaced by
      // the selected app chain below; keep other provider overrides.
      overrideMap.remove('dialer-proxy');
      final expressions = <dynamic>[];
      final previous = overrideMap['override-expr'];
      void keepUnrelatedExpression(Object? expression) {
        if (expression is! String) {
          throw FormatException(
            'Provider "$name" has an unsupported override expression.',
          );
        }
        if (expression.contains('.dialer-proxy')) {
          if (RegExp(r'^\s*\.dialer-proxy\s*=').hasMatch(expression)) {
            return; // replaced by the explicit selected chain below.
          }
          throw FormatException(
            'Provider "$name" has a complex chain override that cannot be safely replaced.',
          );
        }
        expressions.add(expression);
      }

      if (previous is List) {
        for (final expression in previous) {
          keepUnrelatedExpression(expression);
        }
      } else if (previous is String && previous.isNotEmpty) {
        keepUnrelatedExpression(previous);
      } else if (previous != null) {
        throw FormatException(
          'Provider "$name" has an unsupported override-expr value.',
        );
      }
      final providerPrefix = '[chain ${_nameToken(profileId)}/$name] ';
      expressions.add('.name = ${jsonEncode(providerPrefix)} + .name');
      overrideMap['override-expr'] = expressions;
      copied['override'] = overrideMap;
      final newName = mapped('provider', name);
      importedProviders[newName] = copied;
    }

    const protected = {'DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'COMPATIBLE'};

    void addGroup(String name) {
      final group = groupByName[name];
      if (group == null) {
        throw FormatException('Group "$name" is no longer in this profile.');
      }
      if (visitedGroups.contains(name)) return;
      if (!visitingGroups.add(name)) {
        throw FormatException('The selected group contains a cycle.');
      }
      for (final field in [
        'include-all',
        'include-all-proxies',
        'include-all-providers',
      ]) {
        if (group[field] == true) {
          throw FormatException(
            'Group "$name" includes the whole profile; select a static group or a provider-backed group instead.',
          );
        }
      }
      final copy = _cloneMap(group);
      // A provider can be empty after refresh; the Mihomo default is
      // COMPATIBLE (direct). A chain must fail closed instead.
      copy['empty-fallback'] = 'REJECT';
      final members = group['proxies'];
      if (members is List) {
        final remapped = <dynamic>[];
        for (final member in members) {
          if (member is! String) {
            throw FormatException('Group "$name" has an unsupported member.');
          }
          if (groupByName.containsKey(member)) {
            addGroup(member);
            remapped.add(mapped('group', member));
          } else if (proxyByName.containsKey(member)) {
            addProxy(member);
            remapped.add(mapped('proxy', member));
          } else if (member == 'DIRECT' ||
              member == 'PASS' ||
              member == 'COMPATIBLE') {
            throw FormatException(
              'Group "$name" can bypass the selected chain via "$member".',
            );
          } else if (protected.contains(member)) {
            remapped.add(member);
          } else {
            throw FormatException(
              'Group "$name" references unavailable member "$member".',
            );
          }
        }
        copy['proxies'] = remapped;
      }
      final uses = group['use'];
      if (uses is List && uses.isNotEmpty) {
        // A dynamic provider may contain a direct adapter; reject those types
        // from this imported runtime group, leaving its original config intact.
        final previous = copy['exclude-type']?.toString() ?? '';
        copy['exclude-type'] = [
          if (previous.isNotEmpty) previous,
          'Direct',
          'Compatible',
          'Pass',
        ].join('|');
      }
      if (uses is List) {
        final remappedProviders = <dynamic>[];
        for (final usedProvider in uses) {
          if (usedProvider is! String) {
            throw FormatException(
              'Group "$name" has an unsupported provider reference.',
            );
          }
          addProvider(usedProvider);
          remappedProviders.add(mapped('provider', usedProvider));
        }
        copy['use'] = remappedProviders;
      }
      // Namespacing provider nodes changes regex match semantics (especially
      // anchors and substring matches). Do not silently select different nodes.
      if (uses is List && uses.isNotEmpty) {
        for (final filterField in ['filter', 'exclude-filter']) {
          final filter = group[filterField];
          if (filter is String && filter.isNotEmpty) {
            throw FormatException(
              'Group "$name" uses a provider filter that cannot be safely preserved when importing; choose an unfiltered group.',
            );
          }
        }
      }
      copy['name'] = mapped('group', name);
      importedGroups.add(copy);
      visitingGroups.remove(name);
      visitedGroups.add(name);
    }

    if (targetKind == ChainTargetKind.proxy) {
      addProxy(targetName);
    } else {
      addGroup(targetName);
    }

    return {
      'external-target': mapped(targetKind.name, targetName),
      'external-target-kind': targetKind.name,
      'external-proxies': importedProxies,
      'external-groups': importedGroups,
      'external-providers': importedProviders,
      'external-provider-names': importedProviderNames
          .map((name) => mapped('provider', name))
          .toList(),
      'external-profile-id': profileId,
      'external-providers-path': ?providersPath,
    };
  }

  static List<Map<String, dynamic>> _objects(Object? value, String label) {
    if (value == null) return const [];
    if (value is! List) {
      throw FormatException('Profile $label list is invalid.');
    }
    return value.whereType<Map>().map(_asStringMap).toList();
  }

  static Map<String, dynamic> _mapping(Object? value) {
    if (value == null) return const {};
    if (value is! Map) {
      throw const FormatException('Profile proxy-providers are invalid.');
    }
    return _asStringMap(value);
  }

  static Map<String, dynamic> _index(
    List<Map<String, dynamic>> values,
    String kind,
  ) {
    final result = <String, Map<String, dynamic>>{};
    for (final value in values) {
      final name = value['name']?.toString() ?? '';
      if (name.isEmpty) throw FormatException('A $kind has no name.');
      if (result.containsKey(name)) {
        throw FormatException('The profile has duplicate $kind name "$name".');
      }
      result[name] = value;
    }
    return result;
  }

  static Map<String, dynamic> _cloneMap(Map value) =>
      _asStringMap(jsonDecode(jsonEncode(value)) as Map);

  static Map<String, dynamic> _asStringMap(Map value) => {
    for (final entry in value.entries) entry.key.toString(): entry.value,
  };
}
