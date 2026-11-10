import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/mkxp.dart';

/// 虚拟按键布局编辑器。
/// 进页面切横屏（按键本来就是横屏布局，所见即所得），退出恢复竖屏。
/// 画布按参考比例 896:414 绘制，控件坐标全部归一化（0..1），换设备不跑偏。
/// 「重置」调用原生 resetControlLayout 删除自定义配置，回到最初硬编码布局。
class ControlLayoutPage extends StatefulWidget {
  const ControlLayoutPage({super.key});

  @override
  State<ControlLayoutPage> createState() => _ControlLayoutPageState();
}

class _ControlLayoutPageState extends State<ControlLayoutPage> {
  static const _primary = Color(0xFF4CC2FF);

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
    // 与 game_run.dart 一致：先松开 Flutter 的全局竖屏锁，再由原生强制切横屏
    // （iOS 上只改 preferred orientations 时，设备物理竖屏不会真的旋转）。
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]).then((_) => Mkxp.setOrientation(true));
    _load();
  }

  @override
  void dispose() {
    Mkxp.setOrientation(false);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  Future<void> _load() async {
    final l = await Mkxp.getControlLayout();
    if (!mounted) return;
    setState(() {
      _items = l.items.map((e) => e.copy()).toList();
      _defaults = l.defaults.map((e) => e.copy()).toList();
      _customized = l.customized;
      _canvasRatio = l.aspect;
      _canvasW = l.canvasW;
      _canvasH = l.canvasH;
      _loading = false;
      _error = _items.isEmpty ? '无法读取原生按键布局（仅 iOS 支持）' : null;
    });
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

  Future<void> _save() async {
    try {
      await Mkxp.setControlLayout(_items);
      if (!mounted) return;
      setState(() {
        _dirty = false;
        _customized = true;
      });
      _toast('已保存，进入游戏即生效');
    } catch (e) {
      _toast('保存失败：$e');
    }
  }

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF16161C),
        title: const Text('重置按键布局', style: TextStyle(color: Colors.white)),
        content: const Text('所有按键的位置和大小将恢复到初始布局。',
            style: TextStyle(color: Colors.white70)),
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
      await Mkxp.resetControlLayout();
      if (!mounted) return;
      setState(() {
        _items = _defaults.map((e) => e.copy()).toList();
        _selectedId = null;
        _dirty = false;
        _customized = false;
      });
      _toast('已恢复初始布局');
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
        child: Column(
          children: [
            _toolbar(),
            Expanded(child: _canvasArea()),
            _bottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _toolbar() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(children: [
          IconButton(
              onPressed: _back,
              icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white70, size: 18)),
          const Text('虚拟按键布局',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(width: 10),
          _badge(),
          const Spacer(),
          const Text('拖动移动 · 点选后调大小',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
          const SizedBox(width: 12),
          TextButton.icon(
              onPressed: (_customized || _dirty) ? _reset : null,
              icon: const Icon(Icons.restart_alt, size: 16),
              label: const Text('重置')),
          const SizedBox(width: 4),
          FilledButton.icon(
              onPressed: (_loading || _error != null) ? null : _save,
              icon: const Icon(Icons.save_outlined, size: 16),
              label: const Text('保存')),
        ]),
      );

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
                      child: Text('游戏画面（横屏 ${_canvasW.round()} : ${_canvasH.round()} 预览）',
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

  Widget _bottomBar() {
    final it = _selected;
    return Container(
      height: 66,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(children: [
        SizedBox(
          width: 110,
          child: Text(it == null ? '点选一个按键' : it.label,
              style: TextStyle(
                  color: it == null ? Colors.white38 : Colors.white,
                  fontSize: 13, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: 8),
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
          width: 46,
          child: Text(it == null ? '' : '${(_scaleOf(it) * 100).round()}%',
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ),
        if (it != null) ...[
          const SizedBox(width: 8),
          _nudgeBtn(Icons.arrow_back, () => _nudge(it, -0.01, 0)),
          _nudgeBtn(Icons.arrow_forward, () => _nudge(it, 0.01, 0)),
          _nudgeBtn(Icons.arrow_upward, () => _nudge(it, 0, -0.01)),
          _nudgeBtn(Icons.arrow_downward, () => _nudge(it, 0, 0.01)),
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
