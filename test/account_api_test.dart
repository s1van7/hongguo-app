import 'package:duanju_app/account/account_api.dart';
import 'package:flutter_test/flutter_test.dart';

const server = 'http://127.0.0.1:8787';

void main() {
  test('authKey 稳定且是 64 位十六进制', () async {
    final first = await deriveAuthKey('Alice', 'secret123');
    final again = await deriveAuthKey(' alice ', 'secret123');
    final other = await deriveAuthKey('alice', 'secret124');
    expect(first, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(first, again, reason: '用户名大小写和空格不影响结果');
    expect(first, isNot(other));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('注册、登录、上传、拉取、删除', () async {
    final api = AccountApi(server, timeout: const Duration(seconds: 5));
    final name = 't${DateTime.now().millisecondsSinceEpoch % 1000000}';
    final AccountSession session;
    try {
      session = await api.register(name, 'secret123');
    } on AccountFailure catch (failure) {
      markTestSkipped('本地同步服务未启动：${failure.message}');
      return;
    }
    expect(session.token, isNotEmpty);
    final login = await api.login(name, 'secret123');
    expect(login.username, name);
    final rev = await api.push(
      login.token,
      rev: 0,
      payload: '{"profiles":[]}',
      device: 'test',
    );
    expect(rev, 1);
    final snapshot = await api.pull(login.token);
    expect(snapshot.rev, 1);
    expect(snapshot.payload, '{"profiles":[]}');
    expect(snapshot.device, 'test');
    await expectLater(
      api.push(login.token, rev: 0, payload: '{}', device: 'test'),
      throwsA(isA<AccountFailure>()),
    );
    await api.deleteAccount(login.token);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
