import 'dart:io';

import 'package:flutter/material.dart';

import '../local_store.dart';
import '../ui/widgets/focus_ring.dart';
import 'account_api.dart';
import 'account_store.dart';

String get deviceLabel {
  final version = Platform.operatingSystemVersion.split(' ').first;
  return switch (Platform.operatingSystem) {
    'android' => 'Android',
    'windows' => 'Windows',
    'ios' => 'iOS',
    'macos' => 'macOS',
    'linux' => 'Linux',
    _ => '${Platform.operatingSystem} $version',
  };
}

/// 上传本机数据，[baseRev] 是云端当前的 rev（乐观锁）。
Future<int> pushLocal(
  AccountApi api,
  AccountStore account,
  LocalStore store, {
  required int baseRev,
}) async {
  final payload = await store.exportBackup();
  final rev = await api.push(
    account.token,
    rev: baseRev,
    payload: payload,
    device: deviceLabel,
  );
  await account.markSynced(rev);
  return rev;
}

/// 把云端快照写回本机。
Future<void> pullRemote(
  AccountApi api,
  AccountStore account,
  LocalStore store,
) async {
  final snapshot = await api.pull(account.token);
  if (snapshot.isEmpty) {
    throw const AccountFailure('云端还没有数据，先在这台设备上传一次');
  }
  store.validateBackup(snapshot.payload);
  await store.importBackup(snapshot.payload);
  await account.markSynced(snapshot.rev);
}

/// 一次完整同步：云端没变就上传，云端更新就问用户要哪个方向。
Future<String> syncNow(
  BuildContext context, {
  required AccountStore account,
  required LocalStore store,
}) async {
  final api = account.api;
  if (api == null || !account.loggedIn) {
    throw const AccountFailure('请先登录账号');
  }
  final state = await api.state(account.token);
  if (state.rev == 0) {
    await pushLocal(api, account, store, baseRev: 0);
    return '已上传本机数据';
  }
  if (state.rev == account.rev) {
    await pushLocal(api, account, store, baseRev: state.rev);
    return '已上传本机数据';
  }
  if (!context.mounted) return '已取消';
  final choice = await _askDirection(context, state);
  if (choice == null) return '已取消';
  if (choice == _Direction.download) {
    await pullRemote(api, account, store);
    return '已下载云端数据';
  }
  await pushLocal(api, account, store, baseRev: state.rev);
  return '已上传本机数据';
}

enum _Direction { download, upload }

Future<_Direction?> _askDirection(BuildContext context, AccountState state) {
  final time = state.updatedAt == 0
      ? '未知时间'
      : DateTime.fromMillisecondsSinceEpoch(
          state.updatedAt,
        ).toString().substring(0, 16);
  return showDialog<_Direction>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('云端有更新的数据'),
      content: Text(
        '云端在 $time 由 ${state.device.isEmpty ? '其他设备' : state.device} 上传过。\n'
        '下载会用云端数据覆盖本机（本机的追剧、记录、设置会被替换）；'
        '上传会用本机数据覆盖云端。',
      ),
      actions: [
        FocusRing(
          radius: 20,
          child: TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
        ),
        FocusRing(
          radius: 20,
          child: TextButton(
            onPressed: () => Navigator.pop(dialogContext, _Direction.upload),
            child: const Text('上传本机'),
          ),
        ),
        FocusRing(
          radius: 20,
          child: FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(dialogContext, _Direction.download),
            child: const Text('下载云端'),
          ),
        ),
      ],
    ),
  );
}

/// 启动时静默比对云端，有新数据才提示。
Future<void> runStartupSync(BuildContext context, LocalStore store) async {
  final account = await AccountStore.instance();
  if (!account.loggedIn || !account.autoSync) return;
  final api = account.api;
  if (api == null) return;
  AccountState state;
  try {
    state = await api.state(account.token);
  } catch (_) {
    return;
  }
  if (!context.mounted || state.rev <= account.rev) return;
  final choice = await _askDirection(context, state);
  if (choice == null || !context.mounted) return;
  try {
    if (choice == _Direction.download) {
      await pullRemote(api, account, store);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已同步云端数据')));
      }
    } else {
      await pushLocal(api, account, store, baseRev: state.rev);
    }
  } catch (failure) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('同步失败：$failure')));
    }
  }
}
