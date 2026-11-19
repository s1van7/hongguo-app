import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'diary_service.dart';

/// 启动与运行期异常的落盘记录。
///
/// 应用「打开就闪退」时用户什么也看不到，只能靠这份文件定位：
/// Windows 下在 `%APPDATA%\<应用>\logs\crash.log`（和播放器日志同一个目录）。
class CrashLog {
  static Future<File?>? _pending;
  static File? _file;

  static String get _stamp {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }

  static Future<File?> _target() => _pending ??= _open();

  static Future<File?> _open() async {
    try {
      final support = await getApplicationSupportDirectory();
      final directory = Directory(path.join(support.path, 'logs'));
      if (!await directory.exists()) await directory.create(recursive: true);
      final file = File(path.join(directory.path, 'crash.log'));
      // 超过 256KB 滚一份旧的，避免无限增长
      if (await file.exists() && await file.length() > 256 * 1024) {
        final old = File('${file.path}.1');
        if (await old.exists()) await old.delete();
        await file.rename(old.path);
      }
      _file = file;
      return file;
    } catch (_) {
      _pending = null;
      return null;
    }
  }

  /// 日志文件路径，界面上用来告诉用户去哪儿找。
  static Future<String?> get location async => (await _target())?.path;

  static Future<void> write(String line) async {
    final file = _file ?? await _target();
    if (file == null) return;
    try {
      await file.writeAsString(
        '$_stamp $line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  /// 记录一条异常：进内存日志（设置 › 日志 里能看），同时落盘。
  static void record(String kind, Object error, [StackTrace? stack]) {
    final text = stack == null ? '$kind：$error' : '$kind：$error\n$stack';
    try {
      DiaryService.add(text);
    } catch (_) {}
    unawaited(write(text));
  }
}
