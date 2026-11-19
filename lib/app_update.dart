import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

/// 下载来源：同一个版本可以有多个来源，让用户自己挑。
enum UpdateSourceKind { mirror, selfHosted, github, netdisk, page }

class UpdateSource {
  const UpdateSource({
    required this.kind,
    required this.label,
    required this.hint,
    required this.url,
  });

  final UpdateSourceKind kind;
  final String label;
  final String hint;
  final String url;
}

/// GitHub Release 上的一个产物文件。
class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.url});

  final String name;
  final String url;
}

class AppUpdate {
  const AppUpdate({required this.version, required this.sources});

  final String version;
  final List<UpdateSource> sources;

  /// 默认来源（清单里排第一的那个）。
  String get url => sources.first.url;
}

/// 发布仓库。改仓库时这里和 `.github/workflows` 一起改。
const releaseRepository = 's1van7/yingyu';

const _latestPage = 'https://github.com/$releaseRepository/releases/latest';
const _manifestUrl = 'https://yy.s1van.top:8448/dl/latest.json';
const _latestApi =
    'https://api.github.com/repos/$releaseRepository/releases/latest';

/// GitHub 加速镜像前缀，和清单里 `mirror` 字段用的是同一家。
const _mirrorPrefix = 'https://ghfast.top/';

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
  AppUpdate? hosted;
  try {
    hosted = await _fromManifest(timeout);
  } on AppUpdateFailure {
    // 自建更新服务不可用时退回 GitHub
  }
  final manifestReached = hosted != null;
  if (hosted != null && compareVersions(hosted.version, current) > 0) {
    return hosted;
  }
  // 清单已经应答过说明网络没问题，GitHub 只是复核，没必要等满 8 秒
  final fallback = manifestReached ? const Duration(seconds: 3) : timeout;
  // 重定向能拿到 tag（国内往往比 api.github.com 好连），API 能拿到产物列表，
  // 两个并发跑，谁也不拖谁。
  final (redirectTag, release) = await (
    _tagFromRedirect(fallback),
    _releaseFromApi(fallback),
  ).wait;
  final tag = release?.tag ?? redirectTag;
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
    sources: buildUpdateSources(
      tag: tag,
      version: version,
      assets: release?.assets ?? const [],
      manifest: hosted,
    ),
  );
}

/// 汇总这一版能用的下载方式，顺序就是弹窗里的推荐顺序。
///
/// 清单还没跟上（或者干脆连不上）时，靠 GitHub 上的产物名拼出加速镜像和直连地址，
/// 保证弹窗里始终有好几个来源可选，而不是只剩一个「打开 GitHub 发布页」。
/// 清单版本和最终版本对不上时不掺和它的来源，免得把上一版的安装包当成新版给出去。
List<UpdateSource> buildUpdateSources({
  required String tag,
  required String version,
  List<ReleaseAsset> assets = const [],
  AppUpdate? manifest,
  String? platform,
}) {
  final sources = <UpdateSource>[];
  void add(UpdateSource source) {
    if (source.url.isEmpty) return;
    if (sources.any((s) => s.url == source.url)) return;
    sources.add(source);
  }

  final asset = _pickAsset(assets, platform ?? _platformKey);
  if (asset != null) {
    add(
      UpdateSource(
        kind: UpdateSourceKind.mirror,
        label: '加速下载',
        hint: 'GitHub 镜像，通常最快',
        url: '$_mirrorPrefix${asset.url}',
      ),
    );
    add(
      UpdateSource(
        kind: UpdateSourceKind.github,
        label: 'GitHub 下载',
        hint: '需要能直连 github.com',
        url: asset.url,
      ),
    );
  }
  if (manifest != null && manifest.version == version) {
    for (final source in manifest.sources) {
      add(source);
    }
  }
  add(
    UpdateSource(
      kind: UpdateSourceKind.page,
      label: '打开 GitHub 发布页',
      hint: '手动挑对应平台的安装包',
      url: 'https://github.com/$releaseRepository/releases/tag/$tag',
    ),
  );
  return sources;
}

/// 按产物命名挑出当前平台的安装包。
///
/// Android 同一版有多个 ABI，优先 64 位；Windows 优先安装版而不是便携压缩包。
ReleaseAsset? _pickAsset(List<ReleaseAsset> assets, String platform) {
  final wanted = switch (platform) {
    'windows' => const ['.exe'],
    'android' => const ['.apk'],
    'macos' => const ['.dmg', '.zip'],
    'linux' => const ['.tar.gz', '.appimage'],
    'ios' => const ['.ipa'],
    _ => const <String>[],
  };
  if (wanted.isEmpty) return null;
  final found = assets
      .where(
        (asset) => wanted.any((ext) => asset.name.toLowerCase().endsWith(ext)),
      )
      .toList();
  if (found.isEmpty) return null;
  if (platform == 'android') {
    for (final abi in const ['arm64-v8a', 'armeabi-v7a', 'x86_64']) {
      final hit = found.where((asset) => asset.name.contains(abi));
      if (hit.isNotEmpty) return hit.first;
    }
  }
  if (platform == 'windows') {
    final setup = found.where((asset) => asset.name.contains('setup'));
    if (setup.isNotEmpty) return setup.first;
  }
  return found.first;
}

/// 清单里的平台键：Windows 取 exe，Android 取 apk。
String get _platformKey {
  if (Platform.isWindows) return 'windows';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isLinux) return 'linux';
  if (Platform.isIOS) return 'ios';
  return 'android';
}

/// 按平台收集下载来源：加速镜像、自建、GitHub 直连，有几个给几个。
///
/// 老清单只有顶层 `url`，也照样认。
List<UpdateSource> _manifestSources(Map json) {
  final sources = <UpdateSource>[];
  void add(UpdateSourceKind kind, String label, String hint, Object? raw) {
    if (raw is! String || raw.isEmpty) return;
    if (sources.any((s) => s.url == raw)) return;
    sources.add(UpdateSource(kind: kind, label: label, hint: hint, url: raw));
  }

  final platforms = json['platforms'];
  final entry = platforms is Map ? platforms[_platformKey] : null;
  final map = entry is Map ? entry : const {};
  add(UpdateSourceKind.mirror, '加速下载', 'GitHub 镜像，通常最快', map['mirror']);
  add(UpdateSourceKind.selfHosted, '自建下载', '走你的服务器，稳定但带宽有限', map['url']);
  add(UpdateSourceKind.github, 'GitHub 下载', '需要能直连 github.com', map['github']);
  add(UpdateSourceKind.netdisk, '网盘下载', '夸克网盘，浏览器打开即可下载', map['lanzou']);
  if (sources.isEmpty) {
    add(UpdateSourceKind.selfHosted, '下载', '打开下载地址', json['url']);
  }
  return sources;
}

/// 读自建更新清单，国内可直连。
///
/// 形如 `{"version":"1.0.6","platforms":{"android":{"url":"...apk"},
/// "windows":{"url":"...exe"}}}`。清单正常返回对应 [AppUpdate]；
/// 连不上或格式不对抛 [AppUpdateFailure]。
Future<AppUpdate?> _fromManifest(Duration timeout) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final request = await client
        .getUrl(Uri.parse('$_manifestUrl?t=$stamp'))
        .timeout(timeout);
    request.headers
      ..set(HttpHeaders.userAgentHeader, 'yingyu-app')
      ..set(HttpHeaders.cacheControlHeader, 'no-cache');
    final response = await request.close().timeout(timeout);
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    if (response.statusCode != 200) {
      throw const AppUpdateFailure('更新服务返回异常');
    }
    final json = jsonDecode(body);
    if (json is! Map) throw const AppUpdateFailure('更新清单格式不对');
    final version = normalizeVersion('${json['version']}');
    final sources = _manifestSources(json);
    if (version == null || sources.isEmpty) {
      throw const AppUpdateFailure('更新清单缺少版本或下载地址');
    }
    return AppUpdate(version: version, sources: sources);
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
    final request = await client
        .getUrl(Uri.parse(_latestPage))
        .timeout(timeout);
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

Future<({String tag, List<ReleaseAsset> assets})?> _releaseFromApi(
  Duration timeout,
) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.getUrl(Uri.parse(_latestApi)).timeout(timeout);
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set(HttpHeaders.userAgentHeader, 'yingyu-app');
    final response = await request.close().timeout(timeout);
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    final tag = decoded['tag_name'];
    if (tag is! String) return null;
    final assets = <ReleaseAsset>[];
    if (decoded['assets'] case final List list) {
      for (final item in list) {
        if (item is! Map) continue;
        final name = item['name'];
        final url = item['browser_download_url'];
        if (name is String && url is String && url.isNotEmpty) {
          assets.add(ReleaseAsset(name: name, url: url));
        }
      }
    }
    return (tag: tag, assets: assets);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
