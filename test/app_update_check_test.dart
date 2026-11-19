import 'package:duanju_app/app_update.dart';
import 'package:flutter_test/flutter_test.dart';

const _tag = 'v1.1.7';

const _assets = [
  ReleaseAsset(
    name: 'yingyu-1.1.7-arm64-v8a.apk',
    url: 'https://github.com/x/yingyu-1.1.7-arm64-v8a.apk',
  ),
  ReleaseAsset(
    name: 'yingyu-1.1.7-armeabi-v7a.apk',
    url: 'https://github.com/x/yingyu-1.1.7-armeabi-v7a.apk',
  ),
  ReleaseAsset(
    name: 'yingyu-1.1.7-windows-x64-setup.exe',
    url: 'https://github.com/x/yingyu-1.1.7-windows-x64-setup.exe',
  ),
  ReleaseAsset(
    name: 'yingyu-1.1.7-windows-x64.zip',
    url: 'https://github.com/x/yingyu-1.1.7-windows-x64.zip',
  ),
];

AppUpdate _manifest(String version) => AppUpdate(
  version: version,
  sources: [
    UpdateSource(
      kind: UpdateSourceKind.selfHosted,
      label: '自建下载',
      hint: '走你的服务器',
      url: 'https://dl.example/$version/setup.exe',
    ),
    const UpdateSource(
      kind: UpdateSourceKind.netdisk,
      label: '网盘下载',
      hint: '夸克网盘',
      url: 'https://pan.example/share',
    ),
  ],
);

void main() {
  test('版本号归一与比较', () {
    expect(normalizeVersion('v1.1.7'), '1.1.7');
    expect(normalizeVersion('1.1.7+117'), '1.1.7');
    expect(normalizeVersion('v1.1.7-117'), '1.1.7');
    expect(normalizeVersion('v1.2'), isNull);
    expect(normalizeVersion('latest'), isNull);
    expect(compareVersions('1.0.1+3', '1.0.1+2'), greaterThan(0));
    expect(compareVersions('1.0.1+3', '1.0.1+3'), 0);
    expect(compareVersions('1.0.2+0', '1.0.1+9'), greaterThan(0));
  });

  test('清单没跟上时，靠 GitHub 产物也能给出多个来源', () {
    final sources = buildUpdateSources(
      tag: _tag,
      version: '1.1.7',
      assets: _assets,
      platform: 'windows',
    );
    expect(sources.map((s) => s.kind), [
      UpdateSourceKind.mirror,
      UpdateSourceKind.github,
      UpdateSourceKind.page,
    ]);
    // Windows 优先安装版，不是便携压缩包
    expect(
      sources.first.url,
      'https://ghfast.top/https://github.com/x/yingyu-1.1.7-windows-x64-setup.exe',
    );
    expect(sources.last.url, endsWith('/releases/tag/$_tag'));
  });

  test('Android 优先 64 位包', () {
    final sources = buildUpdateSources(
      tag: _tag,
      version: '1.1.7',
      assets: _assets,
      platform: 'android',
    );
    expect(sources.first.url, contains('arm64-v8a'));
  });

  test('清单版本对得上时才用清单里的来源，且不重复', () {
    final sources = buildUpdateSources(
      tag: _tag,
      version: '1.1.7',
      assets: _assets,
      manifest: _manifest('1.1.7'),
      platform: 'windows',
    );
    expect(
      sources.map((s) => s.kind),
      containsAll([
        UpdateSourceKind.mirror,
        UpdateSourceKind.selfHosted,
        UpdateSourceKind.github,
        UpdateSourceKind.netdisk,
        UpdateSourceKind.page,
      ]),
    );
    expect(sources.map((s) => s.url).toSet().length, sources.length);
  });

  test('清单还停在旧版本时，不掺和它的安装包地址', () {
    final sources = buildUpdateSources(
      tag: _tag,
      version: '1.1.7',
      assets: _assets,
      manifest: _manifest('1.1.6'),
      platform: 'windows',
    );
    expect(
      sources.map((s) => s.kind),
      isNot(contains(UpdateSourceKind.selfHosted)),
    );
    expect(sources.first.kind, UpdateSourceKind.mirror);
  });

  test('拿不到产物列表时至少还有发布页', () {
    final sources = buildUpdateSources(tag: _tag, version: '1.1.7');
    expect(sources.single.kind, UpdateSourceKind.page);
  });

  test('线上最新版本', () async {
    final AppUpdate? update;
    try {
      update = await fetchLatestRelease('1.0.1');
    } on AppUpdateFailure {
      markTestSkipped('离线环境，跳过线上检查');
      return;
    }
    expect(update, isNotNull);
    expect(update!.version, isNot('1.0.1'));
    // 测试跑在 Linux 上，清单没有 linux 条目，这里只保证拿得到地址
    expect(update.sources, isNotEmpty);
    final none = await fetchLatestRelease('99.0.0');
    expect(none, isNull);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
