import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// MKXP 游戏画面层（M1 起）。
///
/// 嵌入方案（最终定版）：mkxp-z 依旧自己 `SDL_CreateWindow` 全屏渲染，但引擎在
/// 建窗后会把 SDL 的渲染视图【搬进】这里 `UiKitView` 提供的宿主 UIView
/// （见 scripts/mkxp-framework/ios_embed.mm 的 mkxp_ios_setHostView + mkxp_ios_embedIntoView）。
/// 这样画面就在 Flutter 真正可见的 PlatformView 里出像素，虚拟摇杆/动作键等 Flutter
/// 控件再叠在上面。
///
/// 注意：MkxpPlatformView.init 创建宿主 UIView 时会调用 mkxp_ios_setHostView 注入指针，
/// 所以本 Widget 必须真实挂载到游戏页（不能是无 UiKitView 的透明占位），否则引擎
/// 拿不到宿主、画面进不到可见层级（日志会打 “host view not set”）。
class GameView extends StatelessWidget {
  const GameView({super.key});

  @override
  Widget build(BuildContext context) {
    const viewType = 'mkxp-game-view';
    return const UiKitView(
      viewType: viewType,
      creationParams: <String, dynamic>{},
      creationParamsCodec: StandardMessageCodec(),
    );
  }
}
