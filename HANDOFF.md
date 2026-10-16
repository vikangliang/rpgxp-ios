# HANDOFF — MKXP-Z iOS 构建接力

> 本文件专门写给「接手继续云编译」的会话/人。AI 记忆**不随仓库走**，所以把接力上下文写在这里。

## 当前状态（2026-10-16）

- 最新提交：见 git log（M1-A 框架化入口 `8f263e1` + vcpkg 缓存修复）。待 CI 验证。
- **M0 流水线 ✅**（Flutter 壳 + mkxp 插件 + 云构建 + 侧载，IPA 可出）。
- **M1 编译关已通** ✅✅：`e7d7019` 起 `build-mkxp.yml` 全绿——`libmkxp.a` 编通并合并出
  `MKXP.framework`（artifact 9.96MB = libmkxp + 全部 vcpkg 静态依赖 + libruby-static + 4.5MB CJK 字体）。
  configure / xxd / find_library / 头文件路径 / assert 截胡 / Metal 守卫 / TTF_Font 改名 / CJK 字体 /
  system() / 根相对 include 十关全过（坑 #3/#6-#12）。
- **M1-A 已完成** ✅（`baeb52f` CI 验证）：`mkxp_run`/`mkxp_key`/`mkxp_quit` 框架化入口落地
  （`scripts/mkxp-framework/`：patch + mkxp_framework.cpp），`MKXP.framework` 含全部三个符号。
- **M1-C/B 已完成（待 CI 验证）**：`ios.yml` 改为 **`workflow_run` 触发**——等 `build-mkxp.yml`
  完成后用**同一次提交**的 `MKXP.framework` 编 App（此前两 workflow 并行触发只能拿到上一个
  提交的旧框架，引擎修复晚一轮生效，`Context.o` 问题就是这么被掩埋的；手动 dispatch 时
  退而取最近成功）。podspec 放开 `vendored_frameworks` 并补齐系统框架/库；Swift 侧
  `MkxpBridge` + MethodChannel 的 launch/quit/key；Dart 侧 `GameView` 改透明浮层、
  主界面加启动/关机入口。**真机验证清单**：装包 → 填游戏目录（如 games/Essentials）→
  启动引擎 → 看 `mkxp.log`。
- **M1 剩余**：真机验证（上述清单）+ M2（游戏库扫描/导入解压/虚拟摇杆）。
- **M1-A 进行中（2026-10-16）**：框架化入口已落地并由 `baeb52f` 验证通过——
  `scripts/mkxp-framework/` 下 `framework-entry.patch`（`main()`→`extern "C" mkxp_z_main()`；
  input.cpp 发布 rgssKey→scancode 反查表带 mutex）+ `mkxp_framework.cpp`
  （`mkxp_run` 后台线程 / `mkxp_key` SDL 事件注入 / `mkxp_quit` SDL_QUIT），
  CMake 加 `WORKDIR_CURRENT`（游戏目录由 mkxp_run 设为工作目录，不 chdir 到 bundle）。
  已知待验证风险：后台线程里 `SDL_Init(VIDEO)`/`SDL_CreateWindow` 在 iOS 上是否
  稳（已先调 `SDL_SetMainReady()`）；真机跑起来看 `mkxp.log`。
- 已跑通的子步骤（CI 已验证）：
  - MRI Ruby 3.3.12 静态库 `libruby.3.3-static.a` 链接成功 + 头文件 staged；
  - vcpkg `arm64-ios-static` 静态 triplet 编出全部 C 依赖（脚本内有诊断会列出 `libSDL2*` 等）；
  - `SDL2_sound` v2.0.6 源码交叉编译出 `libSDL2_sound.a` 成功。

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
18. **静态框架链接的三难**（都在 App 最终链接期暴露）：① podspec `vendored_frameworks` 会被
    静态 framework 的 pod 并进 `Pods-mkxp.framework`，与 App 侧加载重复；② 仅 `-framework MKXP`
    放 OTHER_LDFLAGS 会排在 Pods 之前扫描，pod 归档里的引用方还没进场 → Undefined symbol；
    ③ `-force_load` 全量载入会把 Ruby `--with-static-linked-ext` 烘进的 zlib 等对象与 vcpkg 的
    libz/libpng 重叠符号一起载入 → 800+ duplicate symbols。**正解=按需加载 + 链接锚点**：
    podspec 只留编译期 FRAMEWORK_SEARCH_PATHS；`scripts/mkxp-link-anchor.m` 加入 Runner 编译源
    （Runner 自身引用 mkxp_run/mkxp_key/mkxp_quit，未决状态在链接最开始就存在，顺序无关）；
    MKXP.framework 经 frameworks 阶段按需链接。

## 下一步该做什么（编译关已通，2026-10-16）

`libmkxp.a` → `MKXP.framework`（9.96MB）已由 `e7d7019` 的 CI 产出，编译期十二个坑全部填平。
接下来按优先级做「M1 后续必做」A/B/C（见下），把引擎接进 App：

1. **A（引擎入口）**：`main.cpp` 的 `int main()` → `mkxp_run(gamePath)` 后台线程 + `mkxp_key`/`mkxp_quit`；
   注意 `int main()` 目前仍编在静态库里，不解决的话最终链进 Flutter App 会符号冲突。
2. **C（workflow 串接）**：`ios.yml` 加 `needs: build-mkxp` + `download-artifact` 取 `MKXP-framework`，
   否则 App 包里永远没有引擎。
3. **B（Flutter 侧）**：桥接改透明浮层（依赖 A 的 `mkxp_run`）。

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
