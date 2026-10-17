import 'package:flutter/material.dart';

/// MKXP 游戏画面层（M1 终版：SDL 官方路径）。
///
/// 引擎自己创建全屏 UIWindow 并 makeKeyAndVisible（见 scripts/mkxp-framework/
/// ios_embed.mm），窗口层级 1999：盖在 Flutter 界面之上、低于原生触摸浮层
/// （MkxpTouchOverlay，alert+2）。因此这里不需要 UiKitView 承载任何视图——
/// 游戏画面直接从引擎窗口出，虚拟控件为原生浮层（不经过 Flutter）。
class GameView extends StatelessWidget {
  const GameView({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
