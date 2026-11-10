import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/mkxp.dart';

/// 虚拟按键布局编辑器。
/// 横屏/竖屏各一套独立布局，切换目标方向时把设备方向一起转过去，画布按该方向的
/// 真实屏幕比例绘制 → 编辑竖屏时看到的就是竖屏游玩时的实际排布。
/// 两套坐标都归一化（0..1），但各自相对本方向画布，不会因宽高比翻转而拉伸变形。
/// 某方向没编辑过就不落盘，浮层自动走原硬编码布局；「重置」删除该方向的自定义项。
class ControlLayoutPage extends StatefulWidget {
  const ControlLayoutPage({super.key});

  @override
  State<ControlLayoutPage> createState() => _ControlLayoutPageState();
}

class _ControlLayoutPageState extends State<ControlLayoutPage> {
  static const _primary = Color(0xFF4CC2FF);

  bool _landscape = true;   // 当前正在编辑的方向
  double _canvasRatio = 896 / 414;
  double _canvasW = 896, _canvasH = 414;
  List<ControlItem> _items = [];
  List<ControlItem> _defaults = [];
  bool _loading = true;
  bool _dirty = false;
  bool _customized = false;
  String? _error;
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _orientFor(_landscape);
    _load();
  }

  @override
  void dispose() {
    Mkxp.setOrientation(false);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  /// 与 game_run.dart 一致：先松开 Flutter 的全局竖屏锁，再由原生强制切到目标方向
  /// （iOS 上只改 preferred orientations 时，设备物理竖屏不会真的旋转）。
  Future<void> _orientFor(bool landscape) async {
    await SystemChrome.setPreferredOrientations(landscape
        ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
        : [DeviceOrientation.portraitUp]);
    await Mkxp.setOrientation(landscape);
  }

  Future<void> _load() async {
    final l = await Mkxp.getControlLayout(landscape: _landscape);
    if (!mounted) return;
    setState(() {
      _items = l.items.map((e) => e.copy()).toList();
      _defaults = l.defaults.map((e) => e.copy()).toList();
      _customized = l.customized;
      _canvasRatio = l.aspect;
      _canvasW = l.canvasW;
      _canvasH = l.canvasH;
      _loading = false;
      _selectedId = null;
      _error = _items.isEmpty ? '无法读取原生按键布局（仅 iOS 支持）' : null;
    });
  }

  /// 切换编辑方向：有未保存改动时先确认，避免两套配置混着丢。
  Future<void> _switchTarget(bool landscape) async {
    if (landscape == _landscape) return;
    if (_dirty) {
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF16161C),
          title: const Text('有未保存的改动', style: TextStyle(color: Colors.white)),
          content: const Text('切换方向会重新载入另一套布局，当前改动需要先处理。',
              style: TextStyle(color: Colors.white70)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'),
                child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(ctx, 'discard'),
                child: const Text('丢弃', style: TextStyle(color: Colors.orange))),
            TextButton(onPressed: () => Navigator.pop(ctx, 'save'),
                child: const Text('保存并切换', style: TextStyle(color: _primary))),
          ],
        ),
      );
      if (!mounted || choice == null || choice == 'cancel') return;
      if (choice == 'save') {
        try {
          await Mkxp.setControlLayout(_items, landscape: _landscape);
        } catch (e) {
          _toast('保存失败：$e');
          return;
        }
        if (!mounted) return;
      }
    }
    setState(() {
      _landscape = landscape;
      _dirty = false;
      _loading = true;
    });
    await _orientFor(landscape);
    await _load();
  }

  ControlItem? get _selected {
    if (_selectedId == null) return null;
    for (final it in _items) {
      if (it.id == _selectedId) return it;
    }
    return null;
  }

  ControlItem _defaultOf(ControlItem it) {
    for (final d in _defaults) {
      if (d.id == it.id) return d;
    }
    return it;
  }

  double _scaleOf(ControlItem it) {
    final d = _defaultOf(it);
    return d.w > 0 ? it.w / d.w : 1.0;
  }

  double _clampCenter(double v, double size) {
    if (size >= 1) return 0.5;
    return v.clamp(size / 2, 1 - size / 2).toDouble();
  }

  void _setScale(ControlItem it, double scale) {
    final d = _defaultOf(it);
    setState(() {
      it.w = d.w * scale;
      it.h = d.h * scale;
      it.cx = _clampCenter(it.cx, it.w);
      it.cy = _clampCenter(it.cy, it.h);
      _dirty = true;
    });
  }

  void _nudge(ControlItem it, double dx, double dy) =>
      setState(() {
        it.cx = _clampCenter(it.cx + dx, it.w);
        it.cy = _clampCenter(it.cy + dy, it.h);
        _dirty = true;
      });

  Future<void> _back() async {
    // 先把方向锁回竖屏再出栈，避免设置页短暂保持横屏
    await Mkxp.setOrientation(false);
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    if (mounted) Navigator.pop(context);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(msg), behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2)));
  }

  String get _targetName => _landscape ? '横屏' : '竖屏';

  Future<void> _save() async {
    try {
      await Mkxp.setControlLayout(_items, landscape: _landscape);
      if (!mounted) return;
      setState(() {
        _dirty = false;
        _customized = true;
      });
      _toast('已保存$_targetName布局，进入游戏即生效');
    } catch (e) {
      _toast('保存失败：$e');
    }
  }

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF16161C),
        title: Text('重置$_targetName布局', style: const TextStyle(color: Colors.white)),
        content: Text('$_targetName下所有按键的位置和大小将恢复到初始布局；'
            '另一方向的布局不受影响。',
            style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('重置', style: TextStyle(color: _primary))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Mkxp.resetControlLayout(landscape: _landscape);
      if (!mounted) return;
      setState(() {
        _items = _defaults.map((e) => e.copy()).toList();
        _selectedId = null;
        _dirty = false;
        _customized = false;
      });
      _toast('已恢复$_targetName初始布局');
    } catch (e) {
      _toast('重置失败：$e');
    }
  }

  static const _shortLabels = {
    'dpad': '方向', 'act13': 'C', 'act12': '✕', 'act11': 'Z',
    'act16': '☰', 'shL': 'L', 'shR': 'R', 'menu': '⋯',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0F),
      body: SafeArea(
        // 竖屏只有约 390pt 宽，横屏那排工具会溢出；按实际宽度收起次要元素。
        child: LayoutBuilder(builder: (context, c) {
          final narrow = c.maxWidth < 620;
          return Column(children: [
            _toolbar(narrow),
            Expanded(child: _canvasArea()),
            _bottomBar(narrow),
          ]);
        }),
      ),
    );
  }

  Widget _toolbar(bool narrow) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(children: [
          IconButton(
              onPressed: _back,
              icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white70, size: 18)),
          if (!narrow) const Text('虚拟按键布局',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          _orientationSwitch(),
          const SizedBox(width: 8),
          _badge(),
          const Spacer(),
          if (!narrow) ...[
            const Text('拖动移动 · 点选后调大小',
                style: TextStyle(color: Colors.white38, fontSize: 12)),
            const SizedBox(width: 12),
          ],
          narrow
              ? IconButton(
                  onPressed: (_customized || _dirty) ? _reset : null,
                  tooltip: '重置',
                  icon: const Icon(Icons.restart_alt, size: 18))
              : TextButton.icon(
                  onPressed: (_customized || _dirty) ? _reset : null,
                  icon: const Icon(Icons.restart_alt, size: 16),
                  label: const Text('重置')),
          const SizedBox(width: 4),
          narrow
              ? FilledButton(
                  onPressed: (_loading || _error != null) ? null : _save,
                  style: FilledButton.styleFrom(
                      padding: const EdgeInsets.all(8),
                      minimumSize: const Size(40, 40)),
                  child: const Icon(Icons.save_outlined, size: 18))
              : FilledButton.icon(
                  onPressed: (_loading || _error != null) ? null : _save,
                  icon: const Icon(Icons.save_outlined, size: 16),
                  label: const Text('保存')),
        ]),
      );

  Widget _orientationSwitch() => Container(
        decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(8)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _orientBtn('横屏', true, Icons.stay_current_landscape_outlined),
          _orientBtn('竖屏', false, Icons.stay_current_portrait_outlined),
        ]),
      );

  Widget _orientBtn(String text, bool value, IconData icon) {
    final on = _landscape == value;
    return InkWell(
      onTap: () => _switchTarget(value),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
            color: on ? _primary.withValues(alpha: 0.22) : Colors.transparent,
            borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          Icon(icon, size: 14, color: on ? _primary : Colors.white38),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(
              color: on ? _primary : Colors.white54, fontSize: 12)),
        ]),
      ),
    );
  }

  Widget _badge() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
            color: (_dirty ? Colors.orange : _primary).withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10)),
        child: Text(_dirty ? '未保存' : (_customized ? '已自定义' : '初始布局'),
            style: TextStyle(
                color: _dirty ? Colors.orange : _primary, fontSize: 11)),
      );

  Widget _canvasArea() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text(_error!, style: const TextStyle(color: Colors.white54)));
    return Center(
      child: AspectRatio(
        aspectRatio: _canvasRatio,
        child: LayoutBuilder(builder: (context, c) {
          final W = c.maxWidth, H = c.maxHeight;
          return GestureDetector(
            onTap: () => setState(() => _selectedId = null),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF101018),
                border: Border.all(color: Colors.white24),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Stack(children: [
                  Center(
                      child: Text('游戏画面（$_targetName ${_canvasW.round()} : ${_canvasH.round()} 预览）',
                          style: const TextStyle(color: Colors.white12, fontSize: 13))),
                  for (final it in _items) _control(it, W, H),
                ]),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _control(ControlItem it, double W, double H) {
    final w = it.w * W, h = it.h * H;
    final selected = _selectedId == it.id;
    final shoulder = it.id == 'shL' || it.id == 'shR';
    return Positioned(
      left: (it.cx - it.w / 2) * W,
      top: (it.cy - it.h / 2) * H,
      width: w,
      height: h,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _selectedId = it.id),
        onPanUpdate: (d) => setState(() {
          _selectedId = it.id;
          it.cx = _clampCenter(it.cx + d.delta.dx / W, it.w);
          it.cy = _clampCenter(it.cy + d.delta.dy / H, it.h);
          _dirty = true;
        }),
        child: Container(
          decoration: BoxDecoration(
            color: selected
                ? _primary.withValues(alpha: 0.28)
                : Colors.white.withValues(alpha: 0.10),
            border: Border.all(
                color: selected ? _primary : Colors.white38,
                width: selected ? 2 : 1),
            borderRadius: BorderRadius.circular(
                shoulder ? h / 2 : math.min(w, h) / 2),
          ),
          alignment: Alignment.center,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Text(_shortLabels[it.id] ?? it.label,
                  style: TextStyle(
                      color: selected ? Colors.white : Colors.white70,
                      fontSize: math.min(w, h) * 0.34,
                      fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bottomBar(bool narrow) {
    final it = _selected;
    return Container(
      height: narrow ? 58 : 66,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(children: [
        SizedBox(
          width: narrow ? 62 : 110,
          child: Text(it == null ? '点选按键' : it.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: it == null ? Colors.white38 : Colors.white,
                  fontSize: narrow ? 11 : 13, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: 8),
        if (!narrow)
          const Text('大小', style: TextStyle(color: Colors.white54, fontSize: 12)),
        Expanded(
          child: Slider(
            value: it == null ? 1.0 : _scaleOf(it).clamp(0.4, 2.0).toDouble(),
            min: 0.4,
            max: 2.0,
            divisions: 16,
            activeColor: _primary,
            onChanged: it == null ? null : (v) => _setScale(it, v),
          ),
        ),
        SizedBox(
          width: 42,
          child: Text(it == null ? '' : '${(_scaleOf(it) * 100).round()}%',
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ),
        // 竖屏宽度有限，只保留最有用的左右微调；上下仍可直接拖动。
        if (it != null && !narrow) ...[
          const SizedBox(width: 8),
          _nudgeBtn(Icons.arrow_back, () => _nudge(it, -0.01, 0)),
          _nudgeBtn(Icons.arrow_forward, () => _nudge(it, 0.01, 0)),
          _nudgeBtn(Icons.arrow_upward, () => _nudge(it, 0, -0.01)),
          _nudgeBtn(Icons.arrow_downward, () => _nudge(it, 0, 0.01)),
        ],
        if (it != null && narrow) ...[
          _nudgeBtn(Icons.arrow_back, () => _nudge(it, -0.01, 0)),
          _nudgeBtn(Icons.arrow_forward, () => _nudge(it, 0.01, 0)),
        ],
      ]),
    );
  }

  Widget _nudgeBtn(IconData icon, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(left: 2),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 30, height: 30,
            decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(6)),
            child: Icon(icon, size: 15, color: Colors.white60),
          ),
        ),
      );
}
