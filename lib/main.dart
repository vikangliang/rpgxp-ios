import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/game_library.dart';
import 'services/mkxp.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: GameScreen(),
      );
}

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});
  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  List<GameInfo> _games = [];
  bool _loading = true;
  bool _importing = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final games = await GameLibrary.scan();
    if (!mounted) return;
    setState(() {
      _games = games;
      _loading = false;
    });
  }

  Future<void> _import() async {
    setState(() {
      _importing = true;
      _status = '正在选择并解压…（大游戏请稍候）';
    });
    try {
      final name = await GameLibrary.importZip();
      setState(() => _status = name.isEmpty ? '已取消导入' : '导入完成：$name');
      if (name.isNotEmpty) await _refresh();
    } catch (e) {
      setState(() => _status = '导入失败：$e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _launch(GameInfo g) async {
    setState(() => _status = '正在启动 ${g.name}…');
    try {
      await Mkxp.launchGame('games/${g.name}');
      // 启动成功：引擎事件循环在后台线程，界面不冻结；SDL 全屏窗盖在 Flutter 之上，
      // 原生触摸浮层（MkxpTouchOverlay）同步展示。引擎报错看「日志」页 mkxp.log。
      if (mounted) setState(() => _status = '${g.name} 运行中');
    } on PlatformException catch (e) {
      if (mounted) setState(() => _status = '启动失败：${e.message}');
    }
  }

  Future<void> _delete(GameInfo g) async {
    await GameLibrary.delete(g.name);
    setState(() => _status = '已删除 ${g.name}');
    await _refresh();
  }

  Future<void> _showLog() async {
    final log = await Mkxp.readLog();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('mkxp.log',
            style: TextStyle(color: Colors.white70, fontSize: 14)),
        content: SizedBox(
          width: double.maxFinite,
          height: 320,
          child: SingleChildScrollView(
            child: Text(log,
                style: const TextStyle(color: Colors.white54, fontSize: 10)),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text('M2 · 游戏库（MKXP-Z 引擎）',
                      style: TextStyle(color: Colors.white70)),
                ),
                const SizedBox(height: 8),
                Text(_status,
                    style: const TextStyle(color: Colors.amber, fontSize: 11)),
                const SizedBox(height: 8),
                Expanded(
                  child: _loading
                      ? const Center(
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : _games.isEmpty
                          ? const Center(
                              child: Text(
                                '还没有游戏\n\n点下方「导入游戏」选择游戏 Zip，\n或用 iTunes 文件共享把游戏文件夹\n放进 Documents/',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: Colors.white38, fontSize: 12),
                              ),
                            )
                          : RefreshIndicator(
                              onRefresh: _refresh,
                              child: ListView.separated(
                                itemCount: _games.length,
                                separatorBuilder: (_, __) =>
                                    const Divider(color: Colors.white12, height: 1),
                                itemBuilder: (_, i) {
                                  final g = _games[i];
                                  return ListTile(
                                    title: Text(g.name,
                                        style: const TextStyle(
                                            color: Colors.white)),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon: const Icon(
                                              Icons.delete_outline,
                                              color: Colors.white38),
                                          tooltip: '删除',
                                          onPressed: () => _delete(g),
                                        ),
                                        ElevatedButton(
                                          onPressed: () => _launch(g),
                                          child: const Text('启动'),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _importing ? null : _import,
                      icon: _importing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.folder_zip_outlined, size: 18),
                      label: Text(_importing ? '解压中…' : '导入游戏'),
                    ),
                    OutlinedButton(
                        onPressed: _refresh, child: const Text('刷新')),
                    OutlinedButton(
                        onPressed: _showLog, child: const Text('日志')),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
}
