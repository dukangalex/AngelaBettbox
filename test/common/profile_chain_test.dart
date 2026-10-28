import 'package:bett_box/common/profile_chain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const entryTargets = {'proxy\u0000Entry', 'group\u0000Entry group'};
  const landingTargets = {'proxy\u0000Exit', 'group\u0000Exit group'};
  const bothTargets = {...entryTargets, ...landingTargets};

  test('disabled choices can be prepared before enabling', () {
    expect(
      ProfileChain().selectionIssue(
        currentProfileId: 'p',
        entryTargets: entryTargets,
        landingTargets: landingTargets,
      ),
      isNull,
    );
    expect(
      ProfileChain(entry: 'old').selectionIssue(
        currentProfileId: 'p',
        entryTargets: entryTargets,
        landingTargets: landingTargets,
      ),
      isNull,
    );
  });

  test('enabled chain accepts proxy and group selections', () {
    final chain = ProfileChain(
      enabled: true,
      entry: 'Entry group',
      entryKind: ChainTargetKind.group,
      landing: 'Exit group',
      landingKind: ChainTargetKind.group,
      landingProfileId: 'other',
    );
    expect(
      chain.selectionIssue(
        currentProfileId: 'p',
        entryTargets: entryTargets,
        landingTargets: landingTargets,
      ),
      isNull,
    );
  });

  test('entry and exit must be complete, available and distinct', () {
    expect(
      ProfileChain(enabled: true).selectionIssue(
        currentProfileId: 'p',
        entryTargets: entryTargets,
        landingTargets: landingTargets,
      ),
      ProfileChainIssue.incomplete,
    );
    expect(
      ProfileChain(
        enabled: true,
        entry: 'Entry',
        landing: 'Entry',
      ).selectionIssue(
        currentProfileId: 'p',
        entryTargets: entryTargets,
        landingTargets: landingTargets,
      ),
      ProfileChainIssue.otherProfileRequired,
    );
    expect(
      ProfileChain(
        enabled: true,
        entry: 'Entry group',
        entryKind: ChainTargetKind.group,
        landing: 'Exit group',
        landingKind: ChainTargetKind.group,
        landingProfileId: 'other',
      ).selectionIssue(
        currentProfileId: 'p',
        entryTargets: entryTargets,
        landingTargets: const {'proxy\u0000Exit'},
      ),
      ProfileChainIssue.unavailable,
    );
    expect(
      ProfileChain(
        enabled: true,
        entry: 'Entry group',
        entryKind: ChainTargetKind.group,
        landing: 'Entry group',
        landingKind: ChainTargetKind.group,
      ).selectionIssue(
        currentProfileId: 'p',
        entryTargets: entryTargets,
        landingTargets: bothTargets,
      ),
      ProfileChainIssue.otherProfileRequired,
    );
    expect(
      ProfileChain(
        enabled: true,
        entry: 'Entry group',
        entryKind: ChainTargetKind.group,
        landing: 'Entry group',
        landingKind: ChainTargetKind.group,
        landingProfileId: 'other',
      ).selectionIssue(
        currentProfileId: 'p',
        entryTargets: entryTargets,
        landingTargets: bothTargets,
      ),
      isNull,
    );
  });

  test('legacy JSON reads as a same-profile proxy selection', () {
    final legacy = ProfileChain.fromJson({
      'enabled': true,
      'entry': 'Entry',
      'landing': 'Exit',
    });
    expect(legacy.entryKind, ChainTargetKind.proxy);
    expect(legacy.landingKind, ChainTargetKind.proxy);
    expect(legacy.resolvedLandingProfileId('p'), 'p');
    expect(ProfileChain.fromJson(legacy.toJson()).toJson(), legacy.toJson());
  });

  test('editing candidate does not mutate last saved choice', () async {
    SharedPreferences.setMockInitialValues({});
    final store = ProfileChainStore.instance;
    await store.ensureLoaded();
    final original = ProfileChain(
      enabled: true,
      entry: 'Entry',
      landing: 'Exit',
      landingProfileId: 'other',
    );
    store.byProfile['p'] = original;
    await store.save();
    final candidate = original.copyWith(landing: 'Entry');
    expect(
      candidate.selectionIssue(
        currentProfileId: 'p',
        entryTargets: entryTargets,
        landingTargets: landingTargets,
      ),
      ProfileChainIssue.unavailable,
    );
    expect(store.of('p').landing, 'Exit');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('profile_chain_v1'), contains('"landing":"Exit"'));
    expect(
      ProfileChain.fromJson(original.toJson()).toJson(),
      original.toJson(),
    );
  });
  test('enabled chain requires exit from another profile', () {
    final chain = ProfileChain(
      enabled: true,
      entry: 'Entry',
      landing: 'Exit',
      landingProfileId: '',
    );
    expect(
      chain.selectionIssue(
        currentProfileId: 'active',
        entryTargets: {chainTargetKey(ChainTargetKind.proxy, 'Entry')},
        landingTargets: {chainTargetKey(ChainTargetKind.proxy, 'Exit')},
      ),
      ProfileChainIssue.otherProfileRequired,
    );
  });
}
