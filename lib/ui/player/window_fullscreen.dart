import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import '../../app_device.dart';
import '../shell/window_caption.dart';

Future<void> setWindowFullScreen(bool value) async {
  if (value) {
    // 先交还系统标题栏，避免自绘浮层给全屏留出边框
    await syncTitleBarWithFullscreen(true);
    await _apply(true);
  } else {
    await _apply(false);
    await syncTitleBarWithFullscreen(false);
  }
}

Future<void> _apply(bool value) async {
  try {
    if (defaultTargetPlatform == TargetPlatform.windows) {
      await AppDevice.channel.invokeMethod<void>('setFullScreen', {
        'enabled': value,
      });
    } else {
      await windowManager.setFullScreen(value);
    }
  } catch (_) {}
}
