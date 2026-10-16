import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../services/mkxp.dart';

/// 游戏运行页（M2/M3）：全屏黑底。SDL 引擎自建全屏窗口盖在 Flutter 之上，
/// 虚拟控制为原生浮层（MkxpTouchOverlay）。本页负责：
///   启动引擎 / 按设置锁横屏 / 保持常亮 / 记录最近游玩 / 退出时清理。
class GameRunPage extends StatefulWidget {
  final GameEntry game;
  const GameRunPage({super.key, required this.game});

  @override
  State<GameRunPage> createState() => _GameRunPageState();
}

class _GameRunPageState extends State<GameRunPage> {
  static const _primary = Color(0xFF4CC2FF);
  String _status = '正在启动…';
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final settings = await AppSettings.load();
    await Mkxp.setKeepAwake(settings.keepAwake);
    await Mkxp.setOrientation(settings.lockLandscape);
    await AppSettings.touchLastPlayed(widget.game.name);
    try {
      await Mkxp.launchGame('games/${widget.game.name}');
      if (!mounted) return;
      setState(() => _status = '运行中');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = '启动失败：$e\n（可在「设置 → 运行日志」查看 mkxp.log）';
        _failed = true;
      });
    }
  }

  Future<void> _cleanup() async {
    await Mkxp.setKeepAwake(false);
    await Mkxp.setOrientation(false);
    await Mkxp.quitGame();
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // 引擎窗口出现前的占位（引擎起后 SDL 全屏窗盖住本页）
            Center(
              child: _failed
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_status,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Color(0xFFFF453A), fontSize: 14, height: 1.6)),
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(
                            strokeWidth: 2, color: _primary),
                        const SizedBox(height: 16),
                        Text(_status,
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 14)),
                      ],
                    ),
            ),
            // 右上角返回（引擎窗盖住后不可见，但启动失败时可用）
            Positioned(
              top: 4,
              left: 4,
              child: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new,
                    color: Colors.white38, size: 20),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
