import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_update.dart';
import '../local_store.dart';
import 'widgets/focus_ring.dart';

var _checked = false;

enum _UpdateChoice { mute, skip, dismiss, download }

/// 用户在弹窗里做出的选择，选了下载时带上来源地址。
class _UpdateAction {
  const _UpdateAction(this.choice, [this.url]);

  final _UpdateChoice choice;
  final String? url;
}

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
  final action = await _askUpdate(context, current, update, manual: false);
  switch (action?.choice) {
    case _UpdateChoice.mute:
      await store.setCheckUpdates(false);
    case _UpdateChoice.skip:
      await store.setIgnoredUpdate(update.version);
    case _UpdateChoice.download:
      final url = action?.url;
      if (context.mounted && url != null) await _openRelease(context, url);
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
  final action = await _askUpdate(context, current, update, manual: true);
  final url = action?.url;
  if (action?.choice == _UpdateChoice.download && url != null && context.mounted) {
    await _openRelease(context, url);
  }
}

Future<_UpdateAction?> _askUpdate(
  BuildContext context,
  String current,
  AppUpdate update, {
  required bool manual,
}) {
  return showDialog<_UpdateAction>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('发现新版本 ${update.version}'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              manual
                  ? '当前版本 $current。选一个下载方式，装完覆盖安装即可，数据不会丢。'
                  : '当前版本 $current。选一个下载方式，装完覆盖安装即可，数据不会丢。\n\n选「不再提醒」后可在 设置 › 关于 里重新打开启动检查。',
            ),
            const SizedBox(height: 14),
            for (final source in update.sources) ...[
              _SourceTile(
                source: source,
                onTap: () => Navigator.pop(
                  dialogContext,
                  _UpdateAction(_UpdateChoice.download, source.url),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
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
              onPressed: () =>
                  Navigator.pop(dialogContext, _UpdateAction(choice)),
              child: Text(label),
            ),
          ),
      ],
    ),
  );
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({required this.source, required this.onTap});

  final UpdateSource source;
  final VoidCallback onTap;

  IconData get _icon => switch (source.kind) {
    UpdateSourceKind.mirror => Icons.bolt_rounded,
    UpdateSourceKind.selfHosted => Icons.dns_rounded,
    UpdateSourceKind.github => Icons.code_rounded,
    UpdateSourceKind.netdisk => Icons.cloud_outlined,
    UpdateSourceKind.page => Icons.open_in_new_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(12);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .45),
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(_icon, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(source.label, style: theme.textTheme.bodyLarge),
                    Text(
                      source.hint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.download_rounded, size: 18),
            ],
          ),
        ),
      ),
    );
  }
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
