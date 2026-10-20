import 'package:bett_box/common/utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final utils = Utils();
  test('fork versions compare without parsing the suffix as a number', () {
    expect(
      utils.compareVersions('1.19.6-chain.2', '1.19.6-chain.1'),
      greaterThan(0),
    );
    expect(
      utils.compareVersions('1.19.6-chain.10', '1.19.6-chain.2'),
      greaterThan(0),
    );
    expect(
      utils.compareVersions('1.19.6-chain.2-pre.1', '1.19.6-chain.1'),
      greaterThan(0),
    );
  });
  test('stable and standard prerelease precedence is preserved', () {
    expect(utils.compareVersions('1.19.6', '1.19.6-pre.1'), greaterThan(0));
    expect(utils.compareVersions('1.19.6-pre.2', '1.19.6-pre.10'), lessThan(0));
    expect(utils.compareVersions('1.20.0', '1.19.99'), greaterThan(0));
  });
  test('fork stable upgrades its preview and never downgrades to it', () {
    expect(
      utils.compareVersions('1.19.6-chain.2', '1.19.6-chain.2-pre.1'),
      greaterThan(0),
    );
    expect(
      utils.compareVersions('1.19.6-chain.2-pre.1', '1.19.6-chain.2'),
      lessThan(0),
    );
    expect(
      utils.compareVersions('1.19.6-chain.2-pre.10', '1.19.6-chain.2-pre.2'),
      greaterThan(0),
    );
    expect(
      utils.compareVersions('1.19.6-chain.3-pre.1', '1.19.6-chain.2'),
      greaterThan(0),
    );
    expect(
      utils.compareVersions('1.19.6-chain.2+23', '1.19.6-chain.2+22'),
      greaterThan(0),
    );
    expect(
      utils.compareVersions('1.19.7-chain.1', '1.19.6-chain.99'),
      greaterThan(0),
    );
    expect(utils.compareVersions('v1.19.6-chain.2', '1.19.6-chain.2'), 0);
  });
  test('numeric build ordering, leading v and abbreviated versions work', () {
    expect(utils.compareVersions('1.19.6+20', '1.19.6+19'), greaterThan(0));
    expect(utils.compareVersions('v1.19.6-chain.1', '1.19.6-chain.1'), 0);
    expect(utils.compareVersions('1.19', '1.19.0'), 0);
  });
}
