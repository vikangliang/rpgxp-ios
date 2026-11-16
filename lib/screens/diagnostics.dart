import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/mkxp.dart';

/// 性能诊断页（gated by MKXP_DIAG）。读取引擎 Ruby 侧周期写入 mkxp.log 的
/// `[diag] <json>`（经原生 getDiagnostics 解析），结构化展示：
///   · 实时 FPS（引擎报）
///   · Ruby 帧逻辑耗时（平均/最大/采样数）
///   · 慢帧统计（阈值/次数/最近一次卡顿组件）
///   · 组件耗时归因（Top 8 条形图）
///   · 闪退列表（类型/信息/回溯）
/// 游戏中另由原生 HUD 浮层实时显示「FPS + 当前卡顿组件」，本页用于事后/复现分析。
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  static const _primary = Color(0xFF4CC2FF);
  static const _card = Color(0xFF16161C);

  Map? _diag;
  double _nativeFps = 0.0;
  bool _loading = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    final d = await Mkxp.getDiagnostics();
    // 原生侧帧率（与游戏内 HUD 同值）比日志里的窗口均值更实时，优先用它。
    final f = await Mkxp.getFps();
    if (!mounted) return;
    setState(() {
      _diag = d;
      _nativeFps = f;
      _loading = false;
    });
  }

  // —— 类型安全取值助手（平台通道字典为非泛型 Map，避免 as 转换失败）——
  double _num(Object? v, [double dflt = 0]) => (v is num) ? v.toDouble() : dflt;
  int _int(Object? v, [int dflt = 0]) => (v is num) ? v.round() : dflt;
  Map _map(Object? v) => v is Map ? v as Map : <Object?, Object?>{};
  List _list(Object? v) => v is List ? v as List : const [];

  // —— 派生指标 ——
  /// 帧率：优先用原生侧实时值（与游戏内 HUD 同值），无则退回日志里的窗口均值。
  double get fps => _nativeFps > 0 ? _nativeFps : _num(_diag?['fps']);
  /// 当前显示的帧率是否来自日志（游戏未运行，值为上次运行时的实测帧率）。
  bool get fpsFromLog => _nativeFps <= 0 && _num(_diag?['fps']) > 0;
  Map get ruby => _map(_diag?['ruby']);
  double get rubyAvg => _num(ruby['avgMs']);
  double get rubyMax => _num(ruby['maxMs']);
  int get rubyN => _int(ruby['n']);
  Map get slow => _map(_diag?['slow']);
  /// 引擎侧帧分解（ios_embed.mm 埋点）：真实帧周期的构成。
  Map get engine => _map(_diag?['engine']);
  /// 冻结抓拍：真实帧间隔 >200ms 的现场（Ruby 逻辑耗时抓不到这类卡顿）。
  Map get freeze => _map(_diag?['freeze']);
  List get freezeSamples {
    final s = freeze['samples'];
    return s is List ? s : const [];
  }
  /// 最严重的冻结现场（按 gapMs 降序 Top-8）——最近 20 个样本可能挤掉最严重的那次。
  List get freezeWorst {
    final s = freeze['worst'];
    return s is List ? s : const [];
  }
  int get slowCount => _int(slow['count']);
  int get slowThr => _int(slow['thresholdMs'], 16);
  List get components => _list(_diag?['components']);
  Map get lastSlow => _map(_diag?['lastSlow']);
  List get crashes => _list(_diag?['crashes']);
  /// 条形归一基准：取所有组件里最大的【每帧均值】。
  /// 兼容旧数据（只有 ms 没有 avgMs）：此时退回用累计值。
  double get _compMax => components.fold(0.0, (m, e) {
    if (e is! Map) return m;
    final v = _num(e['avgMs']) > 0 ? _num(e['avgMs']) : _num(e['ms']);
    return v > m ? v : m;
  });

  bool get _hasData => rubyN > 0;

  Future<void> _export() async {
    final json = const JsonEncoder.withIndent('  ').convert(_diag ?? {});
    final dir = await getTemporaryDirectory();
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    final file = File('${dir.path}/mkxp_diag_$ts.json');
    await file.writeAsString(json);
    await Share.shareXFiles([XFile(file.path)],
        subject: 'mkxp 诊断', text: 'MKXP 运行诊断');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0F),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('性能诊断',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
              icon: const Icon(Icons.article_outlined),
              tooltip: '运行日志',
              onPressed: () => Navigator.pushNamed(context, '/log')),
          IconButton(
              icon: const Icon(Icons.download_outlined),
              tooltip: '导出诊断 JSON',
              onPressed: _export),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _poll),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(strokeWidth: 2, color: _primary))
            : !_hasData
                ? _emptyHint()
                : _body(),
      ),
    );
  }

  Widget _emptyHint() => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.speed_outlined,
                  size: 48, color: Colors.white24),
              const SizedBox(height: 16),
              const Text('诊断器未开启或本局暂无数据',
                  style: TextStyle(color: Colors.white, fontSize: 16)),
              const SizedBox(height: 10),
              const Text(
                '请在「设置 → 游戏 → 性能诊断」打开开关，进入游戏复现卡顿/慢帧/闪退，'
                '再回到此处查看归因。游戏中浮层会实时显示 FPS + 当前卡顿组件。',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 13, height: 1.6),
              ),
            ],
          ),
        ),
      );

  Widget _body() => ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _freezeCard(),
          const SizedBox(height: 14),
          _fpsCard(),
          const SizedBox(height: 14),
          _engineCard(),
          const SizedBox(height: 14),
          _rubyCard(),
          const SizedBox(height: 14),
          _slowCard(),
          const SizedBox(height: 14),
          _componentsCard(),
          const SizedBox(height: 14),
          _crashesCard(),
        ],
      );

  /// 冻结抓拍卡片：>200ms 的帧间隔会立即落盘（黑匣子），这里展示最近 20 次现场。
  /// 关键看 outsideMs（= 帧间隔 − Ruby 逻辑耗时）：它大就说明卡顿在引擎/呈现层。
  Widget _freezeCard() {
    final n = _int(freeze['count']);
    final thr = _int(freeze['thresholdMs'], 200);
    final maxGap = _num(freeze['maxGapMs']);
    final lastGap = _num(freeze['lastGapMs']);
    final samples = freezeSamples;
    final shown = samples.length > 8 ? samples.sublist(samples.length - 8) : samples;
    final worst = freezeWorst;
    return _cardBox('冻结抓拍（帧间隔 > $thr ms）',
        children: [
          _kv('次数', '$n'),
          _kv('最大帧间隔', maxGap > 0 ? '${maxGap.toStringAsFixed(0)} ms' : '—'),
          _kv('最近帧间隔', lastGap > 0 ? '${lastGap.toStringAsFixed(0)} ms' : '—'),
          if (worst.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('最严重（按卡顿时长排序）',
                style: TextStyle(color: Colors.redAccent, fontSize: 12)),
            const SizedBox(height: 4),
            for (final s in worst.take(5))
              if (s is Map)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '${_num(s['gapMs']).toStringAsFixed(0)}ms  引擎外 ${_num(s['outsideMs']).toStringAsFixed(0)}ms'
                    '  ${s['scene']?.toString() ?? '?'} @${s['mapId']?.toString() ?? '?'}(${s['px']?.toString() ?? '?'},${s['py']?.toString() ?? '?'})',
                    style: const TextStyle(color: Color(0xFFFF9A8F), fontSize: 11, height: 1.4),
                  ),
                ),
          ],
          if (shown.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('最近现场（倒序）',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 4),
            for (final s in shown.reversed)
              if (s is Map)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '${_num(s['gapMs']).toStringAsFixed(0)}ms  引擎外 ${_num(s['outsideMs']).toStringAsFixed(0)}ms'
                    '  Ruby ${_num(s['rubyMs']).toStringAsFixed(1)}ms'
                    '  ${s['scene']?.toString() ?? '?'}'
                    '  @${s['mapId']?.toString() ?? '?'}(${s['px']?.toString() ?? '?'},${s['py']?.toString() ?? '?'})',
                    style: const TextStyle(color: Colors.white70, fontSize: 11, height: 1.4),
                  ),
                ),
          ],
          const SizedBox(height: 6),
          const Text(
              '帧间隔由 Graphics.frame_count + 单调时钟测得，包含引擎等待与呈现。'
              '「引擎外」= 帧间隔 − Ruby 逻辑耗时；它远大于 Ruby 耗时时，'
              '说明卡顿发生在引擎/GL/软呈现层（Ruby 侧改不动）。',
              style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.5)),
        ]);
  }

  Widget _fpsCard() {
    final v = fps.round();
    final running = fps > 0;
    final color = fps >= 55
        ? const Color(0xFF34C759)
        : fps >= 30
            ? const Color(0xFFFFD60A)
            : const Color(0xFFFF453A);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
          color: _card, borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          Text(running ? '$v' : '—',
              style: TextStyle(
                  color: running ? color : Colors.white38,
                  fontSize: 44,
                  fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          const Text('FPS',
              style: TextStyle(color: Colors.white54, fontSize: 18)),
          const Spacer(),
          Text(running
                  ? (fpsFromLog ? '上次运行的实测帧率' : '引擎实时帧率（原生 HUD 同值）')
                  : '游戏中由 HUD 实时显示',
              style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ),
    );
  }

  /// 引擎侧帧分解：真实帧周期由哪一段构成。
  /// 这是比 Ruby 侧归因更权威的数据——Ruby 只覆盖脚本/绘制逻辑（~0.2ms），
  /// 真实开销在 iOS 软呈现层：GPU→CPU 回读(read) + 哈希拷贝(hmc) + 主线程放大上屏(disp)。
  Widget _engineCard() {
    final e = engine;
    if (e.isEmpty) {
      return _cardBox('引擎侧帧分解',
          children: const [
            Text('暂无引擎埋点数据（需开启性能诊断并进入游戏，引擎每 600 帧打印一次）。',
                style: TextStyle(color: Colors.white38, fontSize: 12))
          ]);
    }
    final frame = _num(e['frameMs']);
    final eng = _num(e['engine']);
    final read = _num(e['read']);
    final hmc = _num(e['hmc']);
    final disp = _num(e['disp']);
    final mainDisp = _num(e['mainDispMs']);
    final softMax = _num(e['softMaxMs']);
    final efps = _num(e['fps']);
    // 引擎侧细分（graphics.cpp 埋点，新包才有；旧包缺省为 0 → 不显示该行）
    final redraw = _num(e['redrawMs']);
    final delay = _num(e['delayMs']);
    final swapMs = _num(e['swapMs']);
    String ms(double v) => '${v.toStringAsFixed(2)} ms';
    return _cardBox('引擎侧帧分解',
        children: [
          _kv('真实帧周期', ms(frame)),
          _kv('引擎实测 FPS', efps > 0 ? efps.toStringAsFixed(1) : '—'),
          const SizedBox(height: 4),
          _kv('engine（引擎渲染+等待）', ms(eng)),
          if (redraw > 0) _kv('├ redraw（合成+GL提交+swap）', ms(redraw)),
          if (delay > 0) _kv('├ delay（等 vsync 等待）', ms(delay)),
          if (swapMs > 0) _kv('├ swap（提交+等 GPU）', ms(swapMs)),
          _kv('read（GPU→CPU 回读）', ms(read)),
          _kv('hmc（哈希+拷贝+CGImage）', ms(hmc)),
          _kv('disp（主线程上屏）', ms(disp)),
          if (mainDisp > 0) _kv('main-display（主线程显示）', ms(mainDisp)),
          if (softMax > 0) _kv('软呈现峰值', ms(softMax)),
          const SizedBox(height: 6),
          const Text(
              'engine = 帧间隔 − read − hmc；redraw/delay/swap 把它进一步拆成'
              '「引擎合成与 GL 提交」「等 vsync」「提交并等 GPU」三段。'
              'read/hmc/disp 是 iOS 软呈现层的 CPU 开销。',
              style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.5)),
        ]);
  }

  Widget _rubyCard() => _cardBox('Ruby 帧逻辑耗时',
      children: [
        _kv('平均', '${rubyAvg.toStringAsFixed(2)} ms'),
        _kv('最大', '${rubyMax.toStringAsFixed(2)} ms'),
        _kv('采样帧数', '$rubyN'),
        const SizedBox(height: 6),
        const Text('Ruby 侧每帧脚本/绘制逻辑耗时（不含引擎 GL 渲染）。',
            style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.5)),
      ]);

  Widget _slowCard() {
    final comp = lastSlow['comp']?.toString() ?? '—';
    final ms = _num(lastSlow['ms']);
    final over = _num(slow['overPct']);
    final hard = _int(slow['hardCount']);
    final hardThr = _int(slow['hardThresholdMs'], 40);
    return _cardBox('超预算帧（> ${slowThr}ms）',
        children: [
          _kv('次数', '$slowCount'),
          _kv('占采样帧', '${over.toStringAsFixed(2)} %'),
          _kv('严重卡顿（> ${hardThr}ms）', '$hard'),
          _kv('最近一次', ms > 0 ? '${ms.toStringAsFixed(1)} ms @ $comp' : '—'),
          const SizedBox(height: 6),
          const Text('阈值取 60fps 帧预算 16.7ms：超预算即掉帧。超阈值的帧会记录'
              '“最耗时组件”，作为卡顿归因线索。',
              style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.5)),
        ]);
  }

  Widget _componentsCard() {
    if (components.isEmpty) {
      return _cardBox('组件耗时归因',
          children: const [
            Text('暂无组件采样（诊断开启后跑一会才有数据）。',
                style: TextStyle(color: Colors.white38, fontSize: 12))
          ]);
    }
    final max = _compMax;
    return _cardBox('组件耗时归因（Top ${components.length}）',
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text(
                '条形按「每帧均值」归一（对照 16.7ms 的 60fps 帧预算）；括号内为会话累计与占比。',
                style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.5)),
          ),
          for (final e in components)
            if (e is Map)
              _bar(e['name']?.toString() ?? '?', _num(e['avgMs']),
                  _num(e['ms']), _num(e['pct']), max),
        ]);
  }

  /// [avgMs] 每帧均值（条形归一基准）、[totalMs] 会话累计、[pct] 占 Ruby 总耗时比例。
  Widget _bar(String name, double avgMs, double totalMs, double pct, double max) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                    child: Text(name,
                        style: const TextStyle(color: Colors.white, fontSize: 13))),
                Text(
                    '${avgMs.toStringAsFixed(2)} ms/帧  (${totalMs.toStringAsFixed(0)} ms · ${pct.toStringAsFixed(1)}%)',
                    style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: max > 0 ? (avgMs / max).clamp(0, 1) : 0,
                minHeight: 6,
                backgroundColor: Colors.white10,
                valueColor: AlwaysStoppedAnimation<Color>(
                  avgMs >= 40
                      ? const Color(0xFFFF453A)
                      : avgMs >= 16
                          ? const Color(0xFFFFD60A)
                          : _primary,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _crashesCard() {
    if (crashes.isEmpty) {
      return _cardBox('闪退 / 逐帧异常', children: const [
        Text('本会话未捕获到异常（崩溃回溯为空 = 这一局没崩）。',
            style: TextStyle(color: Colors.white38, fontSize: 12))
      ]);
    }
    return _cardBox('闪退 / 逐帧异常（${crashes.length}）',
        children: [
          for (final c in crashes)
            if (c is Map) _crashItem(c),
        ]);
  }

  Widget _crashItem(Map c) {
    final type = c['type']?.toString() ?? '?';
    final msg = c['msg']?.toString() ?? '';
    final bt = _list(c['bt']);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: const Color(0xFF0B0B0F),
          borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(type,
              style: const TextStyle(
                  color: Color(0xFFFF453A),
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          if (msg.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(msg,
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 12))),
          if (bt.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                bt.whereType<String>().join('\n'),
                style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                    fontFamily: 'monospace',
                    height: 1.4),
              ),
            ),
        ],
      ),
    );
  }

  Widget _cardBox(String title, {required List<Widget> children}) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: _card, borderRadius: BorderRadius.circular(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Text(k, style: const TextStyle(color: Colors.white54, fontSize: 13)),
            const Spacer(),
            Text(v,
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ],
        ),
      );
}
