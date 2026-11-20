import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'contained_slider.dart';

/// 进度条上方的时间预览气泡。
///
/// 鼠标移到进度条上时，指针落在哪一段就显示那一段对应的时间，
/// 不用先拖一下才知道会跳到哪里。触屏设备没有悬停，拖动时同样显示
/// （页面自己已经有居中大号时间气泡的，把 [showOnDrag] 传 false 即可）。
class SeekPreviewSlider extends StatefulWidget {
  const SeekPreviewSlider({
    super.key,
    required this.slider,
    this.describe,
    this.showOnDrag = true,
  });

  final Slider slider;

  /// 把滑块数值（毫秒）转成显示文本。不传就用 [Slider.semanticFormatterCallback]。
  final String Function(double value)? describe;

  /// 拖动时是否也显示。
  final bool showOnDrag;

  @override
  State<SeekPreviewSlider> createState() => _SeekPreviewSliderState();
}

class _SeekPreviewSliderState extends State<SeekPreviewSlider> {
  double? _fraction;
  bool _dragging = false;
  bool _hovering = false;

  String _text(double value) {
    final format = widget.describe ?? widget.slider.semanticFormatterCallback;
    if (format != null) return format(value);
    final max = widget.slider.max;
    return max > 0 ? '${(value / max * 100).round()}%' : '0%';
  }

  void _pointAt(_TrackGeometry geometry, double dx, {bool drag = false}) {
    final fraction = geometry.fractionAt(dx);
    if (drag && !_dragging) _dragging = true;
    if (!drag && !_hovering) _hovering = true;
    if (_fraction == fraction) return;
    setState(() => _fraction = fraction);
  }

  void _release() {
    if (!_dragging) return;
    _dragging = false;
    if (!_hovering) _hide();
  }

  void _hide() {
    if (_dragging || _fraction == null) return;
    setState(() => _fraction = null);
  }

  Widget _bubble(String text) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .78),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          height: 1.1,
          fontWeight: FontWeight.w600,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = SliderTheme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 拖不动的进度条（还没加载出时长、不可拖动）不弹提示，避免一直显示 00:00
        if (!constraints.hasBoundedWidth || widget.slider.onChanged == null) {
          return ContainedSlider(slider: widget.slider);
        }
        final geometry = _TrackGeometry(
          theme: theme,
          slider: widget.slider,
          width: constraints.maxWidth,
        );
        final height = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : 28.0;
        final fraction = _fraction;
        return MouseRegion(
          onHover: (event) => _pointAt(geometry, event.localPosition.dx),
          onExit: (_) {
            _hovering = false;
            _hide();
          },
          child: Listener(
            onPointerDown: widget.showOnDrag
                ? (event) => _pointAt(
                    geometry,
                    event.localPosition.dx,
                    drag: true,
                  )
                : null,
            onPointerMove: widget.showOnDrag
                ? (event) {
                    if (_dragging) {
                      _pointAt(geometry, event.localPosition.dx, drag: true);
                    }
                  }
                : null,
            onPointerUp: (_) => _release(),
            onPointerCancel: (_) => _release(),
            child: Stack(
              fit: StackFit.passthrough,
              clipBehavior: Clip.none,
              children: [
                ContainedSlider(slider: widget.slider),
                if (fraction != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    // 贴在轨道正上方，而不是贴住整个控件盒子
                    bottom: height / 2 + 12,
                    child: IgnorePointer(
                      child: Align(
                        // 靠边时自动收进可视区，不会露一半到屏幕外
                        alignment: Alignment(fraction * 2 - 1, 0),
                        child: _bubble(
                          _text(geometry.valueAt(fraction)),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 轨道在控件里的实际范围。
///
/// Material 的 [Slider] 会把轨道左右各让出「缩略图与光晕里更宽的那个」，
/// 设了 `padding` 则按 padding 来，这里跟着同一套规则算，
/// 保证气泡位置和真按下去跳到的位置一致。
class _TrackGeometry {
  _TrackGeometry({
    required SliderThemeData theme,
    required Slider slider,
    required double width,
  }) : min = slider.min,
       max = slider.max {
    final padding = theme.padding?.resolve(TextDirection.ltr);
    if (padding != null) {
      // 设了 padding 时 Slider 会把自己整个缩进一层，轨道就等于缩进后的盒子
      left = padding.left;
      span = math.max(width - padding.horizontal, 1.0);
      return;
    }
    // 没设 padding 时，轨道左右各让出「缩略图与光晕里更宽的那个」。
    // 主题里没写形状就按 Material 默认的来（缩略图半径 10、光晕半径 24）。
    final thumb =
        (theme.thumbShape ?? const RoundSliderThumbShape())
            .getPreferredSize(true, false)
            .width;
    final overlay =
        (theme.overlayShape ?? const RoundSliderOverlayShape())
            .getPreferredSize(true, false)
            .width;
    final pad = math.max(thumb, overlay);
    left = pad / 2;
    span = math.max(width - pad, 1.0);
  }

  final double min;
  final double max;
  late final double left;
  late final double span;

  double fractionAt(double dx) => ((dx - left) / span).clamp(0.0, 1.0);

  double valueAt(double fraction) => min + (max - min) * fraction;
}
