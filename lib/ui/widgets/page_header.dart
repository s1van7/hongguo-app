import 'package:flutter/material.dart';

import 'bar_button.dart';

class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.actions = const [],
    this.onBack,
  });
  final String title;
  final List<Widget> actions;

  /// 传入后标题左侧显示返回按钮。
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
    child: SizedBox(
      height: 64,
      child: Row(
        children: [
          if (onBack != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: BarButton(
                icon: Icons.arrow_back_rounded,
                tooltip: '返回',
                onPressed: onBack,
              ),
            ),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          ...actions,
        ],
      ),
    ),
  );
}
