import 'dart:convert';

import 'package:bett_box/common/profile_chain.dart';
import 'package:bett_box/common/profile_chain_overlay.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('imports static strategy group closure with namespaced members', () {
    final source = <String, dynamic>{
      'proxies': [
        {'name': 'Node A', 'type': 'http', 'server': 'a.example', 'port': 80},
        {'name': 'Node B', 'type': 'http', 'server': 'b.example', 'port': 80},
      ],
      'proxy-groups': [
        {
          'name': 'Inner',
          'type': 'select',
          'proxies': ['Node A'],
        },
        {
          'name': 'Outer',
          'type': 'select',
          'proxies': ['Inner', 'Node B'],
        },
      ],
    };
    final before = jsonEncode(source);
    final overlay = ProfileChainOverlay.build(
      profileId: 'profile-1793192612',
      source: source,
      targetKind: ChainTargetKind.group,
      targetName: 'Outer',
      reservedNames: {'[chain 192612] Node A'},
    );
    expect(
      jsonEncode(source),
      before,
      reason: 'source subscription is immutable',
    );
    final groups = (overlay['external-groups'] as List).cast<Map>();
    final proxies = (overlay['external-proxies'] as List).cast<Map>();
    expect(groups, hasLength(2));
    expect(proxies, hasLength(2));
    expect(overlay['external-target-kind'], 'group');
    expect(overlay['external-profile-id'], 'profile-1793192612');
    final names = {
      ...proxies.map((node) => node['name']),
      ...groups.map((group) => group['name']),
    };
    expect(names, hasLength(4));
    expect(names, isNot(contains('[chain 192612] Node A')));
    final outer = groups.singleWhere(
      (g) => g['name'] == overlay['external-target'],
    );
    expect((outer['proxies'] as List).length, 2);
    expect(outer['empty-fallback'], 'REJECT');
  });

  test('floors aggressive health-check parameters on imported copies', () {
    final source = <String, dynamic>{
      'proxies': [
        {'name': 'Node A', 'type': 'http', 'server': 'a.example', 'port': 80},
      ],
      'proxy-groups': [
        {
          'name': 'Fast',
          'type': 'url-test',
          'url': 'http://www.gstatic.com/generate_204',
          'interval': 60,
          'tolerance': 20,
          'timeout': 2000,
          'lazy': true,
          'proxies': ['Node A'],
        },
        {
          'name': 'Calm',
          'type': 'url-test',
          'url': 'http://www.gstatic.com/generate_204',
          'interval': 600,
          'tolerance': 150,
          'proxies': ['Node A'],
        },
      ],
      'proxy-providers': {
        'prov': {
          'type': 'http',
          'url': 'https://example.com/prov',
          'health-check': {
            'enable': true,
            'url': 'http://www.gstatic.com/generate_204',
            'interval': 30,
            'timeout': 1000,
            'lazy': true,
          },
        },
      },
    };
    final fast = ProfileChainOverlay.build(
      profileId: 'p1',
      source: source,
      targetKind: ChainTargetKind.group,
      targetName: 'Fast',
    );
    final fastGroup = (fast['external-groups'] as List).cast<Map>().single;
    expect(fastGroup['interval'], 60);
    expect(fastGroup['tolerance'], 100);
    expect(fastGroup['timeout'], 5000);
    expect(fastGroup['lazy'], isTrue, reason: 'lazy is preserved, not forced');

    final calm = ProfileChainOverlay.build(
      profileId: 'p1',
      source: source,
      targetKind: ChainTargetKind.group,
      targetName: 'Calm',
    );
    final calmGroup = (calm['external-groups'] as List).cast<Map>().single;
    expect(calmGroup['interval'], 600, reason: 'generous values stay');
    expect(calmGroup['tolerance'], 150);
    expect(calmGroup.containsKey('timeout'), isFalse);

    final withProvider = ProfileChainOverlay.build(
      profileId: 'p1',
      source: <String, dynamic>{
        'proxy-groups': [
          {
            'name': 'Pool',
            'type': 'select',
            'use': ['prov'],
          },
        ],
        'proxy-providers': source['proxy-providers'],
      },
      targetKind: ChainTargetKind.group,
      targetName: 'Pool',
    );
    final providers = (withProvider['external-providers'] as Map).values
        .cast<Map>();
    final healthCheck = providers.single['health-check'] as Map;
    expect(healthCheck['interval'], 60);
    expect(healthCheck['timeout'], 5000);
    expect(
      healthCheck['lazy'],
      isTrue,
      reason: 'lazy is preserved, not forced',
    );
  });

  test('imports unfiltered provider-backed group and prefixes provider', () {
    final source = <String, dynamic>{
      'proxy-providers': {
        'remote': {
          'type': 'http',
          'url': 'https://example.invalid/nodes',
          'path': 'old-path',
          'override': {'udp': true},
        },
      },
      'proxy-groups': [
        {
          'name': 'Auto',
          'type': 'url-test',
          'use': ['remote'],
        },
      ],
    };
    final overlay = ProfileChainOverlay.build(
      profileId: 'p2',
      source: source,
      targetKind: ChainTargetKind.group,
      targetName: 'Auto',
      providersPath: '/private/providers/p2',
    );
    final providerNames = (overlay['external-providers'] as Map).keys.toList();
    expect(providerNames, hasLength(1));
    expect(overlay['external-providers-path'], '/private/providers/p2');
    final copied =
        (overlay['external-providers'] as Map)[providerNames.single] as Map;
    expect(copied['path'], 'old-path');
    final expr = (copied['override'] as Map)['override-expr'] as List;
    expect(expr, hasLength(1));
    final group = (overlay['external-groups'] as List).single as Map;
    expect(group['use'], providerNames);
  });

  test('rejects provider filters instead of changing regex matching', () {
    final source = <String, dynamic>{
      'proxy-providers': {
        'remote': {'type': 'http', 'url': 'https://example.invalid'},
      },
      'proxy-groups': [
        {
          'name': 'Auto',
          'type': 'url-test',
          'use': ['remote'],
          'filter': '^region',
        },
      ],
    };
    expect(
      () => ProfileChainOverlay.build(
        profileId: 'p',
        source: source,
        targetKind: ChainTargetKind.group,
        targetName: 'Auto',
      ),
      throwsFormatException,
    );
  });

  test('rejects direct adapter as a chain exit', () {
    final source = <String, dynamic>{
      'proxies': [
        {'name': 'not-a-hop', 'type': 'direct'},
      ],
    };
    expect(
      () => ProfileChainOverlay.build(
        profileId: 'p',
        source: source,
        targetKind: ChainTargetKind.proxy,
        targetName: 'not-a-hop',
      ),
      throwsFormatException,
    );
  });

  test(
    'fails closed on unsupported dynamic groups, cycles and missing members',
    () {
      for (final source in [
        {
          'proxy-groups': [
            {'name': 'All', 'type': 'select', 'include-all': true},
          ],
        },
        {
          'proxy-groups': [
            {
              'name': 'A',
              'type': 'select',
              'proxies': ['B'],
            },
            {
              'name': 'B',
              'type': 'select',
              'proxies': ['A'],
            },
          ],
        },
        {
          'proxy-groups': [
            {
              'name': 'A',
              'type': 'select',
              'proxies': ['gone'],
            },
          ],
        },
      ]) {
        expect(
          () => ProfileChainOverlay.build(
            profileId: 'p',
            source: source,
            targetKind: ChainTargetKind.group,
            targetName:
                (source['proxy-groups'] as List).first['name'] as String,
          ),
          throwsFormatException,
        );
      }
    },
  );

  test('app chain replaces only the copied same-feature setting', () {
    final source = {
      'proxies': [
        {
          'name': 'Exit',
          'type': 'http',
          'server': 'exit.example',
          'port': 80,
          'dialer-proxy': 'Own chain',
          'udp': true,
        },
      ],
    };
    final overlay = ProfileChainOverlay.build(
      profileId: 'source',
      source: source,
      targetKind: ChainTargetKind.proxy,
      targetName: 'Exit',
    );
    final imported = (overlay['external-proxies'] as List).single as Map;
    expect(imported.containsKey('dialer-proxy'), isFalse);
    expect(imported['udp'], isTrue);
    expect(source['proxies'], isNotNull);
    expect((source['proxies'] as List).single['dialer-proxy'], 'Own chain');
  });
}
