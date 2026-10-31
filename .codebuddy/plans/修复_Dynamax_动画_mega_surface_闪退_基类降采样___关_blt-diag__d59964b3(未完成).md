---
name: 修复 Dynamax 动画 mega surface 闪退（基类降采样 + 关 blt-diag）
overview: 根因：Dynamax/变身动画给战斗宝可梦精灵 MosaicBattlerSprite#bitmap= 赋一张超过 iOS GPU maxTexSize 的位图，MKXP 将其做成 mega surface（仅内存、禁止 Sprite/Plane 使用），其 Sprite#bitmap= 的 GUARD_MEGA 抛 MKXPError → 被 execute_script 包成 EventScriptError → 游戏崩。修复为在引擎注入层对基类 Sprite#bitmap= / Plane#bitmap= 统一拦截，赋值前把 mega/超尺寸位图降采样到 maxTexSize 内（512x384 画面、精灵实际~100px，视觉无损），覆盖所有精灵与地图/战斗背景，根治"下次又来"。同时关闭 framework-entry.patch 中查横线 Bug2 时遗留、未关闭的 blt-diag stderr 洪水（地图加载期同步写会阻塞引擎线程，是 c0ce727 那次"地图闪退"的元凶）。基于 dcf87a5。
todos:
  - id: patch-mega-rb
    content: 在 ios_hook.rb 给基类 Sprite/Plane#bitmap= 加 mega 位图降采样拦截（根治覆盖所有精灵与背景）
    status: completed
  - id: disable-bltdiag
    content: 关闭 framework-entry.patch 的 blt-diag 残留诊断，消除地图加载期 stderr 洪水
    status: completed
  - id: commit-push
    content: 提交并推送到 dcf87a5 之上触发 CI 重建
    status: completed
    dependencies:
      - patch-mega-rb
      - disable-bltdiag
  - id: verify-build
    content: 侧载新构建复现 Dynamax/变身与地图，验证无 EventScriptError 且战斗可打完
    status: in_progress
    dependencies:
      - commit-push
---

## 用户需求

- 修掉 Dynamax/变身动画的闪退真因，让游戏**不再 error**（不是"出错后继续跑"，是根本不出错）。
- 要**根治**：覆盖所有精灵与背景（战斗宝可梦、地图行走图、跟随精灵、战斗背景、地图滚动平面等），不再逐个子类打补丁，避免"下次又来"。
- 按源码改，不改动游戏 Plugins 文件（sp4 不受影响），保持此前已验证可用的降采样逻辑。

## 产品概述

在 iOS 真机上，超尺寸宝可梦精灵位图（超过 GPU 最大纹理尺寸）被 MKXP 做成 mega surface（仅内存、禁止 Sprite/Plane 使用），Dynamax/变身动画给 `MosaicBattlerSprite#bitmap=` 赋值时命中 `GUARD_MEGA` 抛 `MKXPError`，被脚本层 `execute_script` 包成 `EventScriptError` 导致战斗崩。PC 端 RMXP 无纹理尺寸上限故正常。

## 核心功能

- 引擎注入层对基类 `Sprite#bitmap=` 与 `Plane#bitmap=` 统一拦截：赋值前若位图是 mega 或超过 2048px，先降采样到 2048 内（低于所有 iOS 设备 maxTexSize≥2048，512×384 画面、精灵实际约 100px 视觉无损）再存储，覆盖全部显示对象。
- 关闭 `framework-entry.patch` 中查"横线 Bug2"遗留、未关闭的 `blt-diag` stderr 诊断洪水（地图加载期海量 tilemap blit 同步写日志会阻塞引擎线程，是 c0ce727 那次"还没进地图就闪退"的元凶）。
- 保留 `dcf87a5` 的 `[mkxp-ess]` 根因探针（无害，仅出错打一行）以便后续验证。

## 技术栈

- 引擎注入层：Ruby（`scripts/mkxp-framework/ios_hook.rb`），在 MKXP 启动时通过 `method_added`/启动钩子给 RGSS 类打补丁。
- 引擎 C++ 层：`scripts/mkxp-framework/framework-entry.patch`（mkxp-z 源码补丁），关闭残留诊断。
- 平台：iOS（Metal-GL 软呈现），GPU maxTexSize 通常 ≥2048。

## 实现方案

### 总体策略

在 RGSS 基类 `Sprite` 与 `Plane`（RGSS 中仅这两个显示对象带 `bitmap=`）的 `bitmap=` 上包一层：赋值前检测位图是否 mega/超尺寸，若是则降采样为普通位图再存入。这样所有精灵与背景平面在赋超尺寸位图时都被透明降采样，彻底绕开 mega surface 限制，且只发生一次（512×384 下视觉无损）。

### 关键技术决策

1. **基类级覆盖**：此前 `b8ee694` 只补 `MosaicBattlerSprite` 一个子类（打地鼠），`c0ce727` 已升级到基类 `Sprite`/`Plane` 且逻辑验证可用，本次沿用该正确方向（用户回滚只是因另一处 `blt-diag` 干扰，并非降采样逻辑本身有问题）。
2. **判定优先用 `Bitmap#isMega`**：精确命中 MKXP 的 mega surface（`p->megaSurface != NULL`），其绑定在 mkxp-z 中已存在；若无该 API 则退回 `v.width>2048 || v.height>2048` 兜底，阈值 2048 低于所有 iOS maxTexSize。
3. **降采样用 `stretch_blt`**：已读 `framework-entry.patch` 中 `Bitmap::stretchBlt`（3793–3873 行）实现——mega 源走 `source.megaSurface()` 的 RAM 路径（PATH=B/C，`SDL_BlitScaled`+`uploadSubImage`），**安全处理 mega 源，不依赖无效的 `gl.tex`**，故 `nb.stretch_blt(Rect.new(0,0,nw,nh), v, v.rect)` 对 mega 位图安全。`Bitmap#rect()`（3675+）仅 `guardDisposed`，对 mega 取 `v.rect` 亦安全。
4. **关闭 `blt-diag`**：`static int bltDiagN; bool bltDiag=(bltDiagN++ < 3000);` 改为恒 `false`（或阈值 0），消除前 3000 次 blit 的同步 stderr 写，避免地图加载期引擎线程被阻塞。

### 性能与可靠性

- 降采样仅对超过 2048px 的位图触发，512×384 画面绝大多数精灵不触发，零常态开销；启动期一次性 `alias`/`define_method` 包好，运行期仅多一次尺寸判断。
- `blt-diag` 关闭后，stderr 不再洪水，地图加载/瓦片合成不再阻塞。
- 补丁置于 `mainFunctionDebug` 包裹里启动期执行，并用哨兵变量 `($__mkxp_mega_fixed)` 防重复包装；`rescue StandardError` 包裹失败仅打日志，不影响游戏启动。

### 实现注意事项

- 不改动游戏 Plugins 文件（`[006] Battler Sprites.rb` 等），符合"别改坏 sp4"。
- `alias_method :__mkxp_orig_bitmap_set, :bitmap=` 捕获 C++ 原生方法，`define_method` 包裹层内部调用 `__mkxp_orig_bitmap_set(v)` 存降采样后的普通位图，原子类（如 `MosaicBattlerSprite#bitmap=` 内的 `super`）仍走该包裹层，链路闭合。
- 提交基于当前 `main = dcf87a5`（保留 `[mkxp-ess]` 探针）。

## 架构设计

- 显示对象赋值统一兜底层：`Sprite#bitmap=` / `Plane#bitmap=` →（注入层拦截：mega/超尺寸→降采样）→ 原生 C++ `bitmap=`（GUARD_MEGA 永不再命中）。
- 引擎诊断层：`blt-diag` 开关关闭，日志恢复干净。
- 两者互不耦合，各自独立、可常驻。

## 目录结构

```
scripts/mkxp-framework/
├── ios_hook.rb              # [MODIFY] __mkxp_patch_mega_bitmap：在基类 Sprite#bitmap= 与 Plane#bitmap= 包一层，
│                           #   赋值前对 isMega 或尺寸>2048 的位图用 Bitmap.new(nw,nh)+stretch_blt 降采样到 2048 内再存；
│                           #   启动期一次性执行（mainFunctionDebug 包裹内），哨兵防重复，不改动游戏 Plugins 文件。
└── framework-entry.patch   # [MODIFY] 将 bitmap.cpp 中 static bool bltDiag=(bltDiagN++ < 3000) 改为恒 false（关闭残留诊断），
                            #   消除地图加载期海量 tilemap blit 的 stderr 同步写洪水，避免阻塞引擎线程导致"地图闪退"。
```

## 关键代码结构（修复核心，Ruby 注入层）

```
# ios_hook.rb —— 基类 Sprite/Plane#bitmap= mega 降采样根治
def __mkxp_patch_mega_bitmap
  return if $__mkxp_mega_fixed
  [[:Sprite, defined?(::Sprite) ? ::Sprite : nil],
   [:Plane,  defined?(::Plane)  ? ::Plane  : nil]].each do |_, k|
    next unless k
    next if k.method_defined?(:__mkxp_orig_bitmap_set)
    k.send(:alias_method, :__mkxp_orig_bitmap_set, :bitmap=)
    k.send(:define_method, :bitmap=) do |value|
      v = value
      if v.is_a?(Bitmap) &&
         (v.respond_to?(:isMega) ? v.isMega : (v.width > 2048 || v.height > 2048))
        nw = [v.width, 2048].min; nh = [v.height, 2048].min
        nb = Bitmap.new(nw, nh)
        nb.stretch_blt(Rect.new(0, 0, nw, nh), v, v.rect)
        v = nb
      end
      __mkxp_orig_bitmap_set(v)
    end
  end
  $__mkxp_mega_fixed = true
end
```