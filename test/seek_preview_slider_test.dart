import 'package:duanju_app/ui/player/player_surface.dart';
import 'package:duanju_app/ui/widgets/seek_preview_slider.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _max = 600000.0; // 10 分钟

/// 和播放页一致的进度条主题（主控制条那一套）
const _controlsTheme = SliderThemeData(
  trackHeight: 4,
  thumbShape: RoundSliderThumbShape(enabledThumbRadius: 8),
  overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
  trackShape: RoundedRectSliderTrackShape(),
);

/// 竖屏 / 横屏进度条那一套：padding 为零，轨道铺满整宽
const _fullWidthTheme = SliderThemeData(
  trackHeight: 3,
  padding: EdgeInsets.zero,
  thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
  overlayShape: RoundSliderOverlayShape(overlayRadius: 20),
  trackShape: RoundedRectSliderTrackShape(),
);

Widget _host({
  required void Function(double)? onChanged,
  SliderThemeData theme = _controlsTheme,
  bool showOnDrag = true,
  double width = 320,
  double height = 44,
}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: width,
        height: height,
        child: SliderTheme(
          data: theme,
          child: SeekPreviewSlider(
            showOnDrag: showOnDrag,
            slider: Slider(
              value: 0,
              max: _max,
              semanticFormatterCallback: (value) =>
                  formatClock(Duration(milliseconds: value.round())),
              onChanged: onChanged,
            ),
          ),
        ),
      ),
    ),
  ),
);

String _clock(double value) =>
    formatClock(Duration(milliseconds: value.round()));

Future<TestGesture> _mouseAt(WidgetTester tester, Offset point) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await tester.pump();
  await mouse.moveTo(point);
  await tester.pump();
  return mouse;
}

void main() {
  testWidgets('悬停显示的时间，就是点下去实际会跳到的时间', (tester) async {
    double? tapped;
    await tester.pumpWidget(_host(onChanged: (value) => tapped = value));
    final box = tester.getRect(find.byType(SeekPreviewSlider));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();

    // 太靠左时值仍是 0，Slider 不会回调 onChanged，所以从 6% 开始
    for (final fraction in [.06, .1, .25, .5, .75, .9, .98]) {
      final point = Offset(
        box.left + box.width * fraction,
        box.center.dy,
      );
      await mouse.moveTo(point);
      await tester.pump();
      final shown = tester.widget<Text>(find.byType(Text)).data!;

      tapped = null;
      await tester.tapAt(point);
      await tester.pumpAndSettle();
      expect(tapped, isNotNull, reason: 'fraction=$fraction 没点到');
      expect(
        shown,
        _clock(tapped!),
        reason: 'fraction=$fraction 气泡位置和真实跳转位置不一致',
      );

      await mouse.moveTo(Offset(box.center.dx, box.top - 300));
      await tester.pump();
    }
  });

  testWidgets('悬停到最右侧显示总时长，不会超出可跳转范围', (tester) async {
    await tester.pumpWidget(_host(onChanged: (_) {}));
    final box = tester.getRect(find.byType(SeekPreviewSlider));
    // 贴着右端，超出部分要夹到总时长，不能显示成比总时长还大
    final mouse = await _mouseAt(
      tester,
      Offset(box.right - 2, box.center.dy),
    );

    expect(find.text('10:00'), findsOneWidget);
    await mouse.moveTo(Offset(box.center.dx, box.top - 300));
    await tester.pump();
  });

  testWidgets('鼠标移出后气泡消失', (tester) async {
    await tester.pumpWidget(_host(onChanged: (_) {}));
    final box = tester.getRect(find.byType(SeekPreviewSlider));
    final mouse = await _mouseAt(tester, box.center);
    expect(find.byType(Text), findsOneWidget);

    await mouse.moveTo(Offset(box.center.dx, box.top - 200));
    await tester.pump();
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('拖动时跟着手指走（触屏也能看时间）', (tester) async {
    await tester.pumpWidget(_host(onChanged: (_) {}));
    final box = tester.getRect(find.byType(SeekPreviewSlider));

    final gesture = await tester.startGesture(
      Offset(box.left + box.width * .1, box.center.dy),
    );
    await tester.pump();
    final first = tester.widget<Text>(find.byType(Text)).data;

    await gesture.moveTo(Offset(box.left + box.width * .9, box.center.dy));
    await tester.pump();
    final later = tester.widget<Text>(find.byType(Text)).data;

    expect(first, isNot(later));
    await gesture.up();
    await tester.pump();
    // 手指抬起且没有鼠标悬停，气泡收起来
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('showOnDrag 为 false 时拖动不显示（页面已有大号气泡）', (tester) async {
    await tester.pumpWidget(_host(onChanged: (_) {}, showOnDrag: false));
    final box = tester.getRect(find.byType(SeekPreviewSlider));

    final gesture = await tester.startGesture(box.center);
    await tester.pump();
    await gesture.moveTo(Offset(box.left + box.width * .8, box.center.dy));
    await tester.pump();

    expect(find.byType(Text), findsNothing);
    await gesture.up();
    await tester.pump();
  });

  testWidgets('padding 为零的轨道按整宽换算（竖屏 / 横屏进度条）', (tester) async {
    double? tapped;
    await tester.pumpWidget(
      _host(theme: _fullWidthTheme, onChanged: (value) => tapped = value),
    );
    final box = tester.getRect(find.byType(SeekPreviewSlider));
    final point = Offset(box.left + box.width * .5, box.center.dy);

    await _mouseAt(tester, point);
    expect(find.text('05:00'), findsOneWidget);

    await tester.tapAt(point);
    await tester.pumpAndSettle();
    expect(_clock(tapped!), '05:00');
  });

  testWidgets('拖不动的进度条不弹提示', (tester) async {
    await tester.pumpWidget(_host(onChanged: null));
    final box = tester.getRect(find.byType(SeekPreviewSlider));
    await _mouseAt(tester, box.center);

    expect(find.byType(Text), findsNothing);
  });

  testWidgets('窄屏也不会溢出', (tester) async {
    await tester.pumpWidget(_host(onChanged: (_) {}, width: 60));
    final box = tester.getRect(find.byType(SeekPreviewSlider));
    await _mouseAt(tester, Offset(box.center.dx, box.center.dy));

    expect(tester.takeException(), isNull);
  });
}
