import 'package:flutter/material.dart';
import 'services/mkxp.dart';
import 'widgets/game_view.dart';

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
  String _log = '尚未读取';
  final _gamePathController = TextEditingController(text: 'games/Essentials');

  @override
  void dispose() {
    _gamePathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // 游戏画面由 MKXP 的 SDL 全屏窗口渲染；这里是透明控件浮层（M1 起）
            const GameView(),
            Positioned(
              top: 48,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text('M1 · 引擎已链接，启动后由 SDL 全屏窗渲染',
                      style: TextStyle(color: Colors.white70)),
                ),
              ),
            ),
            Positioned(
              bottom: 176,
              left: 24,
              right: 24,
              child: Center(
                child: Text(_log,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white54, fontSize: 10)),
              ),
            ),
            Positioned(
              bottom: 112,
              left: 24,
              right: 24,
              child: TextField(
                controller: _gamePathController,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
                decoration: const InputDecoration(
                  labelText: '游戏目录（相对 Documents，如 Essentials）',
                  labelStyle: TextStyle(color: Colors.white38, fontSize: 11),
                  enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white24)),
                ),
              ),
            ),
            Positioned(
              bottom: 40,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: () async {
                      final path = _gamePathController.text.trim();
                      if (path.isEmpty) return;
                      setState(() => _log = '正在启动引擎：$path …');
                      await Mkxp.launchGame(path);
                      final log = await Mkxp.readLog();
                      setState(() => _log = log);
                    },
                    child: const Text('启动引擎'),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: () async {
                      await Mkxp.quitGame();
                      final log = await Mkxp.readLog();
                      setState(() => _log = log);
                    },
                    child: const Text('关机'),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: () async {
                      final log = await Mkxp.readLog();
                      setState(() => _log = log);
                    },
                    child: const Text('读取原生日志'),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}
