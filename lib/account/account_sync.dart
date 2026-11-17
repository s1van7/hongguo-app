import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../local_store.dart';
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

/// 本机与云端版本不一致时，按用户选的策略决定方向。
Future<String> _resolve(
  AccountApi api,
  AccountStore account,
  LocalStore store,
  AccountState state,
) async {
  if (account.syncPolicy == SyncPolicy.cloud) {
    await pullRemote(api, account, store);
    return '已下载云端数据';
  }
  await pushLocal(api, account, store, baseRev: state.rev);
  return '已上传本机数据';
}

/// 一次完整同步：云端没变就上传，云端更新则按同步策略处理。
Future<String> syncNow({
  required AccountStore account,
  required LocalStore store,
}) async {
  final api = account.api;
  if (api == null || !account.loggedIn) {
    throw const AccountFailure('请先登录账号');
  }
  final state = await api.state(account.token);
  if (state.rev == 0 || state.rev == account.rev) {
    await pushLocal(api, account, store, baseRev: state.rev);
    return '已上传本机数据';
  }
  return _resolve(api, account, store, state);
}

Timer? _autoSyncTimer;

/// 观看记录变化后延迟上传，把短时间内的多次写入合并成一次请求。
void scheduleAutoSync(LocalStore store) {
  _autoSyncTimer?.cancel();
  _autoSyncTimer = Timer(const Duration(seconds: 4), () {
    unawaited(_autoSync(store));
  });
}

/// 静默同步：没变化就不动，冲突按策略处理，失败不打扰用户。
Future<void> _autoSync(LocalStore store) async {
  final account = await AccountStore.instance();
  if (!account.loggedIn || !account.autoSync) return;
  final api = account.api;
  if (api == null) return;
  try {
    final state = await api.state(account.token);
    if (state.rev == 0 || state.rev == account.rev) {
      await pushLocal(api, account, store, baseRev: state.rev);
    } else {
      await _resolve(api, account, store, state);
    }
  } catch (_) {
    // 网络断了或者刚好被别的设备抢先，下次观看再同步
  }
}

/// 启动时静默比对云端，按同步策略补齐差异。
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
  if (state.rev <= account.rev) return;
  try {
    final message = await _resolve(api, account, store, state);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  } catch (failure) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('同步失败：$failure')));
    }
  }
}
