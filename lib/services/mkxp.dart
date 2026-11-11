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

  /// [active] = false 表示退出游戏：原生侧收敛到同一入口复位持久方向掩码。
  static Future<void> setOrientation(bool landscape, {bool active = true}) async {
    try {
      await _ch.invokeMethod('setOrientation',
          {'landscape': landscape, 'active': active});
    } catch (_) {}
  }

  /// 原生浮层「退出游戏」的反向通知：引擎已由原生关闭，Flutter 侧需要
  /// 复位 preferred orientations / 常亮，否则残留横屏偏好会在系统方向锁
  /// 关闭时把 App 转回横屏。
  static void Function()? _onGameExited;
  static bool _exitHandlerInstalled = false;

  static void setGameExitedHandler(void Function()? handler) {
    _onGameExited = handler;
    if (_exitHandlerInstalled) return;
    _exitHandlerInstalled = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'gameExited') {
        _onGameExited?.call();
        return null;
      }
      throw MissingPluginException('未处理的方法: ${call.method}');
    });
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

  /// 实时平均帧率（FPS 角标/流畅度诊断用；原生侧已直接显示，此通道供日志/调试）。
  static Future<double> getFps() async {
    try {
      return await _ch.invokeMethod('getFps') ?? 0.0;
    } catch (_) {
      return 0.0;
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

  // MARK: - 虚拟按键布局（原生 UserDefaults 为唯一数据源，横竖各一套）

  /// items = 该方向当前生效布局，defaults = 该方向原始布局（重置起点）。
  static Future<ControlLayout> getControlLayout({required bool landscape}) async {
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>(
          'getControlLayout', {'landscape': landscape});
      if (r == null) return ControlLayout.fallback();
      return ControlLayout.fromMap(r);
    } catch (_) {
      return ControlLayout.fallback();
    }
  }

  static Future<void> setControlLayout(
      List<ControlItem> items, {required bool landscape}) async {
    await _ch.invokeMethod('setControlLayout', {
      'items': items.map((e) => e.toMap()).toList(),
      'landscape': landscape,
    });
  }

  static Future<void> resetControlLayout({required bool landscape}) async {
    await _ch.invokeMethod('resetControlLayout', {'landscape': landscape});
  }
}

/// 单个虚拟按键的归一化布局：cx/cy 为中心点，w/h 为尺寸，相对**所在方向**的
/// 画布 0..1。横屏与竖屏各存一套，分母不同，不能混用。
class ControlItem {
  final String id;
  final String label;
  double cx, cy, w, h;

  ControlItem({
    required this.id,
    required this.label,
    required this.cx,
    required this.cy,
    required this.w,
    required this.h,
  });

  factory ControlItem.fromMap(Map m) => ControlItem(
        id: m['id'] as String? ?? '',
        label: m['label'] as String? ?? '',
        cx: (m['cx'] as num?)?.toDouble() ?? 0.5,
        cy: (m['cy'] as num?)?.toDouble() ?? 0.5,
        w: (m['w'] as num?)?.toDouble() ?? 0.1,
        h: (m['h'] as num?)?.toDouble() ?? 0.1,
      );

  Map<String, dynamic> toMap() =>
      {'id': id, 'label': label, 'cx': cx, 'cy': cy, 'w': w, 'h': h};

  ControlItem copy() =>
      ControlItem(id: id, label: label, cx: cx, cy: cy, w: w, h: h);
}

class ControlLayout {
  final List<ControlItem> items;
  final List<ControlItem> defaults;
  final bool customized;
  final double canvasW;
  final double canvasH;

  const ControlLayout({
    required this.items,
    required this.defaults,
    required this.customized,
    this.canvasW = 896,
    this.canvasH = 414,
  });

  double get aspect => canvasH > 0 ? canvasW / canvasH : 896 / 414;

  factory ControlLayout.fromMap(Map m) {
    List<ControlItem> parse(Object? raw) => (raw as List? ?? [])
        .map((e) => ControlItem.fromMap(e as Map))
        .toList();
    final defs = parse(m['defaults']);
    final its = parse(m['items']);
    return ControlLayout(
      items: its.isEmpty ? defs.map((e) => e.copy()).toList() : its,
      defaults: defs,
      customized: m['customized'] as bool? ?? false,
      canvasW: (m['canvasW'] as num?)?.toDouble() ?? 896,
      canvasH: (m['canvasH'] as num?)?.toDouble() ?? 414,
    );
  }

  /// 原生侧不可用时（如 Android/旧版本）不至于白屏，给一个可编辑的空壳。
  static ControlLayout fallback() => ControlLayout(
        items: [],
        defaults: [],
        customized: false,
      );
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
