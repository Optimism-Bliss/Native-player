import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../util/log.dart';

/// Public repository whose GitHub Releases carry the app builds.
const updateRepo = 'Optimism-Bliss/Native-player';

class AppRelease {
  const AppRelease({required this.version, required this.tag, required this.notes, required this.page, this.asset});
  final List<int> version;
  final String tag;
  final String notes;
  final Uri page;

  /// Download for this platform/CPU, if the release has one.
  final ReleaseAsset? asset;

  String get name => tag.startsWith('v') ? tag.substring(1) : tag;
}

class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.url, required this.size});
  final String name;
  final Uri url;
  final int size;
}

/// `0.4.2`, `v0.4.2`, `0.4.2+6` → [0, 4, 2]. Pre-release suffixes are ignored.
List<int> parseVersion(String raw) {
  var s = raw.trim();
  if (s.startsWith('v')) s = s.substring(1);
  s = s.split('+').first.split('-').first;
  return [for (final p in s.split('.')) int.tryParse(p) ?? 0];
}

int compareVersions(List<int> a, List<int> b) {
  for (var i = 0; i < 3; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// Asset name suffix for this device (matches the names CI publishes).
String? assetSuffix() {
  if (Platform.isAndroid) {
    return switch (Abi.current()) {
      Abi.androidArm64 => 'android-arm64-v8a.apk',
      Abi.androidArm => 'android-armeabi-v7a.apk',
      Abi.androidX64 => 'android-x86_64.apk',
      _ => null,
    };
  }
  if (Platform.isWindows) return 'windows-x64-setup.exe';
  if (Platform.isLinux) {
    return switch (Abi.current()) {
      Abi.linuxArm64 => 'linux-arm64.tar.gz',
      Abi.linuxX64 => 'linux-x64.tar.gz',
      _ => null,
    };
  }
  return null;
}

class Updater {
  static const _skipKey = 'update_skip_version';
  static const _lastCheckKey = 'update_last_check';

  static Future<String> currentVersion() async => (await PackageInfo.fromPlatform()).version;

  /// Newest published (non-draft) release; pre-releases count, since every
  /// build here is published as one.
  static Future<AppRelease?> latest() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse('https://api.github.com/repos/$updateRepo/releases?per_page=10'));
      req.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'TorBoxSTRM-app');
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        appLog('update check: HTTP ${res.statusCode}');
        return null;
      }
      final body = jsonDecode(await res.transform(utf8.decoder).join()) as List;
      final suffix = assetSuffix();
      AppRelease? best;
      for (final r in body.whereType<Map>()) {
        if (r['draft'] == true) continue;
        final tag = r['tag_name'];
        if (tag is! String) continue;
        ReleaseAsset? asset;
        for (final a in (r['assets'] as List? ?? const []).whereType<Map>()) {
          final name = a['name'];
          final url = a['browser_download_url'];
          if (suffix != null && name is String && name.endsWith(suffix) && url is String) {
            asset = ReleaseAsset(name: name, url: Uri.parse(url), size: (a['size'] as num?)?.toInt() ?? 0);
          }
        }
        final release = AppRelease(
          version: parseVersion(tag),
          tag: tag,
          notes: (r['body'] as String? ?? '').trim(),
          page: Uri.parse(r['html_url'] as String? ?? 'https://github.com/$updateRepo/releases'),
          asset: asset,
        );
        if (best == null || compareVersions(release.version, best.version) > 0) best = release;
      }
      return best;
    } catch (e) {
      appLog('update check failed: $e');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Release newer than this build, or null. With [automatic], respects
  /// "skip this version" and checks at most every 6 hours.
  static Future<AppRelease?> available({bool automatic = false}) async {
    final prefs = await SharedPreferences.getInstance();
    if (automatic) {
      final last = prefs.getInt(_lastCheckKey) ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - last < const Duration(hours: 6).inMilliseconds) return null;
    }
    final release = await latest();
    await prefs.setInt(_lastCheckKey, DateTime.now().millisecondsSinceEpoch);
    if (release == null) return null;
    final current = parseVersion(await currentVersion());
    if (compareVersions(release.version, current) <= 0) return null;
    if (automatic && prefs.getString(_skipKey) == release.tag) return null;
    return release;
  }

  static Future<void> skip(AppRelease release) async =>
      (await SharedPreferences.getInstance()).setString(_skipKey, release.tag);

  /// Downloads the asset, reporting progress in 0..1.
  static Future<File> download(ReleaseAsset asset, void Function(double) onProgress) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}${asset.name}');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(asset.url);
      req.headers.set(HttpHeaders.userAgentHeader, 'TorBoxSTRM-app');
      final res = await req.close();
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: asset.url);
      final total = res.contentLength > 0 ? res.contentLength : asset.size;
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in res) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress(received / total);
      }
      await sink.close();
      if (asset.size > 0 && await file.length() != asset.size) {
        throw const FileSystemException('Tải về không đủ dung lượng');
      }
      return file;
    } finally {
      client.close(force: true);
    }
  }

  static const _channel = MethodChannel('torboxstrm/intent');

  /// Hands the downloaded build to the platform installer.
  /// Returns false when the user has to finish by hand (release page opened).
  static Future<bool> install(AppRelease release, File file) async {
    if (Platform.isAndroid) {
      return await _channel.invokeMethod<bool>('installApk', {'path': file.path}) ?? false;
    }
    if (Platform.isWindows) {
      // Silent per-user install; the installer closes this app and starts the new one.
      await Process.start(file.path, ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART'], mode: ProcessStartMode.detached);
      exit(0);
    }
    if (Platform.isLinux) {
      final bundle = File(Platform.resolvedExecutable).parent;
      try {
        final probe = File('${bundle.path}/.update-probe')..writeAsStringSync('');
        probe.deleteSync();
      } catch (_) {
        await launchUrl(release.page, mode: LaunchMode.externalApplication);
        return false;
      }
      // The archive holds one top-level folder (TorBox-STRM-linux-<arch>/...).
      final r = await Process.run('tar', ['-xzf', file.path, '-C', bundle.path, '--strip-components=1']);
      if (r.exitCode != 0) throw ProcessException('tar', const [], '${r.stderr}', r.exitCode);
      return true;
    }
    await launchUrl(release.page, mode: LaunchMode.externalApplication);
    return false;
  }
}
