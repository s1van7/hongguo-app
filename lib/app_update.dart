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
const releaseRepository = 's1van7/yingyu';

const _latestPage = 'https://github.com/$releaseRepository/releases/latest';
const _manifestUrl = 'https://yy.s1van.top:8448/dl/latest.json';
const _latestApi = 'https://api.github.com/repos/$releaseRepository/releases/latest';

/// 当前版本，形如 `1.0.2`。构建号只用于安装覆盖，不再对外展示。
Future<String> currentAppVersion() async {
  final info = await PackageInfo.fromPlatform();
  return normalizeVersion(info.version) ?? info.version;
}

/// `v1.0.2` / `1.0.2` / `1.0.2+102` / `v1.0.2-102` 都归一成 `1.0.2`；认不出就返回 null。
String? normalizeVersion(String raw) {
  final tag = raw.trim().replaceFirst(RegExp('^[vV]'), '');
  final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:[-+]\d+)?$').firstMatch(tag);
  if (match == null) return null;
  return '${match.group(1)}.${match.group(2)}.${match.group(3)}';
}

int _part(String version, int index) {
  final numbers = version.split('+').first.split('.');
  return index < numbers.length ? int.tryParse(numbers[index]) ?? 0 : 0;
}

int _build(String version) => int.tryParse(version.split('+').last) ?? 0;

/// 版本号比较：先比 主.次.修订；构建号仅在两边都带时才作次级比较。大于返回正数。
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

/// 查自建清单与 GitHub Release 上有没有比 [current] 更新的版本。
///
/// 优先读自建更新清单 `latest.json`；当自建服务不可用，或自建清单版本不高于 [current] 时，
/// 自动继续检查 GitHub Release（先读 `releases/latest` 重定向，失败再退回 API）取更高版本。
Future<AppUpdate?> fetchLatestRelease(
  String current, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  var manifestReached = false;
  try {
    final hosted = await _fromManifest(timeout);
    if (hosted != null) {
      manifestReached = true;
      if (compareVersions(hosted.version, current) > 0) {
        return hosted;
      }
    }
  } on AppUpdateFailure {
    // 自建更新服务不可用时退回 GitHub
  }
  final tag = await _tagFromRedirect(timeout) ?? await _tagFromApi(timeout);
  if (tag == null) {
    if (manifestReached) return null;
    throw const AppUpdateFailure('连不上更新服务，请检查网络');
  }
  final version = normalizeVersion(tag);
  if (version == null) {
    if (manifestReached) return null;
    throw const AppUpdateFailure('发布页版本号无法识别');
  }
  if (compareVersions(version, current) <= 0) return null;
  return AppUpdate(
    version: version,
    url: 'https://github.com/$releaseRepository/releases/tag/$tag',
  );
}


/// 读自建更新清单 `{"version":"1.0.3","url":"...apk"}`，国内可直连。
/// 清单正常返回对应 [AppUpdate]；连不上或格式不对抛 [AppUpdateFailure]。
Future<AppUpdate?> _fromManifest(Duration timeout) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client
        .getUrl(Uri.parse(_manifestUrl))
        .timeout(timeout);
    request.headers
      ..set(HttpHeaders.userAgentHeader, 'yingyu-app')
      ..set(HttpHeaders.cacheControlHeader, 'no-cache');
    final response = await request.close().timeout(timeout);
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw const AppUpdateFailure('更新服务返回异常');
    }
    final json = jsonDecode(body);
    if (json is! Map) throw const AppUpdateFailure('更新清单格式不对');
    final version = normalizeVersion('${json['version']}');
    final url = json['url'];
    if (version == null || url is! String || url.isEmpty) {
      throw const AppUpdateFailure('更新清单缺少版本或下载地址');
    }
    return AppUpdate(version: version, url: url);
  } on AppUpdateFailure {
    rethrow;
  } catch (_) {
    throw const AppUpdateFailure('连不上更新服务');
  } finally {
    client.close(force: true);
  }
}

Future<String?> _tagFromRedirect(Duration timeout) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.getUrl(Uri.parse(_latestPage)).timeout(timeout);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.userAgentHeader, 'yingyu-app');
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
      ..set(HttpHeaders.userAgentHeader, 'yingyu-app');
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
