import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

/// 账号服务返回的错误，message 直接可以展示给用户。
class AccountFailure implements Exception {
  const AccountFailure(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => message;
}

class AccountSession {
  const AccountSession({
    required this.token,
    required this.username,
    required this.rev,
    required this.updatedAt,
  });
  final String token;
  final String username;
  final int rev;
  final int updatedAt;

  factory AccountSession.fromJson(Map<String, dynamic> json) => AccountSession(
    token: json['token'] as String? ?? '',
    username: json['username'] as String? ?? '',
    rev: (json['rev'] as num?)?.toInt() ?? 0,
    updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
  );
}

class AccountState {
  const AccountState({
    required this.username,
    required this.rev,
    required this.updatedAt,
    required this.device,
    required this.bytes,
  });
  final String username;
  final int rev;
  final int updatedAt;
  final String device;
  final int bytes;

  factory AccountState.fromJson(Map<String, dynamic> json) => AccountState(
    username: json['username'] as String? ?? '',
    rev: (json['rev'] as num?)?.toInt() ?? 0,
    updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
    device: json['device'] as String? ?? '',
    bytes: (json['bytes'] as num?)?.toInt() ?? 0,
  );
}

class SyncSnapshot {
  const SyncSnapshot({
    required this.rev,
    required this.updatedAt,
    required this.device,
    required this.payload,
  });
  final int rev;
  final int updatedAt;
  final String device;
  final String payload;

  bool get isEmpty => payload.isEmpty;

  factory SyncSnapshot.fromJson(Map<String, dynamic> json) => SyncSnapshot(
    rev: (json['rev'] as num?)?.toInt() ?? 0,
    updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
    device: json['device'] as String? ?? '',
    payload: json['payload'] as String? ?? '',
  );
}

/// PBKDF2-HMAC-SHA256（单块，32 字节），返回 64 位十六进制。
///
/// 放在独立 isolate 里跑，40k 次迭代不会卡界面。
Future<String> deriveAuthKey(String username, String password) =>
    Isolate.run(() => _deriveAuthKey(username, password));

String _deriveAuthKey(String username, String password) {
  final salt = utf8.encode('yingyu|${username.trim().toLowerCase()}');
  final hmac = Hmac(sha256, utf8.encode(password));
  final block = [...salt, 0, 0, 0, 1];
  var u = hmac.convert(block).bytes;
  final result = List<int>.from(u);
  for (var round = 1; round < 40000; round++) {
    u = hmac.convert(u).bytes;
    for (var i = 0; i < result.length; i++) {
      result[i] ^= u[i];
    }
  }
  return result.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

class AccountApi {
  AccountApi(this.baseUrl, {this.timeout = const Duration(seconds: 15)});

  /// 规范化服务器地址，去掉末尾斜杠；不合法返回 null。
  static String? normalizeServer(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) return null;
    if (uri.scheme != 'https' && uri.scheme != 'http') return null;
    return text.replaceAll(RegExp(r'/+$'), '');
  }

  final String baseUrl;
  final Duration timeout;

  Future<AccountSession> register(String username, String password) async {
    final json = await _send('POST', '/v1/register', {
      'username': username,
      'authKey': await deriveAuthKey(username, password),
    });
    return AccountSession.fromJson(json);
  }

  Future<AccountSession> login(String username, String password) async {
    final json = await _send('POST', '/v1/login', {
      'username': username,
      'authKey': await deriveAuthKey(username, password),
    });
    return AccountSession.fromJson(json);
  }

  Future<AccountState> state(String token) async =>
      AccountState.fromJson(await _send('GET', '/v1/state', null, token: token));

  Future<SyncSnapshot> pull(String token) async =>
      SyncSnapshot.fromJson(await _send('GET', '/v1/sync', null, token: token));

  /// 上传快照。返回新的 rev；rev 不匹配抛 [AccountFailure]（status 409）。
  Future<int> push(
    String token, {
    required int rev,
    required String payload,
    required String device,
  }) async {
    final json = await _send('PUT', '/v1/sync', {
      'rev': rev,
      'payload': payload,
      'device': device,
    }, token: token);
    return (json['rev'] as num?)?.toInt() ?? rev + 1;
  }

  Future<void> logout(String token) async {
    try {
      await _send('POST', '/v1/logout', null, token: token);
    } on AccountFailure {
      // 注销失败不影响本地退出
    }
  }

  Future<void> deleteAccount(String token) async {
    await _send('DELETE', '/v1/account', null, token: token);
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path,
    Map<String, Object?>? body, {
    String? token,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final uri = Uri.parse('$baseUrl$path');
      final request = await client.openUrl(method, uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.userAgentHeader, 'yingyu-app');
      if (token != null && token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType.json;
        request.headers.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(timeout);
      final text = await response.transform(utf8.decoder).join().timeout(timeout);
      Map<String, dynamic> decoded;
      try {
        final value = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
        decoded = value is Map<String, dynamic> ? value : <String, dynamic>{};
      } catch (_) {
        throw const AccountFailure('服务器返回的内容无法识别');
      }
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return decoded;
      }
      final message = decoded['error'];
      throw AccountFailure(
        message is String && message.isNotEmpty ? message : '请求失败（${response.statusCode}）',
        status: response.statusCode,
      );
    } on AccountFailure {
      rethrow;
    } on SocketException {
      throw const AccountFailure('连不上同步服务器，检查地址和网络');
    } on HttpException {
      throw const AccountFailure('同步服务器没有响应');
    } catch (error) {
      if (error is AccountFailure) rethrow;
      throw AccountFailure('请求失败：$error');
    } finally {
      client.close(force: true);
    }
  }
}
