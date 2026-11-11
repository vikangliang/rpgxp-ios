import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/mkxp.dart';

/// 虚拟按键布局编辑器。
/// 横屏/竖屏各一套独立布局，工具栏切换只改变【预览画布】和【要编辑的那套配置】，
/// 绝不调用任何方向 API —— 编辑器跟随设置页的竖屏锁，设备/游戏画面不会被旋转。
/// 游戏横屏还是竖屏完全由设置里的「固定横屏游戏」开关决定（game_run.dart）。
/// 两套坐标都归一化（0..1），各自相对本方向画布，不会因宽高比翻转而拉伸变形。
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
    _load();
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
    await _load();   // 只换预览与配置，不旋转设备
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

  void _back() {
    // 编辑器从不改方向，直接出栈即可（方向由设置页的竖屏锁 / 游戏页的开关决定）。
    Navigator.pop(context);
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
          // 横屏预览在竖屏手机上整体旋转 90°，底部滑块栏也跟着转 90° 并
          // 拉长成左侧竖条；否则它会横在旋转后的画布下面，方向对不上。
          final rotated = _landscape && narrow;
          if (!rotated) {
            return Column(children: [
              _toolbar(narrow),
              Expanded(child: _canvasArea(narrow)),
              _bottomBar(narrow),
            ]);
          }
          return Column(children: [
            _toolbar(narrow),
            Expanded(
              child: LayoutBuilder(builder: (context, area) {
                // 与十字微调盘及底部条同厚：旋转后竖条宽度要容得下 3 行按键。
                const barT = 72.0;
                return Row(children: [
                  SizedBox(
                    width: barT,
                    child: RotatedBox(
                      quarterTurns: 1,
                      // child 尺寸与旋转后的占用互换：(宽,高) -> (高,宽)
                      child: SizedBox(
                        width: area.maxHeight,
                        height: barT,
                        child: _bottomBar(narrow, barT),
                      ),
                    ),
                  ),
                  Expanded(child: _canvasArea(narrow)),
                ]);
              }),
            ),
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
          _orientationSwitch(narrow),
          const SizedBox(width: 8),
          if (!narrow) _badge(),
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

  Widget _orientationSwitch(bool narrow) => Container(
        decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(8)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _orientBtn('横屏', true, Icons.stay_current_landscape_outlined, narrow),
          _orientBtn('竖屏', false, Icons.stay_current_portrait_outlined, narrow),
        ]),
      );

  Widget _orientBtn(String text, bool value, IconData icon, bool narrow) {
    final on = _landscape == value;
    return Tooltip(
      message: '$text布局',
      child: InkWell(
        onTap: () => _switchTarget(value),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: EdgeInsets.symmetric(
              horizontal: narrow ? 9 : 10, vertical: 5),
          decoration: BoxDecoration(
              color: on ? _primary.withValues(alpha: 0.22) : Colors.transparent,
              borderRadius: BorderRadius.circular(8)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15, color: on ? _primary : Colors.white38),
            if (!narrow) ...[
              const SizedBox(width: 4),
              Text(text, style: TextStyle(
                  color: on ? _primary : Colors.white54, fontSize: 12)),
            ],
          ]),
        ),
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

  Widget _canvasArea(bool narrow) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text(_error!, style: const TextStyle(color: Colors.white54)));
    return Column(children: [
      // 方向标签放在画布外，保证竖屏画布被压窄时也能一眼看出当前预览的是哪一套。
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        child: Row(children: [
          Icon(_landscape ? Icons.stay_current_landscape_outlined
                          : Icons.stay_current_portrait_outlined,
              size: 16, color: _primary),
          const SizedBox(width: 6),
          Text('$_targetName预览  ${_canvasW.round()} × ${_canvasH.round()}',
              style: const TextStyle(
                  color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
          const Spacer(),
          if (narrow) _badge(),
        ]),
      ),
      Expanded(
        child: LayoutBuilder(builder: (context, area) {
          // 竖屏手机上横屏画布原本只是一条 896:414 的扁带，按键太小不好拖。
          // 只把【画布】整体旋转 90°（画布内的按键/文字一起转），让它以
          // 414:896 的竖向比例铺满黄框区域；工具栏、方向切换、底部滑块等
          // 画布外的 app 布局一律不旋转，设备方向也不改。
          final rotated = _landscape && narrow;
          if (!rotated) {
            return Center(
              child: AspectRatio(
                aspectRatio: _canvasRatio,
                child: LayoutBuilder(builder: (context, cc) =>
                    _canvasBody(cc.maxWidth, cc.maxHeight, false)),
              ),
            );
          }
          final r = _canvasH / _canvasW;
          final drawW = math.min(area.maxWidth, area.maxHeight * r);
          final drawH = drawW / r;
          return Center(
            child: RotatedBox(
              quarterTurns: 1,
              // child 尺寸与旋转后的屏幕占用互换：(宽,高) -> (高,宽)
              child: SizedBox(
                width: drawH,
                height: drawW,
                child: _canvasBody(drawH, drawW, true),
              ),
            ),
          );
        }),
      ),
    ]);
  }

  Widget _canvasBody(double W, double H, bool rotated) {
    return GestureDetector(
      onTap: () => setState(() => _selectedId = null),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF101018),
          border: Border.all(
              color: _primary.withValues(alpha: 0.55), width: 1.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(children: [
            Center(
                child: Text(
                    '游戏画面（$_targetName ${_canvasW.round()} : ${_canvasH.round()}）',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 12))),
            // 左上角方向角标：旋转后随画布一起转，歪头看仍是正的。
            Positioned(
              left: 6, top: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                    color: _primary.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(6)),
                child: Text(_targetName,
                    style: const TextStyle(
                        color: _primary, fontSize: 10)),
              ),
            ),
            for (final it in _items) _control(it, W, H, rotated),
          ]),
        ),
      ),
    );
  }

  Widget _control(ControlItem it, double W, double H, bool rotated) {
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
          // DragUpdateDetails.delta 是【屏幕】位移，不受 RotatedBox 变换影响。
          // 画布顺时针转 90° 后：屏幕 (dx,dy) -> 画布 (du,dv) = (dy,-dx)，
          // 否则拖动手感会与视觉方向相反。
          final du = rotated ? d.delta.dy : d.delta.dx;
          final dv = rotated ? -d.delta.dx : d.delta.dy;
          it.cx = _clampCenter(it.cx + du / W, it.w);
          it.cy = _clampCenter(it.cy + dv / H, it.h);
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

  /// [height] 供旋转成左侧竖条时指定厚度；不传则沿用原来的底部条高度。
  Widget _bottomBar(bool narrow, [double? height]) {
    final it = _selected;
    return Container(
      height: height ?? (narrow ? 72 : 66),
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
        // 宽屏仍用一排四键；竖屏手机改成十字微调盘，补上上下键。
        if (it != null && !narrow) ...[
          const SizedBox(width: 8),
          _nudgeBtn(Icons.arrow_back, () => _nudge(it, -0.01, 0)),
          _nudgeBtn(Icons.arrow_forward, () => _nudge(it, 0.01, 0)),
          _nudgeBtn(Icons.arrow_upward, () => _nudge(it, 0, -0.01)),
          _nudgeBtn(Icons.arrow_downward, () => _nudge(it, 0, 0.01)),
        ],
        if (it != null && narrow) _nudgePad(it),
      ]),
    );
  }

  /// 十字方向微调：上下键补在左右键的正上 / 正下方。整块随 _bottomBar
  /// 一起旋转，横屏预览里视觉上就成为红框标的左右两侧，与画布方向一致。
  Widget _nudgePad(ControlItem it) {
    const s = 22.0;
    const rowW = 2 * (s + 2);
    Widget b(IconData icon, double dx, double dy) =>
        _nudgeBtn(icon, () => _nudge(it, dx, dy), s);
    Widget centered(Widget child) =>
        SizedBox(width: rowW, child: Center(child: child));
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        centered(b(Icons.arrow_upward, 0, -0.01)),
        Row(mainAxisSize: MainAxisSize.min, children: [
          b(Icons.arrow_back, -0.01, 0),
          b(Icons.arrow_forward, 0.01, 0),
        ]),
        centered(b(Icons.arrow_downward, 0, 0.01)),
      ],
    );
  }

  Widget _nudgeBtn(IconData icon, VoidCallback onTap, [double size = 30]) => Padding(
        padding: const EdgeInsets.only(left: 2),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: size, height: size,
            decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(6)),
            child: Icon(icon, size: size * 0.5, color: Colors.white60),
          ),
        ),
      );
}
