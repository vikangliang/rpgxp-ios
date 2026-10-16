import 'dart:async';
import 'package:flutter/services.dart';

/// 游戏库条目（M2 由原生插件扫描 Documents/games 填充）
class GameEntry {
  final String id;
  final String name;
  final String engine;
  final String lastPlayed;
  const GameEntry({
    required this.id,
    required this.name,
    this.engine = '',
    this.lastPlayed = '',
  });
  factory GameEntry.fromMap(Map m) => GameEntry(
        id: m['id'] ?? '',
        name: m['name'] ?? '',
        engine: m['engine'] ?? '',
        lastPlayed: m['lastPlayed'] ?? '',
      );
}

/// 与原生 mkxp 插件通信的 MethodChannel 封装。
/// 方法均为 M0 占位实现：原生侧已 stub 返回，M1/M2 再填充真实逻辑。
class Mkxp {
  static const _ch = MethodChannel('com.yourapp.mkxp');

  static Future<List<GameEntry>> listGames() async {
    try {
      final r = await _ch.invokeListMethod('listGames');
      return (r ?? []).map((e) => GameEntry.fromMap(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<bool> importGameZip(String path) async {
    try {
      return await _ch.invokeMethod('importZip', {'path': path}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 启动引擎。gamePath 为游戏目录（含 Game.ini/Data/），相对路径由原生侧
  /// 按沙盒 Documents 解析（如 'games/Essentials'）。
  /// 失败会抛出 PlatformException（code=runFailed/badArgs，message 含返回码含义）。
  static Future<void> launchGame(String gamePath) async {
    await _ch.invokeMethod('launch', {'path': gamePath});
  }

  /// 请求关机（引擎走完清理流程后线程退出）。
  static Future<void> quitGame() async {
    try {
      await _ch.invokeMethod('quit');
    } catch (_) {}
  }

  /// rgssKey: RGSS 键码；down: true=按下 false=抬起
  static Future<void> sendKey(int rgssKey, bool down) async {
    try {
      await _ch.invokeMethod('key', {'k': rgssKey, 'down': down});
    } catch (_) {}
  }

  static Future<void> setOrientation(bool landscape) async {
    try {
      await _ch.invokeMethod('setOrientation', {'landscape': landscape});
    } catch (_) {}
  }

  static Future<void> haptic() async {
    try {
      await _ch.invokeMethod('haptic');
    } catch (_) {}
  }

  static Future<String> readLog() async {
    try {
      return await _ch.invokeMethod('readLog') ?? '';
    } catch (_) {
      return 'readLog 调用失败（原生未实现？）';
    }
  }
}
