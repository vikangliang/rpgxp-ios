# HANDOFF — MKXP-Z iOS 构建接力

> 本文件专门写给「接手继续云编译」的会话/人。AI 记忆**不随仓库走**，所以把接力上下文写在这里。

## 当前状态（2026-10-20，更新于 `d55c23d`）

> 里程碑盘点：

| 里程碑 | 状态 | 说明 |
|---|---|---|
| M0 流水线 | ✅ | Flutter 壳 + mkxp 插件 + 云构建 + 侧载，IPA 可出 |
| M1 编译/框架化 | ✅✅✅ | 双 workflow 全绿；`MKXP.framework` 含引擎；12 编译坑 + 6 链接坑全填平 |
| M1 真机首测（闪退） | ✅ 已修 | 装包/壳/桥接/链接全通；点启动闪退 → `625cbd5` 派发到主线程修掉 |
| M2 阶段一（导入+启动链路） | ✅ | 文件选择器/ZIP 导入/游戏库/启动·删除/日志对话框/透明浮层就位 |
| M2 阶段二（触摸浮层/设置/日志/详情页） | ✅ 已完成 | 原生 `MkxpTouchOverlay`（圆环摇杆+2×2 键直调 mkxp_key）、五页 UI、游戏详情页、退出菜单 |
| **M2 关键 Bug：启动后无画面** | ✅ 已修已验 | 点启动卡「正在启动」/无画面 → `15ab649`+`baa3646` 循环甩后台线程；真机已出画面（M3 在其上继续调） |
| M3 真机调通 + 四运行时修复 | 🔧 基本完成 | ①BGM自愈 ③解码缓存 已修；EventScriptError(has_follower)已根治；②撕裂 glFinish 修复已实现、待真机验证(d55c23d)；④消息框少字定位中(上游脚本切片)。当前 `d55c23d` CI 双绿 |

- 最新提交：`32918a4`（M3：has_follower 改 public，根治 EventScriptError 弹窗）。M3 真机调通 + 四运行时修复（BGM/撕裂/加载/文本）均已完成、构建冲突已修通；完整细节见文末「CI 链复盘 + 全项目根因总表」。自 `8eac281` 起进入 M3 真机调通：黑屏无声三连修、
  UIKit 崩溃根治（`MKXPZ_IOS_EMBED` 守卫）、GL 上下文回主线程、zlib LoadError 根治、sdl2-image JPEG、
  Ruby GC 调优、脚本加载打点。其前 `baa3646` 及更早均双 workflow 全绿；**拉取后仅 `.vscode/` 未跟踪**
  （编辑器目录，可忽略，不影响构建）。
- **M0 流水线 ✅**（Flutter 壳 + mkxp 插件 + 云构建 + 侧载，IPA 可出）。
- **M1 全部完成 ✅✅✅**（`625cbd5` 起双 workflow 全绿）：
  - `MKXP.framework`：核心 = libmkxp + 静态 Ruby + SDL2_sound（`-force_load` 全量载入）；
    vcpkg 依赖在 `MKXP.framework/Libs/*.a` **按需加载**（去重，见坑 #18）；
  - `rpgxp-loader-ipa` **12.26MB**（M0 时约 7.5MB，差额 = 引擎 + 4.5MB CJK 字体），
    即 IPA 已含引擎；App 侧桥接（launch/quit/key）与透明浮层均已就位；
  - 编译期十二坑（#3/#6-#12）+ 链接期六坑（#13-#18）全填平。
- **M1 真机验证（已完成）**：Sideloadly 装包 → 填游戏目录（如 `games/Essentials`）→
  点「启动引擎」→ 看 `mkxp.log`（主界面有 启动/关机/读取原生日志 三按钮 + 目录输入框）。
  **真机首测（2026-10-16）**：装包/Flutter 壳/桥接/链接全通，但**点启动即闪退**——
  根因：引擎整体跑后台 `std::thread`，SDL2 的 iOS 后端（UIWindow/CAEAGLLayer/UIKit
  事件泵）只支持主线程。已修于 `625cbd5` 后的 `mkxp_framework.cpp`（`dispatch_async`
  派发到主线程、立即返回）。若再崩，取 iPhone 设置→隐私→分析与改进→分析数据里最新的
  `rpgxpLoader-*.ips` 崩溃日志定位。
- **M2 关键 Bug（已修，CI 绿待真机验，`15ab649`+`baa3646`）**：闪退修掉后**点启动卡在「正在启动」、
  永远不出现游戏画面**。根因：`EventThread.process()` 这个阻塞事件循环在主线程永不退出，占死
  iOS 主线程 run loop → Core Animation 无法上屏（画面冻在 Flutter 浮层）。`15ab649` 把
  SDL 初始化+建窗+起 RGSS 线程留在主线程（UIKit 安全，后台线程 SDL_Init/CreateWindow 会崩），
  **阻塞事件循环与终止清理挪到后台 `std::thread`**，`mkxp_z_main` 立即返回 → 主线程 run loop
  恢复、画面才上得去。`15ab649` 编译期曾因 `RGSSThreadData(EventThread*, ...)` 实参误写成解引用
  `*evThread` 报错，`baa3646` 改回传指针后双 workflow 全绿——**IPA 已可侧载真机验证**。
- 游戏文件目前只能经 Finder 文件共享进入沙盒（`UIFileSharingEnabled` 尚未开，需的话 CI 加 patch）。
- 已跑通的子步骤（CI 已验证）：
  - MRI Ruby 3.3.12 静态库 `libruby.3.3-static.a` + 头文件 staged；
  - vcpkg `arm64-ios-static` 静态 triplet 编出全部 C 依赖；
  - `SDL2_sound` v2.0.6 源码交叉编译出 `libSDL2_sound.a`；
  - mkxp-z v2.4.2 编译 + 框架化入口 `mkxp_run/mkxp_key/mkxp_quit`（M1-A）。

## M2 进度（2026-10-16 起，已全部完成 ✅）

**阶段一（导入+启动链路）✅**：`file_picker`/`archive`/`path_provider`；`game_library.dart` 扫描
`Documents/games/`（顶层含 Game.ini 即一个游戏）、Zip 导入（自动定位游戏根，兼容直铺/套一层，
跳过 `__MACOSX`/`.DS_Store`/`._*`）、删除；`Mkxp.launchGame` 透出错误（含 mkxp_run 返回码含义）。

**阶段二（界面功能）✅**：全部做完——
- 完整 UI 五页：`lib/screens/` 下 `library`（游戏库列表 + 启动/删除 + 导入 + 刷新）/
  `import`（解压进度条，按未压缩字节计进度 + 当前文件名）/ `log_view`（读 `mkxp.log`）/
  `settings`（设置 + `app_settings.dart`）/ `game_detail`（点列表先进详情，点"开始游戏"才启动）/
  `game_run`（运行页）；
- 原生触摸浮层 `mkxp/ios/Classes/MkxpTouchOverlay.swift`：圆环摇杆 + 2×2 动作键，直调 `mkxp_key`
  （解决 SDL 全屏窗吞触摸，不依赖 Flutter 主线程）；
- 游戏内退出菜单、真实图标、游玩时长、`SDL_HINT_ORIENTATIONS` 横屏 hint。

## M3 进度（2026-10-16 起，真机调通 ✅ + 四运行时修复 ✅；④消息框少字定位中 🔧）

M2 无画面修好后上真机，暴露一连串 iOS 实测问题，已连环修复（提交均带 `m3` 前缀）：

- **黑屏无声三连修**（`f4f36a1`）：① 引擎 C++/Ruby 日志重定向到 `Documents/mkxp.log`
  （`mkxp_framework.cpp` 里 `freopen` stdout/stderr，App 内日志页可读，是无 Mac 的唯一调试通道）；
  ② AVAudioSession 激活挪后台；③ 后台线程 `SDL_ShowSimpleMessageBox` 不安全 → 改为只写日志。
- **UIKit 崩溃根治**（`2c011f0`）：`EventThread::process` 跑在后台线程，而窗口操作（SETFULLSCREEN/
  WINRESIZE/WINREPOSITION/WINCENTER/WINRENAME/标题设置）会改 UIKit 视图 → 后台线程碰 UIKit 必崩
  `NSInternalInconsistencyException: Call must be made on main thread`（Essentials 的
  `Graphics.resize_screen` 必踩）。`framework-entry.patch` 的 `eventthread.cpp` 加 `MKXPZ_IOS_EMBED`
  守卫，这些操作在嵌入模式全部吞掉（窗口固定全屏，内部分辨率由 RGSS 线程 `Screen.setResolution` 调）。
- **GL 上下文回主线程**（`0909989`）：实测崩溃栈直指 `SDL_GL_CreateContext@rgssThread` ——
  GL 上下文创建必须主线程，已从 rgssThread 挪回（与 `MKXPZ_INIT_GL_LATER` 的处理配合）。
- **zlib LoadError 根治**（多轮：`31912ba`→…→`cee6bd0`→**`rb_provide_feature` 正解**）：
  真机 `require 'zlib'` 报 LoadError。`dlsym Init_zlib` + `$LOADED_FEATURES<<'zlib'` 都救不了
  （`require` 先按 `$LOAD_PATH` 找文件、找不到即 LoadError，根本不查 loaded features；dlsym 又脆弱）。
  **正解**（`binding-mri.cpp` 的 `mriBindingInit`）：若 `!const_defined?(:Zlib)` 直接 `Init_zlib()`
  定义模块 + `rb_provide_feature(rb_str_new_cstr("zlib"))` 把 feature 正式登记，此后 `require 'zlib'`
  直接成功。`Init_zlib`/`rb_provide_feature` 都在 `libruby-static.a`（`-force_load` 全量载入），
  `extern "C"` 声明后直接调用即可。`mkxp_framework.cpp` 的 `used` 锚点 `zlib_ext_anchor` 仍保留
  （强制保留 `Init_zlib`，无害）。详见坑 #21。
- **sdl2-image JPEG**（`a3584d5`）：真机日志 `'JPEG images are not supported'` → vcpkg `sdl2-image` 启用 JPEG 特性。
- **Ruby GC 调优**（`05a6dd0`）：iOS 无 JIT，Ruby 纯解释执行；Essentials 启动期解释 1MB 脚本、定义上万对象，
  默认 GC 阈值触发海量 GC 是启动慢主因。在 `ruby_init` 前 `setenv` 放大 `RUBY_GC_HEAP_INIT_SLOTS`(2M)/
  `GROWTH_FACTOR`(2.0)/`MALLOC_LIMIT`(256M)/`OLDMALLOC_LIMIT`(256M) 等。
- **脚本加载打点**（`3ee2341`/`7abee44`）：`binding-mri.cpp` 加 `[stage]`/`rgss: N/t=...ms` 时间戳，
  区分"慢"与"卡死"（inflate/exec 每 50-100 段打点）。
- **CI**：iOS 打包并入 `build-mkxp.yml`（build-ios job，`4697b13`），失败/成功状态发布改用可写 `GITHUB_TOKEN`
  （`4959966`）；`build-mkxp.yml` 增 ~146 行、`ios.yml` 微调。`vcpkg install` 加 `--recurse`（`3597acd`）。

## 环境要求

### 本地（另一台电脑）——只需能推代码，其余全在云端
- **git**：任意安装路径，配置好能 `push` 到本仓库即可（HTTPS 凭据或 SSH key）。
  Windows 上 git 不一定在 PATH，常见位置 `C:\Program Files\Git\cmd\git.exe`、
  `C:\src\git\cmd\git.exe`，找不到时用 `Get-Command git` 定位后把其目录加进 `$env:PATH`。
- **网络**：能访问 github.com（拉取 + 触发 Actions）。
- **仓库远程**：默认 `origin` 指向 `github.com/vikangliang/rpgxp-ios`（`push` 到 `main` 即触发 CI）。
- （可选）**Flutter SDK**：仅用于本地 `flutter analyze` / `flutter test` 自检 Dart 代码；
  iOS 编译**不能**在本地做（无 Mac），必须在 CI。Windows 装 Flutter 即可跑 analyze。
- 编辑器/AI：用任意编辑器改 `scripts/`、CMake、Dart 文本即可，**无需本地编译任何原生代码**。

### 云端 CI（GitHub Actions `macos-15`）——真正的构建环境
- macOS 15 runner，默认 Xcode 16.4（自带 iPhoneOS SDK、Apple clang 17）。
- Homebrew 已预装；脚本内 `brew install` 补：`cmake ninja automake libtool pkg-config bison xxd`。
- `ruby@3.3`（3.3.12）已预装，作 MRI Ruby 交叉编译的引导器。
- 其余全部由脚本自动 clone + 编译，**无需预装**：
  - MRI Ruby 源码（交叉编 `libruby-static.a`）
  - vcpkg + 全部 C 依赖（`arm64-ios-static` 静态 triplet）
  - `SDL2_sound` v2.0.6（源码交叉编译）
  - mkxp-z v2.4.2（手搓 CMake 编 `libmkxp.a`）
- 缓存：workflow 用 `actions/cache` 缓存 `deps/vcpkg/installed` 与 `deps/ruby-ios`，
  命中即跳过重建（改脚本 / triplet 时 key 会变而失效）。

> 结论：另一台电脑**不需要 Mac、不需要 Xcode、不需要 vcpkg/Ruby**；只要 git 能 push，
> 剩下的全交给 CI。唯一会随机器变的是 git 的可执行路径与凭据。

## 怎么触发云编译

- `push` 到 `main` 会**同时**触发：
  - `build-mkxp.yml`：编 `MKXP.framework`，上传 artifact（`MKXP-framework` / `mkxp-build-log`）；
  - `ios.yml`：编 M0 App 的未签名 IPA（`rpgxp-loader-ipa`）。
- 接手动作：本机 `git pull` → 改 `scripts/` 或 `CMakeLists.txt` → `commit && push`，CI 自动跑。
- 看日志：GitHub → Actions → 对应 workflow run → 下载 artifact（尤其 `mkxp-build-log`）。
- **免 token 看状态（关键，接手者只读这两个分支即可，无需截图/登 GitHub）**：
  - `build-mkxp.yml` 永远把跨归档符号冲突报告推到 `ci-status` 分支的 `ci-status/last-collisions.md`
    （`COLLISION_COUNT` 是预期的重复符号，已被「核心 force_load + 依赖按需加载」消化，非致命）；
    **仅失败时**额外推 `ci-status/last-failure.md`（错误行 + 日志尾部）。
  - `ios.yml` 现已 `always()` 把构建状态推到 `ci-status-ios` 分支的 `ci-status/last-failure.md`
    （成功写 `# iOS build success`，失败写 `# iOS build failure` + 重复/未定义符号聚合 + 日志尾部）。
  - 本地读取（公开仓库免登录）：`git fetch origin ci-status ci-status-ios`，再
    `git show origin/ci-status:ci-status/last-collisions.md` /
    `git show origin/ci-status-ios:ci-status/last-failure.md`；
    用里面的 `commit: <sha>` 对上自己推送的提交，即知是否轮到本次、绿还是红。
  注意 `git fetch origin ci-status ci-status-ios` 中若某分支尚不存在会整条报错，
  需**分开 fetch**（如本机另写 `get-ci.ps1` 逐个拉取并容错）。
- **iOS 失败摘要需要 PAT（重要）**：`ios.yml` 由 `workflow_run` 触发，拿到的 `GITHUB_TOKEN` 是
  **只读**的，`git push` 到 `ci-status-ios` 会被拒（摘要步骤也会因此崩）。已在 `ios.yml` 的
  Publish 步骤改用仓库 Secret **`CI_PUSH_TOKEN`**（fine-grained PAT，仅本仓库、Contents: RW）推送；
  无该 Secret 时退回 `GITHUB_TOKEN` 并 `continue-on-error` 容忍失败。**接手者必须先建这个 Secret**
  才能自动读到 iOS 失败摘要——否则只能去 Actions 页面手动看日志。建法：GitHub → Settings →
  Developer settings → Fine-grained tokens → 生成（Repository access 选 rpgxp-ios，Contents: RW）→
  复制 → 仓库 Settings → Secrets and variables → Actions → New secret：`CI_PUSH_TOKEN`。
  **注意**：重跑一个基于旧提交的失败 run 不会带上后续提交的修复，必须在一个含修复的提交上跑。

## 已踩的坑（别再踩）

1. **`find_library(SDL2)` 太脆** → `scripts/mkxp-cmake/CMakeLists.txt` 的 `find_mkxp_lib`
   改为**递归 glob** `lib<name>.a` + framework 主二进制，并在 configure 与 vcpkg 装完两处都
   dump 安装目录（`VCPKG_INSTALL` / `DEP_LIB` 下的 `.a` 清单）。
2. **xxd 嵌入三处错** → 同一 CMakeLists：
   - 符号名：用 `file(RELATIVE_PATH)` 取**相对构建目录**路径 `../shader/xxx` 再 `xxd -i`，
     产出 `___shader_*` / `___assets_*`（3 个下划线），而非传绝对路径得到的 `_Users_runner_...`；
   - 文件名：输出必须是 `*.xxd`（源码是 `#include "simple.frag.xxd"`），原写成 `.c`；
   - 重复符号：`.xxd` 被 `shader.cpp/main.cpp/eventthread.cpp/font.cpp` 直接 `#include`，
     **绝不能**加进 `add_library` 源列表，改由自定义目标 `mkxp_embed_xxd` 驱动生成，`gen/` 加进 include。
3. **`MKXPZ_PLATFORM` 误判 macOS** → `build_mkxp_ios.sh` 用 `sed` 把
   `src/system/system.h` 里的 `MKXPZ_PLATFORM_MACOS` 改成 `MKXPZ_PLATFORM_LINUX`
   （仅 `-D` 不够：源文件里的 `#define` 后定义会覆盖命令行）。
4. **Ruby iOS 交叉编译**：
   - iOS 上 `system()` 标 unavailable，`vm_dump.c` 无宏守卫 → `sed` 改 `system(buf)`/`system(cmd)` 为 `0`；
   - 用 runner 原生 `ruby@3.3` 作 MINIRUBY/BUILTRUBY/PREP 引导；
   - `--with-static-linked-ext`，只 `make libruby.3.3-static.a`（绕过 Ruby 3.3 可执行链接把 Makefile 当目标的坑）；
   - `ulimit -s 65536` 防内建字节码编译栈溢出。
5. **`SDL2_sound`**：vcpkg 无此端口且其 `main` 已升 SDL3 → 固定源码编 `icculus/SDL_sound` 的 `v2.0.6`。
6. **第三方头文件不在 `include/` 根下**（configure 过了，编译期炸一片 `'xxx.h' file not found`）→
   `scripts/mkxp-cmake/CMakeLists.txt` 必须显式加子目录：`include/AL`（openal-soft，mkxp-z 以 `<al.h>` 引用）、
   `include/uchardet`（uchardet 0.0.8 起装 `${CMAKE_INSTALL_INCLUDEDIR}/uchardet` 子目录）、
   `include/pixman-1`（对应 meson 的 pkg-config `pixman-1`）、`<SDLSOUND_PREFIX>/include/SDL2`
   （SDL2_sound v2.0.6 把 `SDL_sound.h` 装进 `SDL2/`）、`${RUBY_INC}/ruby`（mkxp-z 直接 `#include <ruby.h>`，
   Debian 把 ruby.h 平铺在版本目录根、iOS 没有）。已另加两个 include 根的子目录全量 glob 兜底。
   排查方法：本地 clone `mkxp-z/mkxp-z` 的 tag `v2.4.2`，grep 全部 `#include <...>`，逐一对照各 port 安装规则。
   已确认**不会**参与编译的：fluidsynth（`SHARED_FLUID` 未定义）、openssl/HTTPS（`MKXPZ_SSL` 未定义）、
   boost（sigslot 适配器无人引用）、X11/EGL（`GLES2_HEADER` 已定义走 GLES 路径）。
7. **`include/ruby` 不能进 `-I`（assert.h 截胡）**：mkxp-z 直接 `#include <ruby.h>`，曾把
   `include/ruby` 加进搜索路径 → Ruby 的 `ruby/assert.h` 截胡全部 26 处 `<assert.h>`
   （它只定义 `RUBY_ASSERT_*`，无标准 `assert` 宏）→ 满屏 `use of undeclared identifier 'assert'`。
   正解：build 脚本把 `ruby.h` + `defines.h`（ruby.h 内裸名引用）**平铺**到 include 根，
   对齐 homebrew ruby 布局；`<ruby/xxx.h>` 仍从 include 根的 `ruby/` 子目录解析。
8. **`__APPLE__` vs `MKXPZ_PLATFORM` 守卫错位**：iOS 上 `__APPLE__` 为真，但 `MKXPZ_PLATFORM`
   已被坑 #3 的 sed 改成 LINUX。`config.cpp` 三处 `__APPLE__` 守卫引用仅 macOS 存在的 Metal 逻辑
   （`isMetalSupported()` 仅 `MKXPZ_BUILD_XCODE` 下声明、Apple arm64 默认开 Metal、ANGLE 平台选择）
   → `undeclared identifier 'isMetalSupported'`。已 sed 收紧为 `MKXPZ_PLATFORM_MACOS` 专属（iOS 走 GLES）。
9. **SDL2_ttf ≥2.20 结构体改名**：vcpkg 现装 sdl2-ttf 2.24.0，2.20.0 起不透明结构体由
   `_TTF_Font` 改名 `TTF_Font`（`typedef struct TTF_Font TTF_Font;`）。mkxp-z v2.4.2 的
   `font.h/font.cpp` 按旧名 forward-declare/返回，`settingsmenu.cpp` 经 SDL_ttf.h 拿到新类型
   → `incompatible pointer types assigning to 'TTF_Font *' from '_TTF_Font *'`。
   已 sed 把这两个文件的 `_TTF_Font` 统一改成 `TTF_Font`（API 用法均跨版本兼容，无需其他改动）。
10. **`MKXPZ_CJK_FONT` 的字体漏嵌**：本工程 CMake 定义了 `MKXPZ_CJK_FONT`（Essentials 中文 UI
    兜底），此时 `font.cpp` 嵌的是 `assets/wqymicrohei.ttf`（4.5MB）而非 liberation → xxd 清单
    漏了它就炸 `'wqymicrohei.ttf.xxd' file not found`。排查法：grep 全部 `#include "*.xxd"`
    与 CMake 的 SHADERS/ASSETS 清单对账（shader 26 + icon/gamecontrollerdb/liberation/wqy）。
11. **`system()` 在 iOS  unavailable**：`binding-mri.cpp` 的「打开 URL」绑定用 `std::system`
    拼 `OPENCMD`（open/xdg-open/start）启外部程序 → `'system' is unavailable: not available on iOS`。
    已 sed 把调用点替换为 `0`（no-op 降级，返回 Qnil 不抛错）。steamshim 的 fork/execvp 不在编译清单，无需处理。
12. **binding 层按仓库根相对路径 include**：`binding/*.cpp` 有 4 处 `#include "src/..."`
    （util.h/config.h），需把 `${MKXP_SRC}` 本身加进 MKXP_INC（此前只有 src/ 各子目录）。
13. **缓存还原把 vcpkg 目录搞成「有内容无 .git」**：workflow 的 `restore-keys` 前缀回退会把
    旧（成功）运行的 `deps/vcpkg/installed` 还原出来，目录非空但无 `.git`，脚本的
    `[ ! -d $VCPKG/.git ]` 守卫漏判 → `git clone` 报 "already exists and is not an empty directory"。
    已改为：克隆前把还原内容挪到 `${VCPKG}.restore`，clone + checkout 钉死 commit 后再把
    `installed/` 挪回。另：vcpkg 已钉死 commit（`VCPKG_REF`），不钉则每次跑当天 master、
    缓存跨版本复用，构建不可复现。
14. **Ruby 汇编文件没吃 iOS flags（`Context.o` built for macOS）**：Ruby 的 coroutine `.S`
    汇编规则是 `$(CC) $(ASFLAGS) -c`，**不吃 CFLAGS**——`configure cflags=` 传的交叉 flags
    到不了汇编步骤，`Context.o` 按宿主编成 macOS 对象；`libtool -static` 又不校验平台，
    直到最终链进 App 才炸 `linking object file built for 'macOS'`。已改 `make ... ASFLAGS="$ARCH_FLAGS"`。
    另修：Ruby 缓存路径此前误写 `deps/ruby-ios`（与脚本 PREFIX 不一致）导致缓存从未生效，
    已改为 `deps/ruby-ios-3.3.12` 并去掉 restore-keys（脚本变更必须逼重建）。
15. **静态 framework pod 不传递依赖到 App 链接**：mkxp 插件含 Swift 必须 `static_framework = true`，
    而静态 framework 的 pod target 只归档自己的对象——podspec 的 `vendored_frameworks` 只让
    pod 编译期能 `import MKXP`，App 最终链接看不到框架 → `Undefined symbol: _mkxp_run`。
    已用 `scripts/ios-link-mkxp.rb`（CI 在 flutter build 前跑）把框架显式注入 Runner 的
    Link Binary With Libraries + force_load + 补齐系统框架/库。
16. **框架合并漏了自编 SDL2_sound + SDL2main 捣乱 + 缺 CoreMotion/Bluetooth**：合并列表原先只有
    libmkxp + vcpkg 的 `.a` + ruby，`libSDL2_sound.a` 在 vcpkg 外被漏掉 → App 链接期
    `Sound_Init/Sound_Decode` 齐 undefined；`libSDL2main.a` 在 iOS 上无意义且引用已改名的
    main → 排除 + `mkxp_framework.cpp` 里放 `SDL_main` 无害桩；SDL2 的 iOS sensor/joystick
    代码引用 CoreMotion/CoreBluetooth → 两个框架补进链接参数（ios-link-mkxp.rb 与 podspec）。
17. **workflow 竞态**：两 workflow 并行触发时，iOS 只能拿到上一个提交的框架，引擎修复晚一轮
    生效（`Context.o` 问题曾被这么掩埋）。`ios.yml` 已改 `workflow_run` 触发，用同次提交的产物。
18. **静态框架链接终解=核心 force_load + 依赖按需加载**：`-framework MKXP` 无论放
    OTHER_LDFLAGS 还是 frameworks 阶段都拉不到符号（疑似 Xcode/ld 对「框架壳+归档内核」
    的处理问题）；而整个框架 `-force_load` 全量载入会炸 duplicate symbols——nm 对账实锤
    libc++/fmt 的符号被嵌进 `libopenal.a`/`libfmt.a`/`libmkxp.a` 多个归档（454 个重复定义，
    fmt↔openal 59 + mkxp↔openal 36 + …）。终解：框架二进制只合并**核心**（libmkxp + 静态
    Ruby + SDL2_sound）并 `-force_load`（全量载入、无视顺序）；vcpkg 各依赖 `.a` 放进
    `MKXP.framework/Libs/`，在 `-force_load` **之后**逐个按需加载——按需加载天然去重
    （ld 只取第一个定义），且排在核心之后不会再有顺序问题。另：两个 workflow 的失败摘要
    要推不同分支（`ci-status` / `ci-status-ios`），都 `--force` 推同一分支会互相覆盖。
    诊断工具：`build_mkxp_ios.sh` 5b 节的 nm 跨归档对账（COLLISION 行）。
18. **静态框架链接的三难**（都在 App 最终链接期暴露）：① podspec `vendored_frameworks` 会被
    静态 framework 的 pod 并进 `Pods-mkxp.framework`，与 App 侧加载重复；② 仅 `-framework MKXP`
    放 OTHER_LDFLAGS 会排在 Pods 之前扫描，pod 归档里的引用方还没进场 → Undefined symbol；
    ③ `-force_load` 全量载入会把 Ruby `--with-static-linked-ext` 烘进的 zlib 等对象与 vcpkg 的
    libz/libpng 重叠符号一起载入 → 800+ duplicate symbols。**正解=按需加载 + 链接锚点**：
    podspec 只留编译期 FRAMEWORK_SEARCH_PATHS；`scripts/mkxp-link-anchor.m` 加入 Runner 编译源
    （Runner 自身引用 mkxp_run/mkxp_key/mkxp_quit，未决状态在链接最开始就存在，顺序无关）；
    MKXP.framework 经 frameworks 阶段按需链接。

19. **MKXPZ_IOS_EMBED 守卫（UIKit 崩溃）**：`EventThread::process` 后台线程跑，任何 SDL 窗口操作
   会碰 UIKit 视图 → 后台线程崩 `NSInternalInconsistencyException: Call must be made on main thread`。
   `eventthread.cpp` 的 SETFULLSCREEN/WINRESIZE/WINREPOSITION/WINCENTER/WINRENAME/标题设置 在
   `MKXPZ_IOS_EMBED` 下全部吞掉；窗口固定全屏，内部分辨率由 RGSS 线程调。
20. **GL 上下文必须主线程**：`SDL_GL_CreateContext` 在 rgssThread 创建会崩（崩溃栈 `...@rgssThread`），
   改回主线程（与 `MKXPZ_INIT_GL_LATER` 的处理配合，见 build 脚本/CMake）。
21. **zlib 静态扩展：运行时 `require 'zlib'` 必须主动登记 feature（根治经验，2026-10-17）**：
   C++ 侧 libz 解压（inflate）正常，但 Ruby 层 `require 'zlib'` 真机报 LoadError。根因：Ruby 的
   `require` **先按 `$LOAD_PATH` 找文件、找不到即抛 LoadError，根本不会先查 `$LOADED_FEATURES`**——
   所以往 `$LOADED_FEATURES` 塞裸字符串 `'zlib'` 挡不住。**正解**：在 `binding-mri.cpp` 的
   `mriBindingInit` 里、mkxp-z 自带 `require('zlib')` 之前，若 `!const_defined?(:Zlib)` 就
   `Init_zlib()`（定义 Zlib 模块）+ `rb_provide_feature(rb_str_new_cstr("zlib"))`（把 feature 正式
   登记为已加载，此后 `require 'zlib'` 直接成功）。两个符号都在 `libruby-static.a`（`-force_load`
   全量载入）。
   **两个大坑（2026-10-17 实踩，连红两次 CI）**：
   ① `extern "C"` 链接声明**不能写在函数体内部**——C++ 不允许块内 linkage-spec，报
      `error: expected unqualified-id`（`e7fb24c` 红，build-mkxp 编译错）。
   ② 即便声明提到文件作用域、改为**直接调用** `rb_provide_feature`，最终 iOS App 链接会报
      `Undefined symbol: _rb_provide_feature`——它没被 `used` 锚点引用、且 MKXP.framework 未必
      把它重导出，成了链接期未定义符号（`5370dcc` 红，build-mkxp 过但 build-ios 挂）。
   **最终修法**：`Init_zlib` 与 `rb_provide_feature` 都用 `dlsym(RTLD_DEFAULT, "...")` 在运行时解析
   再调用，**彻底消除链接期引用**。运行时两符号一定在进程里（`used` 锚点强制保留 `Init_zlib`；
   `rb_provide_feature` 是 libruby 核心函数、被 `require`/extinit 自身引用，必定在场）。`mkxp_framework.cpp`
   的 `used` 锚点 `zlib_ext_anchor` 仍保留（确保 `Init_zlib` 不被死剥离，dlsym 才找得到）。
22. **sdl2-image 需显式开 JPEG**：vcpkg 默认不编 JPEG 解码 → 真机 `'JPEG images are not supported'`，
   启用 sdl2-image 的 JPEG feature（`build-mkxp.yml` 的 vcpkg install 加 `--recurse`）。
23. **Ruby GC 在 iOS 无 JIT 下是启动慢主因**：默认阈值对 Essentials 量级触发海量 GC；`mkxp_run` 在
   `ruby_init` 前 setenv 放大堆/malloc 阈值（见 `mkxp_framework.cpp`）。
24. **framework-entry.patch 现已 4 个 hunk**（原 2 个）：input.cpp（反查表）+ main.cpp（线程拆分）+
   eventthread.cpp（`MKXPZ_IOS_EMBED` 守卫）+ binding-mri.cpp（zlib 兜底+打点）。改 mkxp-z 源码仍以
   patch 为准，勿直接改 clone；生成 patch 务必 `newline="\n"`（见接手须知 #4）。
25. **交叉编译静态 Ruby 的 Encoding 常量可能缺失（2026-10-17）**：zlib 修好后脚本 `exec` 阶段立刻报
   `uninitialized constant Encoding::UTF_8 (NameError)`（Section004:5，游戏脚本早期就引用）。
   根因待定（编码注册了但常量没定义，或 `enc` 对象根本没链进 libruby-static.a）。修法 =
   `binding-mri.cpp` 初始化里加**编码常量守卫**：对 UTF-8/US-ASCII/ASCII-8BIT/UTF-16LE/UTF-16BE/
   EUC-JP/Shift_JIS/Windows-31J 逐个 `rb_enc_find`，编码在但常量缺就 `rb_define_const` 补上
   （日志 `rgss: defined Encoding::X`）；编码本身没注册则打 WARNING（`rgss: WARNING encoding X
   not registered`）——若真机日志出 WARNING，说明构建缺 `enc` 对象，下一步要去 `build_mkxp_ios.sh`
   手工编 enc/encdb.c、enc/us_ascii.c、enc/utf_8.c 等合进静态库（同 zlib_ext.o 方案）。

## 下一步该做什么（2026-10-20 更新）

M2 已全部完成；M3 真机调通 + 四运行时修复（①BGM **已根治（f33e34b 真因修复）**、③加载 已修，EventScriptError 已根治）；②撕裂已加 glFinish
修复（待真机验证）、④文本待定位上游。构建冲突已修通；当前最新 `f33e34b`（CI 双绿，IPA 可装）。剩余真实待办：

1. **② 撕裂修复真机验证**：`d55c23d` 已在 ios_embed.mm 软呈现读回前加 glFinish()（强制整帧画完再读回，消除
   Metal 异步读回半帧）。侧载后到室外大地图跑几分钟验证；若仍裂，下一步给 UIImageView 上屏加 CADisplayLink
   对齐 vblank；若感觉掉帧，把 glFinish 换成更轻的 glFenceSync 精准同步。
2. **④ 消息框少字定位+根治**：已锤定「引擎不丢字、是上游脚本按字节/宽度切片丢整字」。需用**低开销**方式定位
   上游排版方法（勿在 draw_text/pbDrawTextPositions 热路径加 caller/inspect 重日志——两度引发红线/撕裂回归），
   或用户提供 `Scripts.rxdata` 直接读消息框排版源码；定位后用 `ios_hook.rb` 重定义该方法（码点安全版）修掉。
3. **退出崩溃（间歇性，近期未复现）**：退出时 `signal=5` 崩在 SDL_DestroyWindow/UIKit_HideWindow——修复
   has_follower 后（RGSS 线程能干净退出）近期没再崩，但根因（后台线程销毁窗口碰 UIKit 断言）未根治，待观察；
   若复现需把退出时窗口销毁挪主线程。
4. **可选打磨**：开 `UIFileSharingEnabled`；触感反馈；`mkxp.log` 实时刷新。

### M3 修复：BGM 获得物品后不继续播放（`f33e34b`，2026-10-20 真机验过）

**根因**：pristine mkxp-z v2.4.2 源码有 2 个 bug 同时作用，导致 ME 结束后 BGM 永远静默（不是重启/重复，是音量卡 0 + AL 源永远 STOPPED）：

1. **`src/audio/audio.cpp:218` meWatchFun MePlaying case state 覆盖**：`meWatch.state = MeNotPlaying;` 写在 for 循环体内，每轮 track 都把上面的 `meWatch.state = BgmFadingIn` 覆盖 → ME 结束后 BGM 永远走不到 BgmFadingIn 分支做音量 fade-in（被 BgmFadingOut 设为 0 后永远回不来）。**修**：把 MeNotPlaying 移到 for 循环外，仅在 `state != BgmFadingIn` 时设置。

2. **`src/audio/alstream.cpp:313-316` pauseStream preemptPause race**：`if (AL::Source::getState(alSrc) != AL_PLAYING) preemptPause = true;` —— pause 命中的瞬间 AL 源刚好 STOPPED，preemptPause=true，resumeStream 见 true 跳 play() → AL 源永远 STOPPED。**修**：pauseStream 不再 memo preemptPause；resumeStream 无条件 `AL::Source::play(alSrc)`（OpenAL 规范：PLAYING 上 play 是 no-op，不重启；从 PAUSED 是 resume；从 STOPPED 是 restart，从根消除 race，零回归风险）。

**关键诊断点**：之前的 `mkxp_2026-10-19T22-47-40.218013.log` 显示 `bgm heal attempt 1 alstate=4116 × 73` 反复出现，但**修了我自己之前的 checkStopped heal 也没用**——framework 自带的 heal 是症状放大器（每帧 stopStream+startStream 杀流线程），真因在 pristine 源码。看 `audio.cpp` meWatchFun 状态机和 `alstream.cpp` pauseStream/resumeStream 是唯一正解。

**真机验**：2026-10-20 用户确认"修好了"——获得物品 → ME 结束 → BGM 1 秒内 fade-in 回原音量（不是重启/重复），`bgm heal attempt` 计数不再反复 attempt1。

**副作用/下一轮**：
- framework 自带 `alstream.cpp checkStopped` 的 heal 太激进（每帧杀流线程）待清理：改成只调 AL::Source::play(alSrc) 不杀流线程；heartbeat 移到 `meWatch.state == MeNotPlaying` 才跑（避免 ME 中与 meWatch 抢时序）
- `Tileset Outside 150ms 重解码 cache miss` 与 `文本缺字` 两项仍挂账，下一轮一次打包

## M1 后续必做（`libmkxp.a` 编通后，A/B/C 均已实现，仅作决策留档）

**A. 重构 `src/main.cpp` 的 `int main()` → `mkxp_run(const char* gamePath)`**
- 去掉 `uiView` 参数（浮层方案：SDL 自建全屏窗口，不需要 Flutter 给 UIView）；
- 必须在**后台线程**跑（原 `eventThread.process()` 阻塞）；
- 同时提供 `mkxp_key(int rgssKey, int down)`（向引擎推按键事件）与 `mkxp_quit()`；
- `mkxp/ios/MKXP.framework/Headers/MKXP.h` 里的 `mkxp_run` 签名已同步去掉 `uiView`。

**B. Flutter 桥接改成「透明浮层」**
- `ios/Runner/MkxpPlatformView.swift` 不再走 `UiKitView` 内嵌 SDL 视图，
  改为调用 `mkxp_run` 在后台线程启动引擎；
- `lib/widgets/game_view.dart` 去掉 `UiKitView`，改透明 `Stack` + `touch_pad` 叠加；
- 取消 `mkxp/ios/mkxp.podspec` 第 17 行注释以链接框架。

**C. 两个 workflow 的串接（重要缺口）**
- `build-mkxp.yml` 把 `MKXP.framework` 只上传成 artifact，`ios.yml` 既没 `needs` 也没
  `download-artifact`，二者完全独立、不传产物。解决二选一：
  ① `build-mkxp.yml` 构建成功后 `git commit` 回 framework（重，二进制入库）；
  ② `ios.yml` 加 `needs: build-mkxp` + `download-artifact` 取 `MKXP-framework`。
- 没解决前，`ios.yml` 只能编 M0（不含引擎）。

## 嵌入方案（已定，勿回退到 UiKitView）

**SDL 全屏窗 + Flutter 透明浮层**。理由：mkxp-z 是独立 app、永远自己 `SDL_CreateWindow`，
无 `SDL_CreateWindowFrom` / `SDL_WINDOW_EXTERNAL`，也无 iOS UIView 嵌入代码，只导出标准
`int main()`。详见 README「嵌入方式决策」一节。

## 接手须知 / 协作约定（来自 AI 记忆，跨电脑保留）

> 换电脑后 AI 记忆不随仓库走，这几条是踩过坑才定下的，务必遵守：

1. **进度汇报要给「里程碑表」，不是只报当前单步**。每次 CI 出结果或被人问进度，先甩一张
   整体进度表（M0/M1/M2 各子项 完成/进行中/未开始），再讲细节。用户连续两次追问
   "现在到哪一步了" 才意识到单步汇报不够用。
2. **本仓库 commit message 绝对不能出现 `[skip ci]`（正文也不行）**。GitHub 只要在 HEAD
   提交信息**任意位置**看到这串就跳过 workflow，白等一轮 16 分钟。需要提"跳过机制"时写成
   `skip 标记` / `skip-ci`（去掉方括号）。若推送后 CI 没触发，第一反应查 HEAD 提交信息。
3. **免登录轮询 `api.github.com` 限额 60 次/小时**，CI 轮询要节制；配了 token 自动升到 5000。
   查失败摘要优先读 `ci-status` / `ci-status-ios` 分支的 `last-failure.md`（公开仓库免登录）。
4. **给 CI `git apply` 用的 patch 千万别带 CRLF**。在本机（Windows）用 Python 生成 patch 时，
   写文件必须 `open(path, "w", encoding="utf-8", newline="\n")`——否则 Windows 默认把 `\n`
   转 `\r\n`，patch 在 Linux 的 `git apply` 行尾对不上（CI 大多能容错，但本机校验会假失败、
   误以为 patch 写错）。本会话的 `framework-entry.patch` 已因此重生成过，切记。
5. **框架化改动只动两处**：`scripts/mkxp-framework/framework-entry.patch`（作用于 mkxp-z
   v2.4.2 源码：input.cpp 的 rgssKey→scancode 反查表 + main.cpp 的线程拆分）+ 
   `scripts/mkxp-framework/mkxp_framework.cpp`（引擎入口 `mkxp_run`/`mkxp_key`/`mkxp_quit`
   与 `g_engineRunning` 标志）。**改 mkxp-z 源码一律走 patch，不要直接改 clone**——CI 每次
   重新 clone mkxp-z 再 apply，直接改本地 clone 不会进仓库。
6. **线程模型（2026-10-16 定型）**：SDL_Init / 建窗 / 起 RGSS 线程在主线程（UIKit 安全，
   后台线程 `SDL_Init(VIDEO)`/`SDL_CreateWindow` 直接崩）；`EventThread.process()` 这个阻塞
   事件循环由 `mkxp_z_main` 内部甩到后台 `std::thread`，`mkxp_z_main` 立即返回，主线程 run loop
   不被占死 → Core Animation 才上得了屏。`MKXPZ_INIT_GL_LATER` 已在 CMake 定义，GL 上下文在
   rgssThread 创建，与事件循环线程无关。`g_engineRunning` 由后台线程在引擎真正退出时复位，
   框架层 `mkxp_run` 用它防重入（去掉了原 `static` 以便 main.cpp `extern` 引用）。

## 关键文件速查

| 文件 | 作用 |
|---|---|
| `scripts/build_mkxp_ios.sh` | 主构建脚本（Ruby / vcpkg / SDL2_sound / mkxp / framework） |
| `scripts/mkxp-cmake/CMakeLists.txt` | 手搓 CMake（源清单 / 宏 / xxd / find 库 / 链接） |
| `scripts/vcpkg-triplets/arm64-ios-static.cmake` | 静态 triplet |
| `mkxp/ios/Classes/*.swift` | Flutter 桥接骨架（M0，待改浮层） |
| `mkxp/ios/mkxp.podspec` | 链接框架处（第 17 行）待 uncomment |
| `.github/workflows/build-mkxp.yml` | 编 framework |
| `.github/workflows/ios.yml` | 编 App IPA |
| `README.md` | 进度 / 决策 / 路线图 |


## M3 运行时修复（2026-10-19，CI 待真机验）

> 一次性处理四个真机运行时问题；所有 mkxp-z C++ 改动进 `framework-entry.patch`，
> iOS 音频会话进 `ios_embed.mm`，文本防御进 `ios_hook.rb`。目标：装一次 IPA 验证全部。

### ① BGM 间歇性停止
- 根因：流式解码出错即永久 Stopped 无自愈（`alstream.cpp` checkStopped）；`vorbissource.cpp` ov_read<0 / OV_HOLE 致死；
  iOS 缺 `AVAudioSession` 中断/路由处理 -> 设备失效后 BGM 永久静音（"音频真空态"）。
- 修复：
  - `vorbissource.cpp`：`ov_read<0` 有限次（8）跳过重试，不再直接判死；
  - `alstream.cpp`：checkStopped 在 state==Playing 且 AL source 非 AL_PLAYING 时**有界自愈重启**（<=30 次、2s 节流），
    超限退化为原永久停止；
  - `audio.cpp`：MeNotPlaying 加 BGM 心跳（周期 queryState 触发自愈）；
  - `ios_embed.mm`：注册 `AVAudioSessionInterruptionNotification` / `RouteChangeNotification`，
    复用 `eventthread.cpp` 的 alcDevicePause+haltThreads / resume 逻辑（新增 `mkxp_ios_audioInterruptBegin/End`）；
    中断结束/路由变更后 `AVAudioSession setActive:YES` 重新激活会话。
- 真机验证：长时间播放不中断、循环不猝死、插拔耳机/来电后 BGM 自动恢复；日志 `rgss: bgm heal attempt`。

### ② 室外横向撕裂（横线/裂痕）
- 根因：VSync 默认关（`main.cpp` SetSwapInterval(0)），双缓冲不防无 VSync 翻面撕裂；室内帧差小不可见，室外明显。
- 修复：`main.cpp` iOS（`MKXPZ_IOS_EMBED`）强制 `SDL_GL_SetSwapInterval(1)`；日志打印 `swapInterval`。
- 真机验证：室外横线消失。

### ③ 室内->室外加载慢
- 根因：`Bitmap` 构造完全同步（RGSSAD 解密 + PNG 解码 + GPU 上传），无解码像素缓存；
  战斗返回/重进地图重复冷解码。
- 修复：`bitmap.cpp` 加**解码像素 LRU 缓存**（容量 64MB，按路径缓存解密后 ABGR8888 像素；
  命中即直接 `TEX::uploadImage`，不经过 SDL surface，**字节级等价于原上传，不串色**）；
  逐 Bitmap 各自拷贝上传，缓存只持不可变像素，绝不被 blt 改坏。
- 真机验证：日志 `rgss: decode-cache hits=... miss=...`；室内->室外/战斗返回耗时下降、cache hit 占多数。

### ④ 文本时不时少一两个字
- 根因（探查结论）：mkxp-z C++ `drawText` 对 UTF-8 正确，缺字几乎必然在**上游游戏脚本按字节切片多字节字符**
  （游戏脚本不在本仓，无法直改根因）。
- 修复（安全不回归）：`ios_hook.rb` 包装 `Bitmap#draw_text` / `draw_text_ex` ——
  诊断（bytes vs chars + 上游调用栈前几帧，定位切片方法）+ 防御（对不完整 UTF-8 尾部安全剥离，合法字符串不受影响）；
  hook 版本升至 v9。
- 真机验证：日志 `mkxp-text` 若出现 `INCOMPLETE UTF-8` 或 `draw_text bytes=...` 即定位到上游方法；
  文本尾部不再因不完整 UTF-8 乱码。

## CI 链复盘 + 全项目根因总表（2026-10-20 终版，接手先读）

### A. CI 链复盘（10-19～10-20，16 次：11 成功 / 5 失败）

| 时间(CST) | commit | 构建 | 真机表现 | 阶段/教训 |
|---|---|---|---|---|
| 12:18 | ffbbc26 | 成功 | 撕裂修好，其余待验 | 四修复首版 |
| 13:41 | cbf64c5 | 成功 | — | BGM 每帧自愈 + 缓存 key 归一化 |
| 14:05 | 8beee82 | 成功 | **标题红线** | 诊断回归①：pbDrawTextPositions 无节流 + caller 重日志 |
| 14:21 | 282ef3e | 成功 | 恢复 | revert 红线 |
| 14:43 | 485ea9b | 成功 | **撕裂复发** | 诊断回归②：draw_text caller[0..12] + str + 节流 300 |
| 17:43 | 29764ab | 成功 | 恢复 | revert 撕裂 |
| 20:41 | f91a992 | 成功 | 室外裂 | 另一 session：BGM gate + tileset 缓存 + 文本 trace |
| 21:43 | c6147a2 | 失败 | — | 构建失败 |
| 22:04 | 8f899b1 | 失败 | — | text-clip 锚点缩进错 → 签名 FATAL |
| 22:16 | 6bc3691 | 失败 | — | fprintf 格式串 \n 未闭合 |
| 22:22 | ccc340d | 成功 | 室外裂 | 修 fprintf |
| 23:06 | 297dedc | 成功 | 室外裂 | Bitmap 缺文件 → 1×1 fallback |
| 23:35 | e3deb9f | 失败 | — | showExc 签名在 binding/，校验只 grep src/ → 假 FATAL |
| 09:22(+1) | c59d575 | 失败 | — | bitmap.cpp 构造函数三处补丁冲突 → 丢 hunk → FATAL |
| 09:40(+1) | 4c3af4a | 成功 | 恢复正常 | 签名校验 grep 整棵树 → 首次出包 |
| 10:05(+1) | 32918a4 | 成功 | 正常（当前版） | has_follower 改 public → EventScriptError 根治 |

**链条规律**：① 两次真机回归都是"诊断代码"造成（热路径重日志）；② 5 次构建失败全是补丁/构建脚本问题（锚点/转义/grep 路径/冲突），非业务代码；③ 另一 session 的 C++ 改动因构建卡在签名校验，**从未被编译过**，直到 4c3af4a 才第一次真正编译。

### B. 全项目 Bug 根因总表（★已锤定 ◇疑似未验证）

**启动/画面（早期）**

| 现象 | 根因 | 修复 |
|---|---|---|
| 点启动闪退 | 引擎跑后台线程，SDL iOS 后端(UIWindow/CAEAGLLayer/UIKit)只认主线程 | dispatch_async 回主线程(625cbd5) |
| 无画面/卡启动 | EventThread.process() 占死主线程 run loop → CA 无法上屏 | 阻塞循环挪后台 thread、mkxp_z_main 立即返回(15ab649/baa3646) |
| zlib LoadError | 静态 Ruby zlib 扩展没初始化 | Init_zlib + rb_provide_feature(f41c059) |
| Encoding::* 缺失 | 静态 Ruby 没定义常量 | 常量守卫 |
| JPEG | sdl2-image | — |
| ★ ?-sprite | 解析器缓存**字符串所有权**：游戏 gsub! 原地改缓存共享对象 → 污染 → 解析失败 | 缓存/返回一律 dup(21e9c0e) |
| UIKit 崩溃 | — | MKXPZ_IOS_EMBED 守卫 |

**M3 运行时（10-19/20）**

| 现象 | 根因 | 修复 |
|---|---|---|
| ★ ① BGM 间歇停 | 解码错(ov_read<0/OV_HOLE/seek 失败)或 iOS 设备失效无自愈 | vorbissource 有限重试 + alstream checkStopped 自愈 + meWatchFun 每帧心跳 + ios_embed AVAudioSession 中断/路由；**自愈必须 gate(state==Playing && !sourceExhausted)**，否则误重启 SE/ME(实测 124 次) |
| ★ ② 室外撕裂(基础) | VSync 默认关 | main.cpp 强制 SDL_GL_SetSwapInterval(1) |
| ◇ ② 撕裂复发 | **真因（2026-10-20 查明）：iOS 走软呈现**（swz_presentRenderbuffer → mkxp_softPresent：glReadPixels 读回帧→UIImage→主线程 UIImageView 上屏，盖在 GL 视图上）；**VSync 只作用 EAGL swap，管不到软呈现的读回+UIImageView 上屏**；高负载下 Metal 异步读回半渲染帧→半帧呈现→撕裂（间歇/负载相关/与 commit 无关，实测没改代码也复现）。**旧"L599 导致复发"归因已否定** | **已实现待真机验证（d55c23d）**：ios_embed.mm 读回前加 glFinish() 强制整帧画完再读回；若未根治再上 CADisplayLink 对齐 vblank |
| ★ ③ 加载慢 | Bitmap 构造同步解码无缓存 | 解码像素 LRU 缓存(key 归一化、直接上传像素、勿整份 surface 拷贝、勿重复) |
| ★ ④ 消息框少 1-2 字 | **非引擎**：drawText 用 squeeze 压缩不裁切不丢字，传入字符串都合法完整；少字是**上游脚本按字节/宽度切片丢整字** | 须定位上游排版方法再用 ios_hook.rb 重定义(码点安全版)；引擎无法还原已丢字符 |
| ★ EventScriptError 弹窗 | [Following Pokemon EX] 显式接收者调 Game_Player 私有 has_follower → Ruby3.3 严禁"私有 + 显式接收者" → NoMethodError → rescue 包成 EventScriptError → SDL 弹窗 | ios_hook.rb 惰性 Game_Player.send(:public,:has_follower) + showExc 落日志不弹框 |

### C. 渲染热路径铁律（红线 + 撕裂同一根因，已锤定）
pbDrawTextPositions 与 Bitmap#draw_text 都是每帧热路径。在上面加日志必须：**(a) 硬节流(~40 次即停) (b) 不用 caller(caller[N] 每帧生成栈回溯很贵) (c) 不用大 inspect**。
- 反例(都已 revert)：8beee82 pbDrawTextPositions 无节流 + caller[0..7] + texts.inspect → 标题红线；485ea9b draw_text caller[0..12] + str + 节流 300 → 撕裂。
- 正例(32918a4 安全在跑)：pbDrawTextPositions 节流 40 + 无 caller；draw_text caller[0..3] + 节流 120。
- **撕裂真因是软呈现缺帧同步（见 B⑨），不是渲染被拖慢**：VSync 只减轻（管 EAGL swap），管不到软呈现的读回+UIImageView 上屏；高负载下半帧呈现→裂。**已实现修复（d55c23d，待真机验证）：读回前 glFinish() 强制整帧画完**。热路径铁律防的是另一类"拖慢渲染的 artifact"，两者别混。

### D. 构建/CI 铁律

| 现象 | 根因 | 修复 |
|---|---|---|
| FATAL(bitmap.cpp) | 构建脚本补丁(L599/L712)与 framework-entry.patch 都改 Bitmap 构造函数 → 冲突 → patch -f 静默丢 hunk → 签名缺失 | 删 L599/L712，缓存 + fallback 并入 framework-entry.patch 独管构造函数 |
| 假 FATAL(showExc) | 签名校验 grep 只搜 src/，签名在 binding/binding-mri.cpp | grep 改整棵 $MKXP_SRC |
| CI git apply 失败 | framework-entry.patch 带 CRLF | 必须 open(...,newline="n") 写 LF |
| 没 IPA 可装 | 只有 CI conclusion=success 才出 artifact | 装前先查 Actions conclusion |

### E. 未修
- 退出时 signal=5 崩 SDL_DestroyWindow/UIKit_HideWindow：**间歇性**；修复 has_follower 后（RGSS 线程能干净退出）近期未复现，但根因（后台线程销毁窗口碰 UIKit 断言）未根治，待观察；若复现需把退出时窗口销毁挪主线程。
