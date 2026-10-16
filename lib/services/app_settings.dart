import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 应用设置（M2 设置页）。iOS 风格开关即时生效并持久化。
/// 存储用 Documents/.settings.json（path_provider 已有依赖，不引入
/// shared_preferences——少一个原生插件，CI 链路少一个变量）。
class AppSettings {
  static const _kKeepAwake = 'keepAwake';
  static const _kLockLandscape = 'lockLandscape';
  static const _kVibration = 'vibration';
  static const _kLastPlayedPrefix = 'lastPlayed:';

  final bool keepAwake;      // 保持屏幕常亮 → 原生 idleTimerDisabled
  final bool lockLandscape;  // 固定横屏游戏 → 进游戏锁横屏
  final bool vibration;      // 控制器振动 → 按键触感

  const AppSettings({
    this.keepAwake = true,
    this.lockLandscape = true,
    this.vibration = true,
  });

  static Future<File> _file() async {
    final docs = await getApplicationDocumentsDirectory();
    return File('${docs.path}/.settings.json');
  }

  static Future<Map<String, dynamic>> _read() async {
    try {
      final f = await _file();
      if (!await f.exists()) return {};
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  static Future<void> _write(Map<String, dynamic> map) async {
    final f = await _file();
    await f.writeAsString(jsonEncode(map));
  }

  static Future<AppSettings> load() async {
    final m = await _read();
    return AppSettings(
      keepAwake: m[_kKeepAwake] as bool? ?? true,
      lockLandscape: m[_kLockLandscape] as bool? ?? true,
      vibration: m[_kVibration] as bool? ?? true,
    );
  }

  static Future<void> save({
    required bool keepAwake,
    required bool lockLandscape,
    required bool vibration,
  }) async {
    final m = await _read();
    m[_kKeepAwake] = keepAwake;
    m[_kLockLandscape] = lockLandscape;
    m[_kVibration] = vibration;
    await _write(m);
  }

  /// 记录最近游玩时间（游戏库"最近游玩"列）。
  static Future<void> touchLastPlayed(String gameName) async {
    final m = await _read();
    m['$_kLastPlayedPrefix$gameName'] = DateTime.now().toIso8601String();
    await _write(m);
  }

  static Future<DateTime?> lastPlayed(String gameName) async {
    final m = await _read();
    final s = m['$_kLastPlayedPrefix$gameName'] as String?;
    return s == null ? null : DateTime.tryParse(s);
  }

  static const _kPlaytimePrefix = 'playtime:';

  /// 累计游玩时长（秒）。GameRunPage 退出时把本次时长累进去。
  static Future<void> addPlaytime(String gameName, int seconds) async {
    if (seconds <= 0) return;
    final m = await _read();
    final prev = m['$_kPlaytimePrefix$gameName'] as int? ?? 0;
    m['$_kPlaytimePrefix$gameName'] = prev + seconds;
    await _write(m);
  }

  static Future<int> playtime(String gameName) async {
    final m = await _read();
    return m['$_kPlaytimePrefix$gameName'] as int? ?? 0;
  }

  /// 秒 → 人类可读时长（"3.2 小时" / "42 分钟"）。
  static String formatPlaytime(int seconds) {
    if (seconds < 60) return '不足 1 分钟';
    if (seconds < 3600) return '${seconds ~/ 60} 分钟';
    return '${(seconds / 3600).toStringAsFixed(1)} 小时';
  }

  static const _kPlayCountPrefix = 'playCount:';

  /// 游玩次数（每次真正调 launchGame 计一次）。
  static Future<void> addPlayCount(String gameName) async {
    final m = await _read();
    final prev = m['$_kPlayCountPrefix$gameName'] as int? ?? 0;
    m['$_kPlayCountPrefix$gameName'] = prev + 1;
    await _write(m);
  }

  static Future<int> playCount(String gameName) async {
    final m = await _read();
    return m['$_kPlayCountPrefix$gameName'] as int? ?? 0;
  }

  /// 重命名游戏时迁移以名字为键的统计项。
  static Future<void> migrateName(String oldName, String newName) async {
    final m = await _read();
    for (final prefix in [
      _kLastPlayedPrefix,
      _kPlaytimePrefix,
      _kPlayCountPrefix
    ]) {
      final k = '$prefix$oldName';
      if (m.containsKey(k)) m['$prefix$newName'] = m.remove(k);
    }
    await _write(m);
  }
}
