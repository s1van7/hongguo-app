import 'package:flutter/services.dart';

/// 系统输入法的当前状态，用来在界面上显示、并引导用户切换。
class ImeInfo {
  const ImeInfo({
    this.label = '',
    this.id = '',
    this.enabled = 0,
    this.available = 0,
    this.thirdParty = false,
  });

  final String label;
  final String id;

  /// 已启用（可被选择）的输入法数量。
  final int enabled;

  /// 已安装的输入法数量。
  final int available;

  /// 除当前输入法外，是否还装了第三方输入法（可提示用户切换）。
  final bool thirdParty;

  String get displayName => label.isEmpty ? '系统输入法' : label;

  factory ImeInfo.fromMap(Object? value) {
    if (value is! Map) return const ImeInfo();
    return ImeInfo(
      label: value['label'] is String ? value['label'] as String : '',
      id: value['id'] is String ? value['id'] as String : '',
      enabled: value['enabled'] is int ? value['enabled'] as int : 0,
      available: value['available'] is int ? value['available'] as int : 0,
      thirdParty: value['thirdParty'] == true,
    );
  }
}

class NativeTextInput {
  static const _channel = MethodChannel('duanju/text_input');

  /// 返回系统里是否至少有一个可用输入法；为 false 时调用方应退回内置键盘。
  static Future<bool> start(
    String text, {
    bool search = true,
    bool password = false,
    bool url = false,
    int? maxLength,
    required void Function(String text) onChanged,
    required void Function(String text, bool submit) onDone,
  }) async {
    _channel.setMethodCallHandler((call) async {
      final arguments = call.arguments;
      switch (call.method) {
        case 'changed' when arguments is String:
          onChanged(arguments);
        case 'done' when arguments is Map:
          _channel.setMethodCallHandler(null);
          final text = arguments['text'];
          onDone(text is String ? text : '', arguments['submit'] == true);
      }
    });
    try {
      final hasIme = await _channel.invokeMethod<bool>('start', {
        'text': text,
        'search': search,
        'password': password,
        'url': url,
        'maxLength': maxLength,
      });
      return hasIme ?? true;
    } catch (_) {
      _channel.setMethodCallHandler(null);
      onDone(text, false);
      return true;
    }
  }

  static void stop() {
    _channel.setMethodCallHandler(null);
    _channel.invokeMethod<void>('stop').catchError((_) {});
  }

  /// 输入法面板当前是否真的弹出来了。
  static Future<bool> isActive() async {
    try {
      return await _channel.invokeMethod<bool>('active') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 弹出系统输入法选择器（装了第三方输入法但没选中时，用它切换）。
  static Future<void> switchIme() async {
    try {
      await _channel.invokeMethod<void>('switch');
    } catch (_) {}
  }

  static Future<ImeInfo> info() async {
    try {
      return ImeInfo.fromMap(await _channel.invokeMethod<Object?>('ime'));
    } catch (_) {
      return const ImeInfo();
    }
  }
}
