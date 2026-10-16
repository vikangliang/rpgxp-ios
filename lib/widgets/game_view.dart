import 'package:flutter/material.dart';

/// MKXP 游戏画面层（M1 起）。
///
/// 嵌入方案（见 README「嵌入方式决策」）：mkxp-z 是独立 app 形态，永远自己
/// `SDL_CreateWindow` 全屏渲染；Flutter 侧只做**透明控件浮层**（虚拟摇杆、
/// 动作键，属 M2）。因此这里不再使用 UiKitView 内嵌，而是全屏透明容器，
/// 后续触摸控件直接叠在上面。
class GameView extends StatelessWidget {
  const GameView({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
