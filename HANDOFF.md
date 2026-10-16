# HANDOFF — MKXP-Z iOS 构建接力

> 本文件专门写给「接手继续云编译」的会话/人。AI 记忆**不随仓库走**，所以把接力上下文写在这里。

## 当前状态（2026-10-16）

- 最新提交：`5f78b80`（补第三方头文件 include 路径）。待 `git push origin main` 触发下一轮 CI。
- **M0 流水线 ✅**（Flutter 壳 + mkxp 插件 + 云构建 + 侧载，IPA 可出）。
- **M1 进行中**，卡在「手搓 CMake 编译 `libmkxp.a`」这一关。configure / xxd / find_library / 头文件路径
  四关已过（坑 #6），当前卡点为编译期错误：`assert` 被 ruby/assert.h 截胡（坑 #7，已改平铺布局）、
  `isMetalSupported` 未声明（坑 #8，Metal 守卫已收紧），待下一轮 CI 验证。
- 已跑通的子步骤（CI 已验证）：
  - MRI Ruby 3.3.12 静态库 `libruby.3.3-static.a` 链接成功 + 头文件 staged；
  - vcpkg `arm64-ios-static` 静态 triplet 编出全部 C 依赖（脚本内有诊断会列出 `libSDL2*` 等）；
  - `SDL2_sound` v2.0.6 源码交叉编译出 `libSDL2_sound.a` 成功。
- 两个前置炸弹已修（见下「已踩的坑」）。

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
- **免 token 看错误**：`build-mkxp.yml` 失败时会把错误摘要+日志尾部自动推到 `ci-status` 分支的
  `ci-status/last-failure.md`（`[skip ci]` 防重触发）。读取：
  `GET /repos/vikangliang/rpgxp-ios/contents/ci-status/last-failure.md?ref=ci-status`（公开仓库免登录）。
  本地也可跑 `powershell -File C:\Users\ginny\.ci\get-ci.ps1` 一次拿到状态+步骤+失败摘要。

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

## 下一步该看什么（`ffc7dfa` 之后的构建）

`ffc7dfa`（xxd 修复）+ `c02b881`（find_library 修复）都已在树里，下一次 build-mkxp.yml 会一起吃进去。预期顺序：

1. **cmake configure**：若 `find_library` 仍挂，看诊断输出里 `libSDL2` 的**真实形态**
   （`.a` 还是 `.framework`），据实在 `find_mkxp_lib` 补匹配规则。
2. **cmake build / xxd 生成**：确认 `gen/` 下 `.xxd` 产出、符号名 `___shader_*` 正确。
3. **mkxp-z C++ 真正编译** → 深水区（逐条 error 贴回，按文件定位）：
   - GLES2 后端在某 iOS SDK 上的兼容（已 `-DGLES2_HEADER`；`MKXPZ_INIT_GL_LATER` 控制 init 时机）；
   - iOS 缺失的 POSIX API（已处理 `system()`/`vm_dump`，可能还有别的）；
   - openal-soft `ALCdevice` 结构体名（已 `-DMKXPZ_ALCDEVICE=ALCdevice`）；
   - `src/main.cpp` 的 `int main()` 编进静态库 OK，但**最终链接进 Flutter App 会冲突**（见下 A）。
4. `libmkxp.a` 编通后，`build-mkxp.yml` 的 stage 5 会用 `libtool -static` 把
   `libmkxp.a` + 全部 vcpkg `.a` + `libruby-static.a` 合并成 `MKXP.framework`。

## M1 后续必做（`libmkxp.a` 编通后）

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
