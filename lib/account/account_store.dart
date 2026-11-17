import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_api.dart';

/// 内置的同步服务器。用户可以在「账号与同步」里改成自建地址。
const defaultSyncServer = 'https://yy.s1van.top:8448/yingyu';

/// 本机与云端不一致时的处理方式。
enum SyncPolicy {
  /// 和云端一致：自动下载云端数据覆盖本机。
  cloud,

  /// 使用本机：自动上传本机数据覆盖云端。
  local,
}

/// 账号会话与同步状态，落在 SharedPreferences 里。
class AccountStore extends ChangeNotifier {
  AccountStore._(this._prefs)
    : _server = _prefs.getString(_serverKey) ?? defaultSyncServer,
      _token = _prefs.getString(_tokenKey) ?? '',
      _username = _prefs.getString(_usernameKey) ?? '',
      _rev = _prefs.getInt(_revKey) ?? 0,
      _syncedAt = _prefs.getInt(_syncedAtKey) ?? 0,
      _autoSync = _prefs.getBool(_autoSyncKey) ?? true,
      _policy = _prefs.getString(_policyKey) == SyncPolicy.local.name
          ? SyncPolicy.local
          : SyncPolicy.cloud;

  static const _serverKey = 'account.server';
  static const _tokenKey = 'account.token';
  static const _usernameKey = 'account.username';
  static const _revKey = 'account.rev';
  static const _syncedAtKey = 'account.syncedAt';
  static const _autoSyncKey = 'account.autoSync';
  static const _policyKey = 'account.policy';

  final SharedPreferences _prefs;

  String _server;
  String _token;
  String _username;
  int _rev;
  int _syncedAt;
  bool _autoSync;
  SyncPolicy _policy;

  static AccountStore open(SharedPreferences prefs) {
    final store = AccountStore._(prefs);
    store._migrateLegacyServer();
    return store;
  }

  static AccountStore? _shared;

  /// 全局单例，页面之间共享登录状态。
  static Future<AccountStore> instance() async =>
      _shared ??= open(await SharedPreferences.getInstance());

  /// 1.0.2 起内置地址换成 yy.s1van.top，老版本存下的旧地址自动跟着迁。
  void _migrateLegacyServer() {
    const legacy = 'https://chat.s1van.top:8448/yingyu';
    if (_server == legacy) {
      _server = defaultSyncServer;
      _prefs.setString(_serverKey, defaultSyncServer);
    }
  }

  String get server => _server;
  String get token => _token;
  String get username => _username;
  int get rev => _rev;
  bool get autoSync => _autoSync;
  SyncPolicy get syncPolicy => _policy;
  bool get configured => _server.isNotEmpty;
  bool get loggedIn => _token.isNotEmpty && _server.isNotEmpty;
  DateTime? get syncedAt =>
      _syncedAt == 0 ? null : DateTime.fromMillisecondsSinceEpoch(_syncedAt);

  AccountApi? get api {
    if (_server.isEmpty) return null;
    return AccountApi(_server);
  }

  Future<void> setServer(String value) async {
    final normalized = AccountApi.normalizeServer(value);
    if (normalized == null) {
      throw const AccountFailure('服务器地址要形如 https://yy.s1van.top:8448/yingyu');
    }
    _server = normalized;
    await _prefs.setString(_serverKey, normalized);
    notifyListeners();
  }

  Future<void> setSyncPolicy(SyncPolicy value) async {
    _policy = value;
    await _prefs.setString(_policyKey, value.name);
    notifyListeners();
  }

  Future<void> setAutoSync(bool value) async {
    _autoSync = value;
    await _prefs.setBool(_autoSyncKey, value);
    notifyListeners();
  }

  Future<void> applySession(AccountSession session) async {
    _token = session.token;
    _username = session.username;
    _rev = session.rev;
    await _prefs.setString(_tokenKey, _token);
    await _prefs.setString(_usernameKey, _username);
    await _prefs.setInt(_revKey, _rev);
    notifyListeners();
  }

  Future<void> markSynced(int rev) async {
    _rev = rev;
    _syncedAt = DateTime.now().millisecondsSinceEpoch;
    await _prefs.setInt(_revKey, rev);
    await _prefs.setInt(_syncedAtKey, _syncedAt);
    notifyListeners();
  }

  /// 退出登录：清掉会话，但保留服务器地址，方便下次直接登录。
  Future<void> signOut() async {
    _token = '';
    _username = '';
    _rev = 0;
    _syncedAt = 0;
    await _prefs.remove(_tokenKey);
    await _prefs.remove(_usernameKey);
    await _prefs.remove(_revKey);
    await _prefs.remove(_syncedAtKey);
    notifyListeners();
  }
}
