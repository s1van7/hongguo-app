import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

class AppUpdate {
  const AppUpdate({required this.version, required this.url});
  final String version;
  final String url;
}

/// 发布仓库。改仓库时这里和 `.github/workflows` 一起改。
const releaseRepository = 's1van7/hongguo-app';

const _latestPage = 'https://github.com/$releaseRepository/releases/latest';
const _latestApi = 'https://api.github.com/repos/$releaseRepository/releases/latest';

int baseBuildNumber(String buildNumber) =>
    (int.tryParse(buildNumber) ?? 0) % 1000;

Future<String> currentAppVersion() async {
  final info = await PackageInfo.fromPlatform();
  return '${info.version}+${baseBuildNumber(info.buildNumber)}';
}

/// `v1.0.1-3` / `1.0.1+3` 都归一成 `1.0.1+3`；认不出就返回 null。
String? normalizeVersion(String raw) {
  final tag = raw.trim().replaceFirst(RegExp('^[vV]'), '');
  final match = RegExp(r'^(\d+\.\d+\.\d+)[-+](\d+)$').firstMatch(tag);
  if (match == null) return null;
  return '${match.group(1)}+${match.group(2)}';
}

int _part(String version, int index) {
  final numbers = version.split('+').first.split('.');
  return index < numbers.length ? int.tryParse(numbers[index]) ?? 0 : 0;
}

int _build(String version) => int.tryParse(version.split('+').last) ?? 0;

/// 版本号比较：先比 主.次.修订，再比构建号。大于返回正数。
int compareVersions(String a, String b) {
  for (var i = 0; i < 3; i++) {
    final diff = _part(a, i) - _part(b, i);
    if (diff != 0) return diff;
  }
  return _build(a) - _build(b);
}

class AppUpdateFailure implements Exception {
  const AppUpdateFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 查 GitHub Release 上有没有比 [current] 更新的版本。
///
/// 有更新返回 [AppUpdate]，已是最新返回 null，网络/解析失败抛 [AppUpdateFailure]。
/// 先读 `releases/latest` 的重定向（不占接口配额），失败再退回 API。
Future<AppUpdate?> fetchLatestRelease(
  String current, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final tag = await _tagFromRedirect(timeout) ?? await _tagFromApi(timeout);
  if (tag == null) {
    throw const AppUpdateFailure('无法连接 GitHub，请检查网络或代理');
  }
  final version = normalizeVersion(tag);
  if (version == null) {
    throw const AppUpdateFailure('发布页版本号无法识别');
  }
  if (compareVersions(version, current) <= 0) return null;
  return AppUpdate(
    version: version,
    url: 'https://github.com/$releaseRepository/releases/tag/$tag',
  );
}

Future<String?> _tagFromRedirect(Duration timeout) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.getUrl(Uri.parse(_latestPage)).timeout(timeout);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.userAgentHeader, 'hongguo-app');
    final response = await request.close().timeout(timeout);
    final location = response.headers.value(HttpHeaders.locationHeader);
    await response.drain<void>().catchError((_) {});
    final match = RegExp(r'/releases/tag/([^/?#]+)').firstMatch(location ?? '');
    return match?.group(1);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<String?> _tagFromApi(Duration timeout) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client
        .getUrl(Uri.parse(_latestApi))
        .timeout(timeout);
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set(HttpHeaders.userAgentHeader, 'hongguo-app');
    final response = await request.close().timeout(timeout);
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(timeout);
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    final tag = decoded['tag_name'];
    return tag is String ? tag : null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
