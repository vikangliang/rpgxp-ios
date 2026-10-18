import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/mkxp.dart';

/// 日志页（M2/M3）：读取并显示 Documents/mkxp.log。
/// 无 Mac 环境下的调试代偿——引擎 stdout/stderr 与启动报错都在这里。
class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  String _log = '加载中…';
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final log = await Mkxp.readLog();
    if (!mounted) return;
    setState(() => _log = log.isEmpty ? '（日志为空）' : log);
    // 重载后跳到底部，方便看最新输出 / 异常
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _download() async {
    final log = await Mkxp.readLog();
    if (!mounted) return;
    if (log.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('日志为空，无可导出内容')));
      return;
    }
    final dir = await getTemporaryDirectory();
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    final file = File('${dir.path}/mkxp_$ts.log');
    await file.writeAsString(log);
    await Share.shareXFiles([XFile(file.path)],
        subject: 'mkxp.log', text: 'MKXP 运行日志');
  }

  Future<void> _clear() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF16161C),
        title: const Text('清空日志', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: const Text('确定清空 mkxp.log？',
            style: TextStyle(color: Colors.white70, fontSize: 14)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消', style: TextStyle(color: Colors.white54))),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('清空', style: TextStyle(color: Color(0xFFFF453A)))),
        ],
      ),
    );
    if (yes != true) return;
    await Mkxp.clearLog();
    _reload();
  }

  /// 场景快照：引擎在启动后 ≈0.7s/10s/60s/180s 把场景 FBO 落成 PNG。
  /// 用来一锤定音地判断“画面放大/缺背景”是游戏渲染问题还是显示链路问题。
  Future<void> _showSceneDumps() async {
    final dumps = await Mkxp.listSceneDumps();
    if (!mounted) return;
    if (dumps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('暂无场景快照（启动引擎后约 0.7s/10s/60s/180s 自动落盘）')));
      return;
    }
    final Map<String, Uint8List?> bytes = {};
    for (final d in dumps) {
      bytes[d.name] = await Mkxp.readSceneDump(d.name);
    }
    if (!mounted) return;
    final controller = PageController();
    var index = 0;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF16161C),
        insetPadding: const EdgeInsets.all(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('场景快照（游戏 FBO 原样）',
                        style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    tooltip: '分享当前快照',
                    icon: const Icon(Icons.share, color: Colors.white70, size: 20),
                    onPressed: () async {
                      final name = dumps[index].name;
                      final data = bytes[name];
                      if (data == null) return;
                      final dir = await getTemporaryDirectory();
                      final f = File('${dir.path}/$name');
                      await f.writeAsBytes(data);
                      await Share.shareXFiles([XFile(f.path)], text: name);
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              Flexible(
                child: PageView.builder(
                  controller: controller,
                  itemCount: dumps.length,
                  onPageChanged: (i) => index = i,
                  itemBuilder: (_, i) {
                    final data = bytes[dumps[i].name];
                    if (data == null) {
                      return const Center(child: Text('读取失败', style: TextStyle(color: Colors.white38)));
                    }
                    return InteractiveViewer(
                      maxScale: 6,
                      child: Center(child: Image.memory(data, fit: BoxFit.contain)),
                    );
                  },
                ),
              ),
              const SizedBox(height: 6),
              Text(
                dumps.map((d) => d.name).join('   '),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 10, fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
      ),
    );
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0F),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('运行日志 (mkxp.log)',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
              icon: const Icon(Icons.image_outlined),
              tooltip: '场景快照',
              onPressed: _showSceneDumps),
          IconButton(
              icon: const Icon(Icons.download_outlined),
              tooltip: '导出/下载日志',
              onPressed: _download),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
          IconButton(icon: const Icon(Icons.delete_outline), onPressed: _clear),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF16161C),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Scrollbar(
              controller: _scroll,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _scroll,
                child: SelectableText(
                  _log,
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      fontFamily: 'monospace',
                      height: 1.5),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
