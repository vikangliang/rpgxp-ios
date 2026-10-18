import 'dart:async';
import 'dart:typed_data';
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

  /// 引擎是否已上屏第一帧（原生侧软呈现首次成功出图后为 true）。
  static Future<bool> engineReady() async {
    try {
      return await _ch.invokeMethod('engineReady') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 轮询等待引擎出首帧（加载提示用）。timeout 后放弃返回 false。
  static Future<bool> waitForEngineReady(
      {Duration interval = const Duration(milliseconds: 300),
      Duration timeout = const Duration(seconds: 60)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await engineReady()) return true;
      await Future.delayed(interval);
    }
    return false;
  }

  /// rgssKey: RGSS 键码；down: true=按下 false=抬起
  static Future<void> sendKey(int rgssKey, bool down) async {
    try {
      await _ch.invokeMethod('key', {'k': rgssKey, 'down': down});
    } catch (_) {}
  }

  /// 展示 / 隐藏 / 切换原生触摸浮层（M2 阶段二：SDL 之上的 UIWindow 控件）
  static Future<void> showControls() async {
    try { await _ch.invokeMethod('showControls'); } catch (_) {}
  }

  static Future<void> hideControls() async {
    try { await _ch.invokeMethod('hideControls'); } catch (_) {}
  }

  static Future<void> toggleControls() async {
    try { await _ch.invokeMethod('toggleControls'); } catch (_) {}
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

  /// 保持屏幕常亮（设置页开关；进游戏开、退出关）。
  static Future<void> setKeepAwake(bool on) async {
    try {
      await _ch.invokeMethod('setKeepAwake', {'on': on});
    } catch (_) {}
  }

  /// 清空运行日志（mkxp.log）。
  static Future<void> clearLog() async {
    try {
      await _ch.invokeMethod('clearLog');
    } catch (_) {}
  }

  static Future<String> readLog() async {
    try {
      return await _ch.invokeMethod('readLog') ?? '';
    } catch (_) {
      return 'readLog 调用失败（原生未实现？）';
    }
  }

  /// 场景快照列表（引擎落盘的 Documents/scene_dump_*.png，用于无 Mac 调试）。
  static Future<List<SceneDump>> listSceneDumps() async {
    try {
      final r = await _ch.invokeListMethod('listSceneDumps');
      return (r ?? []).map((e) => SceneDump.fromMap(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  /// 读取一张场景快照的 PNG 字节。
  static Future<Uint8List?> readSceneDump(String name) async {
    try {
      final r = await _ch.invokeMethod('readSceneDump', {'name': name});
      if (r is Uint8List) return r;
      if (r is TypedData) return r.buffer.asUint8List();
      return null;
    } catch (_) {
      return null;
    }
  }
}

/// 场景快照条目。
class SceneDump {
  final String name;
  final int mtime; // epoch 秒
  final int size;
  const SceneDump({required this.name, this.mtime = 0, this.size = 0});
  factory SceneDump.fromMap(Map m) => SceneDump(
        name: m['name'] ?? '',
        mtime: m['mtime'] ?? 0,
        size: m['size'] ?? 0,
      );
}
