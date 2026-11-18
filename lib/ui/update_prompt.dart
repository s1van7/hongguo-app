import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_update.dart';
import '../local_store.dart';
import 'widgets/focus_ring.dart';

var _checked = false;

enum _UpdateChoice { mute, skip, dismiss, download }

/// 启动时静默检查一次更新。失败不打扰用户，有新版本才弹窗。
Future<void> runStartupChecks(BuildContext context, LocalStore store) async {
  if (_checked) return;
  _checked = true;
  if (!store.checkUpdates) return;
  final String current;
  final AppUpdate? update;
  try {
    current = await currentAppVersion();
    update = await fetchLatestRelease(current);
  } catch (_) {
    return;
  }
  if (update == null || !context.mounted) return;
  if (update.version == store.ignoredUpdate) return;
  final choice = await _askUpdate(context, current, update, manual: false);
  switch (choice) {
    case _UpdateChoice.mute:
      await store.setCheckUpdates(false);
    case _UpdateChoice.skip:
      await store.setIgnoredUpdate(update.version);
    case _UpdateChoice.download:
      if (context.mounted) await _openRelease(context, update.url);
    case _UpdateChoice.dismiss || null:
      return;
  }
}

/// 设置里手动检查，结果用提示条反馈。
Future<void> checkUpdateManually(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final String current;
  final AppUpdate? update;
  try {
    current = await currentAppVersion();
    update = await fetchLatestRelease(current);
  } catch (failure) {
    messenger.showSnackBar(
      SnackBar(content: Text('检查更新失败：$failure')),
    );
    return;
  }
  if (update == null) {
    messenger.showSnackBar(const SnackBar(content: Text('已是最新版本')));
    return;
  }
  if (!context.mounted) return;
  final choice = await _askUpdate(context, current, update, manual: true);
  if (choice == _UpdateChoice.download && context.mounted) {
    await _openRelease(context, update.url);
  }
}

Future<_UpdateChoice?> _askUpdate(
  BuildContext context,
  String current,
  AppUpdate update, {
  required bool manual,
}) {
  return showDialog<_UpdateChoice>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('发现新版本 ${update.version}'),
      content: Text(
        manual
            ? '当前版本 $current。点「去下载」直接下载安装包，装完覆盖安装即可，数据不会丢。'
            : '当前版本 $current。点「去下载」直接下载安装包，装完覆盖安装即可，数据不会丢。\n\n选「不再提醒」后可在 设置 › 关于 里重新打开启动检查。',
      ),
      actions: [
        for (final (choice, label) in [
          if (!manual) (_UpdateChoice.mute, '不再提醒'),
          if (!manual) (_UpdateChoice.skip, '忽略此版本'),
          (_UpdateChoice.dismiss, '以后再说'),
        ])
          FocusRing(
            radius: 20,
            child: TextButton(
              onPressed: () => Navigator.pop(dialogContext, choice),
              child: Text(label),
            ),
          ),
        FocusRing(
          radius: 20,
          child: FilledButton(
            autofocus: true,
            onPressed: () =>
                Navigator.pop(dialogContext, _UpdateChoice.download),
            child: const Text('去下载'),
          ),
        ),
      ],
    ),
  );
}

Future<void> _openRelease(BuildContext context, String url) async {
  final opened = await launchUrl(
    Uri.parse(url),
    mode: LaunchMode.externalApplication,
  ).catchError((_) => false);
  if (opened) return;
  await Clipboard.setData(ClipboardData(text: url));
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法打开浏览器，链接已复制')));
  }
}
