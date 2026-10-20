import 'package:dio/dio.dart';

/// Reads stable releases only. Never construct an installer URL: fork assets
/// may have different names, and a platform package may not have been built.
class ReleaseUpdates {
  final Dio client;
  final String repository;

  ReleaseUpdates({required this.repository, Dio? client})
    : client =
          client ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              sendTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
            ),
          );

  String get releasesUrl => 'https://github.com/$repository/releases';

  Future<Map<String, dynamic>?> latest() async {
    try {
      final response = await client.get<Object?>(
        'https://api.github.com/repos/$repository/releases/latest',
        options: Options(headers: {'Accept': 'application/vnd.github+json'}),
      );
      final data = response.data;
      if (data is! Map || data['draft'] == true || data['prerelease'] == true) {
        return null;
      }
      final tag = data['tag_name'];
      if (tag is! String || tag.trim().isEmpty) return null;
      return {
        ...Map<String, dynamic>.from(data),
        // Use the repository we asked for, not an untrusted response URL.
        'html_url': '$releasesUrl/tag/${Uri.encodeComponent(tag)}',
      };
    } on DioException {
      // Public API rate limits or API outages must not prevent a manual check.
      // The web /latest endpoint redirects only to the latest stable release.
      final response = await client.get<Object?>(
        '$releasesUrl/latest',
        options: Options(
          followRedirects: false,
          validateStatus: (status) =>
              status != null && status >= 300 && status < 400,
        ),
      );
      final location = response.headers.value('location');
      if (location == null) return null;
      final uri = Uri.parse('$releasesUrl/latest').resolve(location);
      final prefix = Uri.parse('$releasesUrl/tag/');
      if (uri.scheme != prefix.scheme ||
          uri.host != prefix.host ||
          uri.pathSegments.length != 5 ||
          uri.pathSegments.take(4).join('/') !=
              prefix.pathSegments.take(4).join('/')) {
        return null;
      }
      final tag = uri.pathSegments.last;
      if (tag.isEmpty) return null;
      return {
        'tag_name': tag,
        'html_url': '$releasesUrl/tag/${Uri.encodeComponent(tag)}',
        'body': 'New version available. Please visit GitHub to download.',
        'assets': <Object?>[],
      };
    }
  }

  String downloadUrl(Map<String, dynamic> release, {String assetSuffix = ''}) {
    final tag = release['tag_name'];
    if (tag is! String || tag.isEmpty) return releasesUrl;
    final page = '$releasesUrl/tag/${Uri.encodeComponent(tag)}';
    if (assetSuffix.isEmpty) return page;
    final version = tag.replaceFirst(RegExp(r'^v'), '');
    final names = {
      'Bettbox-$version-$assetSuffix',
      'AngelaBettbox-$version-$assetSuffix',
    };
    final assets = release['assets'];
    if (assets is! List) return page;
    final matches = assets
        .whereType<Map>()
        .where((asset) => names.contains(asset['name']))
        .toList();
    if (matches.length != 1) return page;
    final url = matches.single['browser_download_url'];
    if (url is! String) return page;
    final uri = Uri.tryParse(url);
    // Only open an exact asset from this repository and this release tag.
    final expected = Uri.parse(
      'https://github.com/$repository/releases/download/${Uri.encodeComponent(tag)}/${Uri.encodeComponent(matches.single['name'] as String)}',
    );
    if (uri == null || uri != expected) return page;
    return url;
  }
}
