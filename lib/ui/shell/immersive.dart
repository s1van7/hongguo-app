import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../app_scope.dart';
import 'window_caption.dart';

/// 手机端底部导航栏本体高度（不含系统手势条）。
const double kPhoneNavHeight = 68;

/// 桌面/平板外壳把侧栏浮在画面之上时，左侧要给它留出的宽度。
double railInsetOf(BuildContext context) {
  final form = AppScope.formFactorOf(context);
  return form == FormFactor.window || form == FormFactor.pad ? 74 : 0;
}

/// 桌面端窗口按钮浮在画面顶部，页面顶部内容让开这一条。
double get captionInset => appCaptionEnabled ? kAppCaptionHeight : 0;

/// 这一页是否还压在外壳里：播放页有可能被推到根导航上，把侧栏和窗口按钮一起盖住。
bool shellVisibleFrom(BuildContext context) =>
    Navigator.of(context) != Navigator.of(context, rootNavigator: true);

/// 当前标签页是不是前台（切到别的标签时，压在这个标签上的页面要暂时收掉沉浸声明）。
class ShellForeground extends InheritedWidget {
  const ShellForeground({
    super.key,
    required this.foreground,
    required super.child,
  });
  final bool foreground;

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ShellForeground>()
          ?.foreground ??
      true;

  @override
  bool updateShouldNotify(ShellForeground oldWidget) =>
      foreground != oldWidget.foreground;
}

/// 是否有页面声明自己是沉浸式的（详情页、播放页）。
///
/// 为真时外壳把侧栏、窗口按钮条改成浮层，页面画面铺满整个窗口，
/// 和首页信息流一个观感。
final ValueNotifier<bool> pageImmersive = ValueNotifier<bool>(false);

int _declared = 0;

void _declare(bool immersive) {
  _declared += immersive ? 1 : -1;
  if (_declared < 0) _declared = 0;
  final value = _declared > 0;
  if (value == pageImmersive.value) return;
  // 路由的 initState/dispose 都发生在帧内，这时候改状态会撞上外壳的 build，
  // 推到帧后再通知，慢一帧但不会报错。
  if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
    pageImmersive.value = value;
  } else {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      pageImmersive.value = _declared > 0;
    });
  }
}

/// 声明这一页是沉浸式的：画面铺满窗口，侧栏与窗口按钮浮在上面。
class ImmersivePage extends StatefulWidget {
  const ImmersivePage({super.key, required this.child});

  final Widget child;

  @override
  State<ImmersivePage> createState() => _ImmersivePageState();
}

class _ImmersivePageState extends State<ImmersivePage> {
  bool _declared = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 切到别的标签页时先收回声明，免得那个标签也跟着铺满
    final active = ShellForeground.of(context);
    if (active == _declared) return;
    _declared = active;
    _declare(active);
  }

  @override
  void dispose() {
    if (_declared) _declare(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
