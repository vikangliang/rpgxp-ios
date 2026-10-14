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

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // 全屏承载原生游戏视图（M0 显示一个原生 UIView；M1 接入 MKXP 后渲染游戏）
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
                  child: const Text('M0 流水线验证 · MKXP 未接入',
                      style: TextStyle(color: Colors.white70)),
                ),
              ),
            ),
            Positioned(
              bottom: 96,
              left: 24,
              right: 24,
              child: Center(
                child: Text(_log,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white54, fontSize: 10)),
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
