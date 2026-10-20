import 'package:flutter_test/flutter_test.dart';
import 'package:pub_semver/pub_semver.dart';

// The vendored build-tool package is deliberately not a runtime app dependency.
// ignore: avoid_relative_lib_imports
import '../../plugins/flutter_distributor/packages/flutter_app_packager/lib/src/makers/rpm/rpm_version.dart';

void main() {
  test('RPM version separates build metadata and accepts fork prereleases', () {
    expect(
      rpmVersion(Version.parse('1.19.6-chain.2-pre.1+2026102001')),
      '1.19.6~chain.2.pre.1',
    );
    expect(rpmVersion(Version.parse('1.19.6+2026102001')), '1.19.6');
    expect(rpmVersion(Version.parse('1.20.0-rc.1')), '1.20.0~rc.1');
  });
}
