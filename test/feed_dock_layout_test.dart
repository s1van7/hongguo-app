import 'package:duanju_app/ui/home/home_feed_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 底部信息区的排版约定：简介铺满整行，功能栏按内容宽度贴在右边，两者不相交。
Future<void> _pumpDock(
  WidgetTester tester, {
  required Size size,
  double railWidth = 50,
  bool desktop = false,
  double railHeight = 300,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                // 和首页一致：桌面端左侧让开浮动侧栏
                padding: EdgeInsets.fromLTRB(12 + (desktop ? 74 : 0), 0, 12, 6),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Container(
                          key: const ValueKey('caption'),
                          height: 72,
                          color: Colors.blue.withValues(alpha: .35),
                          alignment: Alignment.bottomLeft,
                          child: const Text(
                            '简介',
                            style: TextStyle(color: Colors.white, fontSize: 13),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FeedDockRail(
                        railMax: size.height,
                        child: Container(
                          key: const ValueKey('rail'),
                          width: railWidth,
                          height: railHeight,
                          color: Colors.red.withValues(alpha: .35),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('手机端：简介铺满，功能栏贴右且不压简介', (tester) async {
    const size = Size(390, 844);
    await _pumpDock(tester, size: size);
    final caption = tester.getRect(find.byKey(const ValueKey('caption')));
    final rail = tester.getRect(find.byKey(const ValueKey('rail')));

    expect(rail.right, moreOrLessEquals(size.width - 12), reason: '功能栏要贴到右边距');
    expect(caption.right, moreOrLessEquals(rail.left - 8), reason: '简介铺到功能栏左边');
    expect(caption.left, moreOrLessEquals(12));
    expect(caption.width, greaterThan(size.width * .7), reason: '简介应该占满大半行');
    expect(caption.overlaps(rail), isFalse);
  });

  testWidgets('桌面端：简介一直铺到功能栏左边，不再卡在中间', (tester) async {
    const size = Size(1090, 700);
    await _pumpDock(tester, size: size, desktop: true);
    final caption = tester.getRect(find.byKey(const ValueKey('caption')));
    final rail = tester.getRect(find.byKey(const ValueKey('rail')));

    expect(caption.left, moreOrLessEquals(12 + 74), reason: '左侧让开浮动侧栏');
    expect(rail.right, moreOrLessEquals(size.width - 12));
    expect(caption.right, moreOrLessEquals(rail.left - 8));
    // 之前简介被卡在 720，宽屏下右边空一大块
    expect(caption.width, greaterThan(720));
    expect(caption.overlaps(rail), isFalse);
  });

  testWidgets('功能栏变宽时简介自动让位，不会被压住', (tester) async {
    const size = Size(390, 844);
    await _pumpDock(tester, size: size, railWidth: 88);
    final caption = tester.getRect(find.byKey(const ValueKey('caption')));
    final rail = tester.getRect(find.byKey(const ValueKey('rail')));

    expect(caption.overlaps(rail), isFalse);
    expect(caption.right, moreOrLessEquals(rail.left - 8));
    expect(rail.right, moreOrLessEquals(size.width - 12));
  });

  testWidgets('窄屏（320）也放得下，简介还剩够用的宽度', (tester) async {
    await _pumpDock(tester, size: const Size(320, 640));
    final caption = tester.getRect(find.byKey(const ValueKey('caption')));
    final rail = tester.getRect(find.byKey(const ValueKey('rail')));

    expect(caption.width, greaterThan(200));
    expect(caption.overlaps(rail), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('功能栏比可用高度还高时整体缩小，不溢出', (tester) async {
    await _pumpDock(tester, size: const Size(390, 200));
    expect(tester.takeException(), isNull);
    final rail = tester.getRect(find.byKey(const ValueKey('rail')));
    expect(rail.height, lessThanOrEqualTo(200));
  });
}
