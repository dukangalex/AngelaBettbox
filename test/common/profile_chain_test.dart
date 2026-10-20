import 'package:bett_box/common/profile_chain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const names = ['Entry', 'Exit'];
  test('disabled choices can be prepared before enabling', () {
    expect(ProfileChain().selectionIssue(names), isNull);
    expect(ProfileChain(entry: 'old').selectionIssue(names), isNull);
  });
  test('an enabled chain needs two available, distinct nodes', () {
    expect(
      ProfileChain(enabled: true).selectionIssue(names),
      ProfileChainIssue.incomplete,
    );
    expect(
      ProfileChain(
        enabled: true,
        entry: 'Entry',
        landing: '  ',
      ).selectionIssue(names),
      ProfileChainIssue.incomplete,
    );
    expect(
      ProfileChain(
        enabled: true,
        entry: 'Entry',
        landing: 'Entry',
      ).selectionIssue(names),
      ProfileChainIssue.sameNode,
    );
    expect(
      ProfileChain(
        enabled: true,
        entry: 'Entry',
        landing: 'Removed',
      ).selectionIssue(names),
      ProfileChainIssue.unavailable,
    );
    expect(
      ProfileChain(
        enabled: true,
        entry: 'Entry',
        landing: 'Exit',
      ).selectionIssue(names),
      isNull,
    );
  });
  test('editing a candidate does not mutate the last saved choice', () async {
    SharedPreferences.setMockInitialValues({});
    final store = ProfileChainStore.instance;
    await store.ensureLoaded();
    final original = ProfileChain(
      enabled: true,
      entry: 'Entry',
      landing: 'Exit',
    );
    store.byProfile['p'] = original;
    await store.save();
    final candidate = original.copyWith(landing: 'Entry');
    expect(candidate.selectionIssue(names), ProfileChainIssue.sameNode);
    expect(store.of('p').landing, 'Exit');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('profile_chain_v1'), contains('"landing":"Exit"'));
    expect(
      ProfileChain.fromJson(original.toJson()).toJson(),
      original.toJson(),
    );
  });
}
