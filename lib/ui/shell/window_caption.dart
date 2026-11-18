import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../app_build.dart';

/// 桌面端自绘标题栏高度。
const double kAppCaptionHeight = 32;

/// Windows 下去掉系统标题栏，改由应用自己画一条浮层，画面就能一直铺到窗口最上沿。
bool get appCaptionEnabled => !kIsWeb && Platform.isWindows;

/// 沉浸状态（视频全屏、页面全屏）。为真时标题栏、侧栏都要让位。
final ValueNotifier<bool> windowImmersive = ValueNotifier(false);

/// 启动时把系统标题栏换成自绘浮层。
Future<void> useCustomTitleBar() async {
  if (!appCaptionEnabled) return;
  try {
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
  } catch (_) {}
}

/// 全屏切换时同步标题栏样式：全屏必须交还给系统，退出全屏再换回浮层。
Future<void> syncTitleBarWithFullscreen(bool fullscreen) async {
  windowImmersive.value = fullscreen;
  if (!appCaptionEnabled) return;
  try {
    await windowManager.setTitleBarStyle(
      fullscreen ? TitleBarStyle.normal : TitleBarStyle.hidden,
    );
  } catch (_) {}
}

/// 浮在画面上的窗口控制条：中间可拖动（双击最大化），右侧最小化/最大化/关闭。
class WindowCaptionBar extends StatefulWidget {
  const WindowCaptionBar({super.key, this.overlay = false});

  /// 沉浸模式：整条透明，直接压在视频画面上，只留控制按钮。
  final bool overlay;

  @override
  State<WindowCaptionBar> createState() => _WindowCaptionBarState();
}

class _WindowCaptionBarState extends State<WindowCaptionBar>
    with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(_syncMaximized());
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  Future<void> _syncMaximized() async {
    try {
      final value = await windowManager.isMaximized();
      if (mounted && value != _maximized) setState(() => _maximized = value);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final foreground = widget.overlay
        ? Colors.white
        : (dark ? Colors.white : Colors.black.withValues(alpha: .82));
    final brightness = widget.overlay
        ? Brightness.dark
        : (dark ? Brightness.dark : Brightness.light);
    return SizedBox(
      height: kAppCaptionHeight,
      child: Row(
        children: [
          Expanded(
            child: DragToMoveArea(
              child: Row(
                children: [
                  if (!widget.overlay) ...[
                    const SizedBox(width: 14),
                    Icon(
                      Icons.movie_filter_rounded,
                      size: 15,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      appName,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: foreground.withValues(alpha: .78),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (widget.overlay)
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: .38),
                  ],
                ),
              ),
              child: _buttons(brightness),
            )
          else
            _buttons(brightness),
        ],
      ),
    );
  }

  Widget _buttons(Brightness brightness) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      WindowCaptionButton.minimize(
        brightness: brightness,
        onPressed: () => unawaited(windowManager.minimize()),
      ),
      if (_maximized)
        WindowCaptionButton.unmaximize(
          brightness: brightness,
          onPressed: () => unawaited(_toggleMaximize()),
        )
      else
        WindowCaptionButton.maximize(
          brightness: brightness,
          onPressed: () => unawaited(_toggleMaximize()),
        ),
      WindowCaptionButton.close(
        brightness: brightness,
        onPressed: () => unawaited(windowManager.close()),
      ),
    ],
  );

  Future<void> _toggleMaximize() async {
    try {
      final maximized = await windowManager.isMaximized();
      if (maximized) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
    } catch (_) {}
    await _syncMaximized();
  }
}
