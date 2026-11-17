import 'package:flutter/material.dart';

import '../../account/account_api.dart';
import '../../account/account_store.dart';
import '../../account/account_sync.dart';
import '../../local_store.dart';
import '../widgets/focus_ring.dart';
import '../widgets/form_text_field.dart';
import '../widgets/group_card.dart';
import '../widgets/page_header.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({super.key, required this.store});
  final LocalStore store;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final _server = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  AccountStore? _account;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    AccountStore.instance().then((account) {
      if (!mounted) return;
      setState(() {
        _account = account;
        _server.text = account.server;
        _username.text = account.username;
      });
    });
  }

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<void> Function() task) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await task();
    } on AccountFailure catch (failure) {
      _toast(failure.message);
    } catch (failure) {
      _toast('操作失败：$failure');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveServer(AccountStore account) => _run(() async {
    await account.setServer(_server.text);
    _toast('服务器地址已保存');
  });

  Future<void> _login(AccountStore account, {required bool create}) =>
      _run(() async {
        final api = account.api;
        if (api == null) throw const AccountFailure('请先填写同步服务器地址');
        final username = _username.text.trim();
        final password = _password.text;
        if (username.isEmpty || password.length < 6) {
          throw const AccountFailure('用户名不能为空，密码至少 6 位');
        }
        final session = create
            ? await api.register(username, password)
            : await api.login(username, password);
        await account.applySession(session);
        _password.clear();
        _toast(create ? '账号已创建' : '已登录');
      });

  Future<void> _sync(AccountStore account) => _run(() async {
    final message = await syncNow(account: account, store: widget.store);
    _toast(message);
  });

  Future<void> _signOut(AccountStore account) => _run(() async {
    final api = account.api;
    if (api != null) await api.logout(account.token);
    await account.signOut();
    _toast('已退出登录');
  });

  Future<void> _delete(AccountStore account) async {
    final confirmed = await _confirm(
      title: '删除账号？',
      message: '会删除云端账号和全部同步数据，本机数据保留。此操作不可恢复。',
    );
    if (confirmed != true) return;
    await _run(() async {
      final api = account.api;
      if (api != null) await api.deleteAccount(account.token);
      await account.signOut();
      _toast('账号已删除');
    });
  }

  Future<bool?> _confirm({required String title, required String message}) =>
      showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            FocusRing(
              radius: 20,
              child: TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
            ),
            FocusRing(
              radius: 20,
              child: FilledButton(
                autofocus: true,
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('确定'),
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final account = _account;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            PageHeader(title: '账号与同步', onBack: () => Navigator.of(context).maybePop()),
            if (account == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              _serverCard(account),
              if (!account.configured)
                _hint('还没有配置同步服务器。默认用内置地址，也可以改成自建服务'
                    '（server/README.md 有部署方法），填好地址就能注册账号、跨设备同步。')
              else if (!account.loggedIn)
                _loginCard(account)
              else ...[
                _accountCard(account),
                _policyCard(account),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _hint(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _card(List<Widget> children) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    child: GroupCard(children: children),
  );

  Widget _field(
    TextEditingController controller,
    String label, {
    bool obscure = false,
    bool url = false,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: FormTextField(
      controller: controller,
      obscure: obscure,
      url: url,
      enabled: !_busy,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  Widget _button(String label, VoidCallback? onPressed, {bool primary = false}) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: FocusRing(
          radius: 12,
          child: primary
              ? FilledButton(
                  onPressed: _busy ? null : onPressed,
                  child: Text(label),
                )
              : OutlinedButton(
                  onPressed: _busy ? null : onPressed,
                  child: Text(label),
                ),
        ),
      );

  Widget _serverCard(AccountStore account) => _card([
    Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Text('同步服务器', style: Theme.of(context).textTheme.titleSmall),
    ),
    _field(_server, defaultSyncServer, url: true),
    _button(
      account.configured ? '更新地址' : '保存地址',
      () => _saveServer(account),
    ),
  ]);

  Widget _loginCard(AccountStore account) => _card([
    Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Text('登录 / 注册', style: Theme.of(context).textTheme.titleSmall),
    ),
    _field(_username, '用户名'),
    _field(_password, '密码（至少 6 位）', obscure: true),
    _button('登录', () => _login(account, create: false), primary: true),
    _button('创建新账号', () => _login(account, create: true)),
    _hint('密码只在设备上做 PBKDF2 拉伸，服务器存的是校验值，看不到原始密码。'),
  ]);

  Widget _policyCard(AccountStore account) => _card([
    Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Text('同步方式', style: Theme.of(context).textTheme.titleSmall),
    ),
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: SegmentedButton<SyncPolicy>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: SyncPolicy.cloud,
            label: Text('和云端一致'),
            icon: Icon(Icons.cloud_download_outlined),
          ),
          ButtonSegment(
            value: SyncPolicy.local,
            label: Text('使用本机'),
            icon: Icon(Icons.smartphone_outlined),
          ),
        ],
        selected: {account.syncPolicy},
        onSelectionChanged: _busy
            ? null
            : (selection) async {
                await account.setSyncPolicy(selection.first);
                if (mounted) setState(() {});
              },
      ),
    ),
    _hint(
      account.syncPolicy == SyncPolicy.cloud
          ? '本机与云端不一致时，自动下载云端数据覆盖本机，适合多台设备共用一份记录。'
          : '本机与云端不一致时，自动上传本机数据覆盖云端，适合只信这台设备。',
    ),
  ]);

  Widget _accountCard(AccountStore account) {
    final synced = account.syncedAt;
    final syncedText = synced == null
        ? '还没有同步过'
        : '上次同步 ${synced.toString().substring(0, 16)}';
    return _card([
      ListTile(
        leading: const Icon(Icons.account_circle_outlined),
        title: Text(account.username),
        subtitle: Text('$syncedText · 云端版本 ${account.rev}'),
      ),
      _button('立即同步', () => _sync(account), primary: true),
      SwitchListTile(
        title: const Text('自动同步'),
        subtitle: const Text('每次观看后上传进度，启动时比对云端'),
        value: account.autoSync,
        onChanged: _busy ? null : (value) => account.setAutoSync(value),
      ),
      _button('退出登录', () => _signOut(account)),
      _button('删除账号', () => _delete(account)),
    ]);
  }
}
