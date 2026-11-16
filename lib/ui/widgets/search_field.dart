import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../native_text_input.dart';
import '../app_scope.dart';
import 'focus_ring.dart';
import 'letter_keyboard.dart';

class SearchField extends StatelessWidget {
  const SearchField({
    super.key,
    required this.hint,
    required this.onSubmitted,
    this.controller,
    this.focusNode,
    this.onChanged,
    this.autofocus = false,
    this.height = 40,
    this.letterKeyboard = false,
    this.matches,
  });
  final String hint;
  final ValueChanged<String> onSubmitted;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final bool autofocus;
  final double height;
  final bool letterKeyboard;
  final TitleMatches? matches;

  InputDecoration _decoration(ColorScheme colors) {
    final radius = BorderRadius.circular(height / 2);
    return InputDecoration(
      hintText: hint,
      isDense: true,
      filled: true,
      fillColor: colors.surfaceContainerHigh,
      contentPadding: EdgeInsets.zero,
      prefixIcon: Icon(
        Icons.search_rounded,
        size: 20,
        color: colors.onSurfaceVariant,
      ),
      border: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: colors.primary, width: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final decoration = _decoration(Theme.of(context).colorScheme);
    final television = AppScope.of(context).television;
    return SizedBox(
      height: height,
      child:
          television &&
              (letterKeyboard ||
                  defaultTargetPlatform == TargetPlatform.android)
          ? _TelevisionSearchField(
              decoration: decoration,
              controller: controller,
              focusNode: focusNode,
              autofocus: autofocus,
              onSubmitted: onSubmitted,
              onChanged: onChanged,
              letters: letterKeyboard,
              matches: matches,
            )
          : TextField(
              controller: controller,
              focusNode: focusNode,
              autofocus: autofocus,
              onChanged: onChanged,
              onSubmitted: onSubmitted,
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 14),
              decoration: decoration,
            ),
    );
  }
}

class _TelevisionSearchField extends StatefulWidget {
  const _TelevisionSearchField({
    required this.decoration,
    required this.controller,
    required this.focusNode,
    required this.autofocus,
    required this.onSubmitted,
    required this.onChanged,
    required this.letters,
    required this.matches,
  });
  final InputDecoration decoration;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final bool autofocus;
  final ValueChanged<String> onSubmitted;
  final ValueChanged<String>? onChanged;
  final bool letters;
  final TitleMatches? matches;

  @override
  State<_TelevisionSearchField> createState() => _TelevisionSearchFieldState();
}

class _TelevisionSearchFieldState extends State<_TelevisionSearchField> {
  final _ownController = TextEditingController();
  final _ownFocus = FocusNode();
  var _editing = false;
  var _typed = false;
  Timer? _watchdog;

  TextEditingController get _controller => widget.controller ?? _ownController;
  FocusNode get _focus => widget.focusNode ?? _ownFocus;

  @override
  void dispose() {
    _watchdog?.cancel();
    if (_editing) NativeTextInput.stop();
    _ownController.dispose();
    _ownFocus.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    if (!widget.letters) {
      await _edit();
      return;
    }
    await _letters();
  }

  Future<void> _letters() async {
    final text = await showLetterKeyboard(
      context,
      text: _controller.text,
      matches: widget.matches,
    );
    if (text == null || !mounted) return;
    _controller.text = text;
    widget.onSubmitted(text);
  }

  Future<void> _edit() async {
    _watchdog?.cancel();
    _typed = false;
    setState(() => _editing = true);
    final hasIme = await NativeTextInput.start(
      _controller.text,
      onChanged: (text) {
        _typed = true;
        if (!mounted) return;
        _controller.text = text;
        widget.onChanged?.call(text);
      },
      onDone: (text, submit) {
        _watchdog?.cancel();
        if (!mounted) return;
        setState(() => _editing = false);
        _controller.text = text;
        if (submit) widget.onSubmitted(text);
      },
    );
    if (!mounted) return;
    if (!hasIme) {
      // 系统里没有任何输入法，直接退回内置键盘，别让搜索卡死
      NativeTextInput.stop();
      setState(() => _editing = false);
      await _letters();
      return;
    }
    _watchdog = Timer(const Duration(milliseconds: 1400), _checkIme);
  }

  /// 输入法迟迟没弹出来（第三方输入法常见）时，给用户一条出路。
  Future<void> _checkIme() async {
    if (!mounted || !_editing || _typed) return;
    if (await NativeTextInput.isActive()) return;
    if (!mounted || !_editing || _typed) return;
    NativeTextInput.stop();
    setState(() => _editing = false);
    final action = await _showImeDialog(problem: true);
    if (action == null || !mounted) return;
    if (action == 'switch') {
      // 系统选择器会盖在应用上面，选完让用户再点一次搜索框即可
      await NativeTextInput.switchIme();
    } else {
      await _letters();
    }
  }

  Future<String?> _showImeDialog({bool problem = false}) async {
    final info = await NativeTextInput.info();
    if (!mounted) return null;
    return showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(problem ? '输入法没有弹出来' : '输入法'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              '当前：${info.displayName}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          TileFocus(
            builder: (focusNode) => ListTile(
              focusNode: focusNode,
              autofocus: true,
              leading: const Icon(Icons.keyboard_rounded),
              title: const Text('切换输入法'),
              subtitle: Text(
                info.thirdParty ? '已安装其它输入法，点这里选一个' : '打开系统输入法选择器',
              ),
              onTap: () => Navigator.pop(context, 'switch'),
            ),
          ),
          TileFocus(
            builder: (focusNode) => ListTile(
              focusNode: focusNode,
              leading: const Icon(Icons.dialpad_rounded),
              title: const Text('用内置字母键盘'),
              subtitle: const Text('遥控器按字母/拼音首字母搜索'),
              onTap: () => Navigator.pop(context, 'letters'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _imeMenu() async {
    final action = await _showImeDialog();
    if (action == null || !mounted) return;
    if (action == 'switch') {
      await NativeTextInput.switchIme();
    } else {
      await _letters();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_controller, _focus]),
    builder: (context, _) => InkWell(
      focusNode: _focus,
      autofocus: widget.autofocus,
      focusColor: Colors.transparent,
      customBorder: const StadiumBorder(),
      onTap: _open,
      onLongPress: _imeMenu,
      child: InputDecorator(
        decoration: widget.decoration.copyWith(
          // 遥控器长按不好按，右上角给一个能聚焦的输入法入口
          suffixIcon: IconButton(
            onPressed: _imeMenu,
            icon: const Icon(Icons.keyboard_rounded, size: 18),
            iconSize: 18,
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          suffixIconConstraints: const BoxConstraints.tightFor(
            width: 40,
            height: 36,
          ),
        ),
        isFocused: _focus.hasFocus,
        isEmpty: _controller.text.isEmpty,
        textAlignVertical: TextAlignVertical.center,
        child: Text.rich(
          TextSpan(
            text: _controller.text,
            children: [
              if (_editing)
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Container(
                    width: 2,
                    height: 16,
                    margin: const EdgeInsets.only(left: 1),
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14),
        ),
      ),
    ),
  );
}
