import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app_device.dart';
import 'core_bridge.dart';
import 'crash_log.dart';
import 'diary_service.dart';
import 'local_files.dart';
import 'local_store.dart';
import 'picture_in_picture.dart';
import 'portable_data.dart';
import 'ui/app.dart';
import 'ui/shell/window_caption.dart';
import 'ui/theme/app_theme.dart';
import 'window_frame.dart';
import 'window_on_top.dart';
import 'windows_data_migration.dart';

Future<void> main() async {
  // 任何未捕获异常都记下来：桌面端闪退时用户看不到控制台，只能靠日志
  PlatformDispatcher.instance.onError = (error, stack) {
    CrashLog.record('未捕获异常', error, stack);
    return true; // 吞掉异常，别让 isolate 直接挂掉（挂掉就是「闪退」）
  };
  runZonedGuarded(() {
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      CrashLog.record('界面异常', details.exception, details.stack);
    };
    unawaited(_boot());
  }, (error, stack) => CrashLog.record('启动异常', error, stack));
}

Future<void> _boot() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(AppTheme.systemBars(Brightness.dark));
  }
  if (Platform.isWindows) {
    enablePortableData();
    // 窗口相关的初始化失败不该拖死整个应用：记下来，照样把界面拉起来
    try {
      if (portableDataPath == null) await migrateWindowsData();
      await windowManager.ensureInitialized();
      await rememberWindowFrame();
      await useCustomTitleBar();
    } catch (failure, stack) {
      CrashLog.record('窗口初始化失败', failure, stack);
    }
  }
  if (Platform.isMacOS) {
    try {
      await windowManager.ensureInitialized();
      await windowManager.waitUntilReadyToShow(
        const WindowOptions(
          size: Size(1280, 800),
          minimumSize: desktopMinimumSize,
          center: true,
        ),
        () async {
          await rememberWindowFrame();
          await windowManager.show();
        },
      );
    } catch (failure, stack) {
      CrashLog.record('窗口初始化失败', failure, stack);
    }
  }
  if (Platform.isWindows || Platform.isMacOS) {
    try {
      await restoreWindowOnTop();
    } catch (failure, stack) {
      CrashLog.record('窗口置顶恢复失败', failure, stack);
    }
  }
  try {
    MediaKit.ensureInitialized();
  } catch (failure, stack) {
    CrashLog.record('播放内核初始化失败', failure, stack);
  }
  var device = const AppDevice();
  try {
    device = await AppDevice.detect();
  } catch (failure, stack) {
    CrashLog.record('设备信息读取失败', failure, stack);
  }
  var rendering = '';
  if (Platform.isAndroid) {
    try {
      rendering =
          ', 渲染: ${await AppDevice.compatibleRendering() ? 'skia' : 'impeller'}';
    } catch (_) {}
  }
  DiaryService.add(
    '[App] 应用启动，版本: ${device.version}, '
    '平台: ${Platform.operatingSystem}$rendering',
  );
  unawaited(
    CrashLog.write('启动 版本: ${device.version}, 平台: ${Platform.operatingSystem}'),
  );
  runApp(AppBootstrap(device: device));
}

class AppBootstrap extends StatefulWidget {
  const AppBootstrap({super.key, this.device = const AppDevice()});
  final AppDevice device;
  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap>
    with WidgetsBindingObserver {
  final repository = NativeRepository();
  LocalStore? store;
  Object? error;
  late AppDevice device = widget.device;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 首帧能出来就说明引擎和 Dart 都起来了，闪退时对比这两行就能定位阶段
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(CrashLog.write('首帧渲染完成')),
    );
    _initialize();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    store?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    DiaryService.add('[App] 生命周期：${state.name}');
    if (state == AppLifecycleState.resumed && Platform.isAndroid) {
      unawaited(_refreshDevice());
    }
    if (!Platform.isIOS) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(
        NativeRepository(
          background: true,
        ).controlDownloads('pauseAll').catchError((Object _) {}),
      );
    }
  }

  Future<void> _refreshDevice() async {
    final detected = await AppDevice.detect(fallback: device);
    if (!mounted ||
        (device.television == detected.television &&
            device.version == detected.version)) {
      return;
    }
    setState(() => device = detected);
  }

  Future<void> _checkSourceUpdate() async {
    try {
      await repository.updateSource();
    } catch (_) {}
  }

  Future<void> _initialize() async {
    setState(() => error = null);
    try {
      final preferences = await SharedPreferences.getInstance();
      await _refreshDevice();
      await repository.initialize();
      unawaited(_checkSourceUpdate());
      final support = await getApplicationSupportDirectory();
      final local = await LocalStore.open(
        preferences,
        LocalFiles(Directory(path.join(support.path, 'store'))),
      );
      if (!mounted) return;
      setState(() {
        store = local;
        repository.access = local;
      });
    } catch (failure) {
      if (mounted) setState(() => error = failure);
    }
  }

  @override
  Widget build(BuildContext context) => DuanjuApp(
    repository: repository,
    store: store,
    bootstrapError: error?.toString(),
    onRetry: _initialize,
    television: device.television,
    version: device.version,
  );
}
