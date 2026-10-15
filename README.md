# RPG XP / Pokémon Essentials 21.1 iOS 启动器（自用）

用 **Flutter** 做界面外壳，内嵌 **MKXP-Z** 引擎（C++/SDL2 的 RGSS 重实现）在 iPhone 上运行
**Pokémon Essentials 21.1**（RPG Maker XP / RGSS1）。

**你的情况**：没有 Mac、没有黑苹果。所以——
- 编译：交给 **GitHub Actions 云端 macOS**；
- 安装：用 **Sideloadly + 免费 Apple ID** 侧载到 iPhone，每 7 天重签一次；
- 仅自用，不上架。

---

## ⚠️ 当前进度（M1 进行中）

**M0 已完成**：SDK 流水线打通（Flutter 壳 + mkxp 插件 + 云构建 + 侧载），真机可跑、日志页可读 bootstrap 日志。

**M1 进行中**：把 MKXP-Z 编译成 iOS 静态库 `libmkxp.a`，再合并成 `MKXP.framework` 接入插件。

> 关键背景：上游 mkxp-z 早已**放弃 CMake / macOS / iOS**（根目录只剩 `meson.build`，且第一行就
> `error('...no longer supports macOS')`）。所有近期 tag（v2.2.3→v2.4.2）都是 Meson + wrap 子项目。
> 因此我们没有去适配它那套 Meson，而是**手搓 CMake**（`scripts/mkxp-cmake/CMakeLists.txt`）
> 直接编译 v2.4.2 的 `src/ + binding/ + shader/ + assets/` → 静态库，按上游 `meson.build`
> 还原源清单、include 目录、编译宏（`GLES2_HEADER` 走 GLES、`SDL2_sound`+vorbis/theora 走音频）
> 和 xxd 嵌入。

### 已跑通的子步骤
- **MRI Ruby 3.3.12 静态库**：`libruby.3.3-static.a` 链接成功 + 头文件已 staged（交叉编译最难的一块已过）。
- **vcpkg 静态依赖**：改用自定义静态 triplet `arm64-ios-static`（动态 `arm64-ios` 产出 `.framework/.dylib`，
  无法被 `libtool -static` 合并进框架）。
- **SDL2_sound 源码交叉编译**：vcpkg 无此端口，且 `icculus/SDL_sound` 的 `main` 已升级 SDL3，
  故固定编其 `v2.0.6`（产出 `libSDL2_sound.a`，正好对上 mkxp-z v2.4.2 要的 SDL2 版）。

### 当前卡点（按 CI 日志迭代）
正在过「手搓 CMake configure → 编 mkxp-z C++」这一关。两个前置炸弹已修，下一轮 CI（`ffc7dfa`）待验证：
1. `find_library(SDL2)` 太脆 → 改成递归 glob `lib<name>.a` + framework 主二进制，并加了诊断输出
   （configure 与 vcpkg 装完两处都 dump 安装目录）。
2. xxd 嵌入三处错（符号名 `___shader_*` / 文件名 `.xxd` / 重复符号）→ 已用 `file(RELATIVE_PATH)`
   取相对构建目录路径、输出改名 `.xxd`、并把 `.xxd` 移出编译源（改由自定义目标驱动生成）修复。

### 嵌入方式决策（已定）
mkxp-z 是独立 app、**不是可嵌入库**——它永远自己 `SDL_CreateWindow`，无 `SDL_CreateWindowFrom` /
`SDL_WINDOW_EXTERNAL`，也无 iOS UIView 嵌入代码，只导出标准 `int main()`。游戏画面进 Flutter 采用
**「SDL 自建全屏窗口 + Flutter 透明浮层」**：mkxp-z 跑全屏 SDL 窗口，Flutter 游戏页只承载圆环摇杆 /
动作键并转发 RGSS 键码。`mkxp_run(gamePath)` 在后台线程启动引擎（原 `eventThread.process()` 会阻塞）。
已放弃原计划的 `UiKitView` 内嵌（需在 `SDL_CreateWindow` 后把 SDL 原生 UIView 重挂，属 hack、本机不可验证）。

### 预期接下来的深水区
- mkxp-z 真实 C++ 编译：GLES2 后端在某 iOS SDK 上的兼容、iOS 缺失的 POSIX API（`system()`/`vm_dump` 等）、
  openal-soft 的 `ALCdevice` 结构体名（已传 `-DMKXPZ_ALCDEVICE=ALCdevice`）。
- `main.cpp` 里的 `int main()` 最终链接进 Flutter App 会冲突 → 届时把 `main` 重构成 `mkxp_run(gamePath)`。
- 桥接层 `MkxpBridge` + Flutter 游戏页从 `UiKitView` 改为透明浮层。

---

## 仓库结构

```
pubspec.yaml            # App 配置（依赖本地 mkxp 插件）
lib/                    # Flutter 源码（main.dart / services / widgets）
mkxp/                   # 原生桥接插件（iOS 自动集成，免改 Xcode 工程）
  ios/Classes/          #   Swift：MkxpPlugin / MkxpPlatformView / MkxpLog
  ios/mkxp.podspec      #   编译 Classes 下所有 Swift，M1 再 vendored MKXP.framework
scripts/build_mkxp_ios.sh   # MKXP-Z 编译脚本（M1 用，M0 未接入）
.github/workflows/ios.yml   # 云构建工作流
```

> 说明：仓库**不含** `ios/` 平台工程，它由 CI 的 `flutter create` 自动生成，再把 `lib/`、
> `pubspec.yaml` 还原、用 `flutter pub get` 集成 `mkxp/` 插件后编译。你本地不需要 Mac。

---

## 本地需要装的东西（Windows）

1. **Git** + 一个 **GitHub** 账号。
2. **Sideloadly**（Windows 版，https://sideloadly.io/ ）+ **iTunes**（提供 USB 驱动）。
3. 一个**普通 Apple ID**（免费即可）。
4. （可选）Flutter SDK：仅用于本地 `flutter analyze` 检查 Dart 代码；不装也能用 CI 出包。

你**不需要** Xcode、不需要 Mac。

---

## 第一次出包 & 侧载（之后每次都一样）

### 1. 推代码
```bash
git add -A
git commit -m "M0 流水线验证"
git push
```

### 2. 等云端编译
到 GitHub 仓库 → **Actions** → 找到 `iOS Build` 任务 → 等它变绿（首次约几分钟到十几分钟，
取决于 macos runner 排队）。

### 3. 下载 IPA
任务详情最下方 **Artifacts** → 下载 `rpgxp-loader-ipa`（得到 `app.ipa`）。

### 4. 侧载到 iPhone（Windows 上操作）
1. iPhone 连电脑，打开 **Sideloadly**；
2. 把 `app.ipa` 拖进去，填你的 Apple ID，点 **Start**；
3. iPhone 上：`设置 → 通用 → VPN与设备管理 → 信任开发者`；
4. 桌面打开 App，即可看到运行（M0 是黑色视图 + “读取原生日志”按钮）。

### 5. 每 7 天重签
免费 Apple ID 侧载的应用 7 天后失效。重签很简单：重新用 Sideloadly 跑一次第 4 步即可
（或开启 Sideloadly 的“自动重签”需手机连电脑）。付费开发者账号可免此限制。

---

## 调试（无 Mac 的代偿方案）

没有 Xcode 控制台，所以：
- 原生侧会把关键日志写入 App 沙盒的 `Documents/mkxp.log`；
- Flutter 后续会有「日志页」读取它（M0 已可通过主界面“读取原生日志”按钮查看 bootstrap 日志）。

真机跑起来后，所有报错都去这个日志里看，再贴给开发侧迭代。

---

## 路线图

- **M0（当前）**：最小 Flutter App + UiKitView + mkxp 插件 + 云构建 + 侧载链路验证。✅
- **M1（进行中）**：MKXP-Z iOS 交叉编译（MRI Ruby + SDL2/SDL2_sound/theora/vorbis + OGG/WAV），
  产出 `MKXP.framework`；**嵌入方式定为「SDL 全屏窗 + Flutter 透明浮层」**，`mkxp_run(gamePath)`
  在后台线程启动引擎，Flutter 游戏页只做透明控件层（放弃原 `UiKitView` 内嵌）。
- **M2**：游戏库扫描、Zip 导入解压、虚拟摇杆+动作键（按 Essentials 键位）、设置页、日志页。
- **M3**：依据 CI 日志与真机 `mkxp.log` 迭代修复引擎兼容/音频/触摸问题。

---

## 你的游戏放哪（M1 起）

你的 Essentials 21.1 工程（含 `Game.ini`、`Data/`）后续通过 App 内“导入”解压到
`Documents/games/<游戏名>/`。M0 暂不需要放游戏。
