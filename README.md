# RPG XP / Pokémon Essentials 21.1 iOS 启动器（自用）

用 **Flutter** 做界面外壳，内嵌 **MKXP-Z** 引擎（C++/SDL2 的 RGSS 重实现）在 iPhone 上运行
**Pokémon Essentials 21.1**（RPG Maker XP / RGSS1）。

**你的情况**：没有 Mac、没有黑苹果。所以——
- 编译：交给 **GitHub Actions 云端 macOS**；
- 安装：用 **Sideloadly + 免费 Apple ID** 侧载到 iPhone，每 7 天重签一次；
- 仅自用，不上架。

---

## ⚠️ 当前进度（M0）

本仓库当前是 **M0：流水线验证版**。它能在 iPhone 上跑起来、证明
`推送 → 云端编译 → 下载 IPA → 侧载 → 真机` 整条链路是通的，但**还没有接入游戏引擎**
（画面是一个黑色原生视图，日志页能读到启动日志）。

下一阶段（M1）才会把 MKXP-Z 编译进 App 并跑通 Essentials 21.1 的画面与声音。

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
- **M1**：MKXP-Z iOS 交叉编译（MRI Ruby 绑定 + SDL2/SDL_mixer + OGG/WAV），接入插件 framework，
  在 UiKitView 里硬编码启动你的 Essentials 21.1，验证画面+声音。
- **M2**：游戏库扫描、Zip 导入解压、虚拟摇杆+动作键（按 Essentials 键位）、设置页、日志页。
- **M3**：依据 CI 日志与真机 `mkxp.log` 迭代修复引擎兼容/音频/触摸问题。

---

## 你的游戏放哪（M1 起）

你的 Essentials 21.1 工程（含 `Game.ini`、`Data/`）后续通过 App 内“导入”解压到
`Documents/games/<游戏名>/`。M0 暂不需要放游戏。
