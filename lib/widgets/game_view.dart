import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 全屏承载 MKXP 游戏画面的原生视图（iOS UiKitView，由 mkxp 插件提供）。
/// M0：原生侧返回一个黑色 UIView；M1 接入引擎后渲染 RPGXP 画面。
class GameView extends StatelessWidget {
  const GameView({super.key});

  @override
  Widget build(BuildContext context) => const UiKitView(
        viewType: 'mkxp-game-view',
        creationParams: <String, dynamic>{},
        creationParamsCodec: StandardMessageCodec(),
      );
}
