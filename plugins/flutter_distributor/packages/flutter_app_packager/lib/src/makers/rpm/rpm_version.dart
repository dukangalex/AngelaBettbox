import 'package:pub_semver/pub_semver.dart';

/// RPM reserves '-' for separating Version and Release and rejects '+'.
/// Keep prerelease precedence with '~'; build metadata belongs in Release.
String rpmVersion(Version version) {
  final base = '${version.major}.${version.minor}.${version.patch}';
  if (version.preRelease.isEmpty) return base;
  return '$base~${version.preRelease.join('.').replaceAll('-', '.')}';
}
