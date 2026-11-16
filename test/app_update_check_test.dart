import 'package:duanju_app/app_update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('版本号归一与比较', () {
    expect(normalizeVersion('v1.0.1-3'), '1.0.1+3');
    expect(normalizeVersion('1.0.1+3'), '1.0.1+3');
    expect(normalizeVersion('v1.2'), isNull);
    expect(compareVersions('1.0.1+3', '1.0.1+2'), greaterThan(0));
    expect(compareVersions('1.0.1+3', '1.0.1+3'), 0);
    expect(compareVersions('1.0.2+0', '1.0.1+9'), greaterThan(0));
  });

  test('线上最新版本', () async {
    final AppUpdate? update;
    try {
      update = await fetchLatestRelease('1.0.1+2');
    } on AppUpdateFailure {
      markTestSkipped('离线环境，跳过线上检查');
      return;
    }
    expect(update, isNotNull);
    expect(update!.version, isNot('1.0.1+2'));
    expect(update.url, contains('/releases/tag/'));
    final none = await fetchLatestRelease('1.0.1+3');
    expect(none, isNull);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
