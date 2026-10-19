#!/usr/bin/env bash
# =============================================================================
# MKXP-Z iOS 交叉编译脚本（M1a：隔离构建，产出 MKXP.framework 静态框架）
# 运行环境：macOS（GitHub Actions macos-15 runner，自带 Xcode/iOS SDK）
# 产物：  $GITHUB_WORKSPACE/mkxp/ios/MKXP.framework （静态，含 MKXP-Z + MRI Ruby + SDL2* + 音频）
# 说明：  本脚本被 .github/workflows/build-mkxp.yml 调用，独立于 App 构建，
#        翻车也不会影响已跑通的 IPA 流水线。Ruby 交叉编译最难，按 CI 日志迭代。
# =============================================================================
set -euo pipefail

# ---------- 基础路径 / 工具链 ----------
export DEVELOPER_DIR=$(xcode-select -p)
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
MIN_IOS=14.0
ARCH=arm64
ROOT=$PWD
LOG=$ROOT/build-mkxp.log
exec > >(tee -a "$LOG") 2>&1

echo "== [$(date)] MKXP-Z iOS build start =="
echo "SDK=$SDK  MIN_IOS=$MIN_IOS"

RUBY_VER=3.3.12
# PREFIX 带版本号：换 Ruby 版本时旧缓存自动失效，避免脚本因 libruby-static.a
# 已存在而跳过重建（同 runner 上 homebrew 的 ruby@3.3.12 已验证可编）。
PREFIX=$ROOT/deps/ruby-ios-$RUBY_VER   # Ruby 安装前缀（缓存）
VCPKG=$ROOT/deps/vcpkg
MKXP_SRC=$ROOT/deps/mkxp-z
FW_DIR=$ROOT/mkxp/ios/MKXP.framework

# 交叉编译统一 flags（给 autotools / cmake 用）
export ARCH_FLAGS="-arch $ARCH -isysroot $SDK -miphoneos-version-min=$MIN_IOS"
export CFLAGS="$ARCH_FLAGS"
export CXXFLAGS="$ARCH_FLAGS"
export LDFLAGS="$ARCH_FLAGS"
export CPPFLAGS="-I$PREFIX/include"

# ---------- 0. 主机工具 ----------
brew install --formula cmake ninja automake libtool pkg-config bison 2>/dev/null || true
# Ruby 的 parse.c 由 bison 生成，Apple 自带 bison 仅 2.3（需 >=3.0），
# 必须把 brew 的 bison 放到 PATH 前面，否则两端生成 parse.c 都会失败。
export PATH="$(brew --prefix bison)/bin:$PATH"

# ---------- 1. vcpkg 安装 C 依赖（arm64-ios 静态） ----------
# 钉死 vcpkg commit：不钉的话每次跑的都是当天 master，port 行为随时间漂移、
# 且 actions/cache 的 installed/ 可能跨 vcpkg 版本被复用，构建不可复现。
# 升 vcpkg 时改这里（缓存 key 只跟本脚本哈希走，会自然失效重建）。
VCPKG_REF=3cd21e48a75f67acfef289da52893ce79144aaa1  # master @ 2026-10-16
if [ ! -d "$VCPKG/.git" ]; then
  # actions/cache 的 restore-keys 会把旧运行的 installed/ 还原到 $VCPKG
  # （目录非空但无 .git），直接 clone 会 "already exists and is not empty"。
  # 先把还原内容挪开，clone + checkout 钉死版本后再把 installed/ 挪回去
  # （vcpkg install 认得它，同版本即跳过重建）。
  if [ -d "$VCPKG" ]; then
    mv "$VCPKG" "${VCPKG}.restore"
    echo "== vcpkg dir restored from cache (no .git), moved aside =="
  fi
  git clone --depth 1 https://github.com/microsoft/vcpkg "$VCPKG"
  git -C "$VCPKG" fetch --depth 1 origin "$VCPKG_REF" \
    && git -C "$VCPKG" checkout --detach "$VCPKG_REF" \
    || echo "WARN: vcpkg pin checkout failed, falling back to master"
  if [ -d "${VCPKG}.restore/installed" ]; then
    mv "${VCPKG}.restore/installed" "$VCPKG/installed"
    echo "== restored cached vcpkg installed/ =="
  fi
  rm -rf "${VCPKG}.restore"
fi
pushd "$VCPKG" >/dev/null
  ./bootstrap-vcpkg.sh
popd >/dev/null

echo "== install C deps via vcpkg (arm64-ios-static) =="
# mkxp-z v2.4.2 依赖面（来自 src/meson.build）：
#   sdl2 sdl2_image sdl2_ttf sdl2_sound physfs openal theora vorbis vorbisfile
#   ogg freetype pixman libpng libjpeg zlib uchardet (+ 系统 bz2/iconv)
# 音频走 SDL2_sound + vorbis/theora，不是 sdl2-mixer；无 boost/sqlite 依赖。
# 必须用【静态】triplet：动态 arm64-ios 产出 .framework/.dylib，既无法被手搓
# CMake 的 find_library(SDL2) 直接命中，也无法被 libtool -static 合并进框架。
"$VCPKG/vcpkg" install --triplet arm64-ios-static \
  --overlay-triplets "$ROOT/scripts/vcpkg-triplets" \
  --recurse \
  sdl2 "sdl2-image[libjpeg-turbo]" sdl2-ttf \
  physfs openal-soft \
  libtheora libvorbis libogg \
  freetype pixman libpng libjpeg-turbo zlib uchardet
# 注：sdl2-image 默认 feature 集不含 JPEG——真机日志实测
# "Error initializing SDL_image: JPEG images are not supported"（Essentials 有 .jpg 资源）。
# [libjpeg-turbo] 显式打开 JPG 解码；PNG 内置不受影响。
VCPKG_INSTALL=$VCPKG/installed/arm64-ios-static
# 诊断：确认静态 triplet 确实产出了 .a（尤其是 libSDL2*），避免 find_library 黑盒
echo "== vcpkg installed 顶层 =="
ls -1 "$VCPKG_INSTALL" 2>/dev/null
echo "== vcpkg installed/lib/*.a (前 200 行) =="
ls -1 "$VCPKG_INSTALL/lib" 2>/dev/null | head -200
echo "== SDL2 相关产物 =="
find "$VCPKG_INSTALL" \( -name 'libSDL2*' -o -name 'SDL2*' \) 2>/dev/null

# ---------- 1b. 编 SDL2_sound（vcpkg 无此端口；mkxp-z 音频硬依赖，源码交叉编译静态库） ----------
SDLSOUND_SRC=$ROOT/deps/SDL_sound
SDLSOUND_PREFIX=$ROOT/deps/sdl2-sound-ios
if [ ! -f "$SDLSOUND_PREFIX/lib/libSDL2_sound.a" ]; then
  if [ ! -d "$SDLSOUND_SRC/.git" ]; then
    git clone --depth 1 --branch v2.0.6 https://github.com/icculus/SDL_sound.git "$SDLSOUND_SRC"
  fi
  cmake -B "$SDLSOUND_SRC/build-ios" -S "$SDLSOUND_SRC" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=$ARCH \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_IOS \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$VCPKG_INSTALL" \
    -DSDL2_DIR="$VCPKG_INSTALL/share/sdl2" \
    -DBUILD_SHARED_LIBS=OFF \
    -DSDLSOUND_BUILD_SHARED=OFF -DSDLSOUND_BUILD_STATIC=ON \
    -DSDLSOUND_BUILD_TEST=OFF \
    -DCMAKE_INSTALL_PREFIX="$SDLSOUND_PREFIX"
  cmake --build "$SDLSOUND_SRC/build-ios" -j"$(sysctl -n hw.ncpu)"
  cmake --install "$SDLSOUND_SRC/build-ios"
fi
echo "sdl2_sound static lib: $(ls -1 "$SDLSOUND_PREFIX"/lib/libSDL2_sound.a 2>/dev/null || echo NONE)"

# ---------- 2. MRI Ruby 交叉编译（iOS arm64） ----------
# 用主机 ruby 引导 miniruby；本体编成静态库供 MKXP 链接。
# mk_builtin_binary.rb 递归编译全部内建字节码时容易栈溢出（segfault 11），
# macOS 默认主线程栈仅 8MB，放大到 64MB 规避。
ulimit -s 65536 2>/dev/null || true
if [ -f "$PREFIX/lib/libruby-static.a" ]; then
  echo "== Ruby 已缓存，跳过 =="
else
  echo "== cross-build Ruby $RUBY_VER for iOS =="
  RUBY_SRC=$ROOT/deps/ruby-$RUBY_VER
  if [ ! -d "$RUBY_SRC/.git" ]; then
    # Ruby tag 格式是 v3_2_5（下划线），不是 v3.2.5
    git clone --depth 1 --branch "v${RUBY_VER//./_}" https://github.com/ruby/ruby.git "$RUBY_SRC"
  fi
  pushd "$RUBY_SRC" >/dev/null
    # iOS 上 system() 被标 unavailable，且 vm_dump.c 的 rb_vm_bugreport 里
    # 没有任何预处理宏守卫（仅运行时 if(cmd) 包着）。函数式宏 -Dsystem(x)=0
    # 会害 shell 把命令行里的括号当成 subshell 语法而报错，故改用 sed 直改调用点。
    # 兼容 3.2（system(buf)）与 3.3（system(cmd)）两种写法。
    sed -i '' -e 's/system(buf)/0/' -e 's/system(cmd)/0/' vm_dump.c
    # autoreconf -fi 自动安装辅助文件（config.guess/sub/install-sh）
    autoreconf -fi
    # ---------- Stage A：定位 macOS 原生 ruby（构建期工具，无需自编） ----------
    # runner 已自带 ruby@3.3 (3.3.12，与 iOS 目标同版本)：原生 macOS arm64、含全套
    # stdlib（含 erb）。交叉编译时 make 用它生成 encdb.h/transdb.h/rbconfig.rb、
    # builtin_binary.inc、ext/configure-ext.mk 等，这些必须在本机跑。
    # 直接复用它作 MINIRUBY/BUILTRUBY/PREP，既避免自编 host ruby 被全局 iOS
    # CFLAGS 污染，也避开 Ruby 3.3 的 `ruby` 可执行链接规则把 Makefile 当目标文件
    # 的坑（那个规则只影响可执行链接，跳过它、只编静态库即可）。
    BUILD_RUBY="$(brew --prefix ruby@3.3 2>/dev/null)/bin/ruby"
    [ -x "$BUILD_RUBY" ] || BUILD_RUBY=/opt/homebrew/opt/ruby@3.3/bin/ruby
    "$BUILD_RUBY" --disable=gems -v
    "$BUILD_RUBY" --disable=gems -e 'require "erb"; puts "HOST_RUBY_ERB_OK"'   # 自检：erb 可用
    # 注意：HOST_RUBY 必须是“裸路径”，不能带 --disable=gems 之类的参数——Ruby 的
    # Makefile 会把 MINIRUBY/PREP 当作前置目标（prerequisite）展开，带空格的参数会被
    # 拆成两个 token 导致 “No rule to make target '--disable=gems'”。erb 是 default gem，
    # 不带该参数也能 require 成功。
    HOST_RUBY="$BUILD_RUBY"
    # ---------- iOS SDK 缺失的 BSD 头桩（iPhoneOS 去掉了部分 macOS 头） ----------
    # Ruby 的 dir.c 等在某些版本下直接 #include <sys/vnode.h>（iOS SDK 没有）。
    # 提供最小桩并放到 include 搜索最前面；同时把对应 ac_cv_header_* 压成 no 双保险。
    STUB=$ROOT/deps/ios-stub
    mkdir -p "$STUB/sys"
    cat > "$STUB/sys/vnode.h" <<'EOF'
#ifndef RUBY_IOS_SYS_VNODE_H
#define RUBY_IOS_SYS_VNODE_H
/* Minimal stub for iOS: <sys/vnode.h> is absent from the iPhoneOS SDK. */
#define VNON  0
#define VREG  1
#define VDIR  2
#define VBLK  3
#define VCHR  4
#define VLNK  5
#define VSOCK 6
#define VFIFO 7
#define VBAD  8
#define VSTR  9
#define VCPLX 10
#endif
EOF
    # zlib 头/库来自 vcpkg（libz.a + zlib.h 已在 arm64-ios-static 装好）：
    # 真机日志实证 Ruby 'require zlib' LoadError → Scripts.rxdata 的 zlib 解包失败，
    # RGSS 线程死亡。CPPFLAGS 喂头文件、LDFLAGS 喂库路径；--with-zlib-dir 双保险。
    export CPPFLAGS="-I$STUB -I$PREFIX/include -I$VCPKG_INSTALL/include"
    # ---------- Stage B：交叉编译 iOS 静态库，用 runner 原生 ruby 引导 ----------
    mkdir -p build-ios && cd build-ios
    # --host 走交叉路径；不显式给 --build，让 configure 用 config.guess 推断
    # （带系统版本号、与 host 不同），autoconf 才判定为交叉编译。
    ../configure --host=aarch64-apple-darwin \
      --prefix="$PREFIX" \
      --enable-static --disable-shared \
      --disable-install-doc --disable-jit-support \
      --with-static-linked-ext \
      --with-out-ext=win32,win32ole,dbm,gdbm,coverage,fiddle,pty \
      --with-zlib-dir="$VCPKG_INSTALL" \
      --with-zlib-include="$VCPKG_INSTALL/include" \
      --with-zlib-lib="$VCPKG_INSTALL/lib" \
      cflags="$ARCH_FLAGS" LDFLAGS="$ARCH_FLAGS -L$VCPKG_INSTALL/lib" \
      CROSS_COMPILING=yes \
      ac_cv_func_getentropy=no \
      ac_cv_func_fcntl=yes \
      ac_cv_header_sys_vnode_h=no \
      ac_cv_header_sys_ucred_h=no \
      ac_cv_header_sys_attr_h=no \
      ac_cv_func_getattrlist=no \
      ac_cv_func_fgetattrlist=no
    # 关键：所有"需要运行 ruby"的生成步骤都用 runner 的原生 ruby（完整版，含 erb
    # 等 stdlib），避免跑 iOS 二进制；miniruby 不加载 default gem（如 erb），生成
    # ext/configure-ext.mk 时会 LoadError，故用完整 ruby 作 MINIRUBY/PREP/BUILTRUBY。
    # 只编静态库（含 encodings 与 static-linked-ext），跳过 `ruby` 可执行链接——
    # Ruby 3.3 的可执行链接规则会把 Makefile/GNUmakefile 当目标文件而失败，而静态库
    # 归档规则不受影响，且 MKXP 只需要静态库。注意 Makefile 里静态库 target 带版本号
    # libruby.$(MAJOR).$(MINOR)-static.a（此处为 libruby.3.3-static.a），直接用该名。
    # ASFLAGS 必须显式传 iOS 交叉 flags：coroutine 的 .S 汇编规则是
    # `$(CC) $(ASFLAGS) -c`，【不吃 CFLAGS】——不传就会按宿主编成 macOS 对象，
    # libtool -static 又不校验平台，直到最终链进 App 才炸
    # "linking object file built for 'macOS'"。
    # 注：【不再】跑 make build-ext——交叉编译下 extconf 用 HOST ruby 的 RbConfig
    # （macOS 编译器）生成 constdefs.h 等，必然失败（实测 make: *** [build-ext]
    # Error 2），产出的也不是 iOS 对象。zlib 改用下方【手工编译】方案。
    make libruby.3.3-static.a -j"$(sysctl -n hw.ncpu)" \
      MINIRUBY="$HOST_RUBY" BUILTRUBY="$HOST_RUBY" PREP="$HOST_RUBY" \
      ASFLAGS="$ARCH_FLAGS"
    # 自检：zlib 扩展必须真的编进来了（真机日志曾因缺它 require zlib LoadError）
    if find .ext -name 'zlib.a' 2>/dev/null | grep -q .; then
      echo "zlib static ext: OK ($(find .ext -name 'zlib.a' | tr '\n' ' '))"
    else
      echo "::warning::zlib 扩展未编译出来——检查 --with-zlib-dir 与 vcpkg 头文件"
      { find .ext -maxdepth 2 -type d 2>/dev/null | head -30; } || true
    fi
    # 交叉编译不能跑 make install（会执行目标架构二进制），手动收集产物。
    # 静态库可能叫 libruby.a 或 libruby-static.a，挑存在的那个。
    mkdir -p "$PREFIX/lib" "$PREFIX/include/ruby"
    RUBY_A=""
    [ -f libruby.3.3-static.a ] && RUBY_A=libruby.3.3-static.a
    [ -f libruby-static.a ] && RUBY_A=libruby-static.a
    [ -f libruby.a ] && RUBY_A=libruby.a
    echo "ruby static lib: ${RUBY_A:-NONE}"

    # 手工编译 zlib 扩展并合进 libruby：交叉编译下 `make build-ext` 用 HOST ruby 的
    # RbConfig（macOS 编译器）产不出 iOS 对象，扩展等于没编。这里直接用 iOS 工具链
    # 编译 ext/zlib/zlib.c，再 libtool 合进静态库；binding-mri.cpp 会用 dlsym 兜底
    # 调 Init_zlib + rb_provide_feature，让 require "zlib" 命中。
    ZLIB_C="$RUBY_SRC/ext/zlib/zlib.c"
    if [ -f "$ZLIB_C" ] && [ -n "$RUBY_A" ]; then
      echo "== 手工编译 zlib 扩展 =="
      clang $ARCH_FLAGS -O2 -fPIC -DHAVE_ZLIB_H -c "$ZLIB_C" -o zlib_ext.o \
        -I"$PREFIX/include" -I"$PREFIX/include/ruby" \
        -I".ext/include/arm64-darwin" -I".ext/include/arm64-darwin/ruby" \
        -I"../include" -I"../include/ruby" -I".." -I"." \
        -I"$RUBY_SRC" -I"$RUBY_SRC/include" -I"$VCPKG_INSTALL/include" 2>&1 | tail -8 || true
      if [ -f zlib_ext.o ]; then
        echo "== zlib_ext.o 符号诊断 =="
        nm zlib_ext.o 2>&1 | grep -i "Init_zlib" || echo "!! zlib_ext.o 里没有 Init_zlib（编译产物异常）"
        nm zlib_ext.o 2>&1 | head -5
        libtool -static -o "$RUBY_A.new" "$RUBY_A" zlib_ext.o && mv -f "$RUBY_A.new" "$RUBY_A"
        echo "zlib 扩展已合并进 $RUBY_A"
        # 合并后自检：libtool 偶发把成员丢掉（duplicate member 警告同场出现）；
        # 失败则用 ar 追加重合并一次（诊断输出 nm 的真实报错）。
        if ! nm "$RUBY_A" 2>/dev/null | grep "Init_zlib" >/dev/null; then
          echo "::warning::libtool 合并后未检出 Init_zlib，nm 报错如下："
          nm "$RUBY_A" 2>&1 | head -3
          echo "== 改用 ar 追加重合并 =="
          cp -f "$RUBY_A" /tmp/ruby_backup.a
          ar -qc "$RUBY_A" zlib_ext.o 2>/dev/null || true
          ranlib "$RUBY_A" 2>/dev/null || true
          if nm "$RUBY_A" 2>/dev/null | grep "Init_zlib" >/dev/null; then
            echo "ar 追加后 Init_zlib: OK"
          else
            cp -f /tmp/ruby_backup.a "$RUBY_A"
            echo "::error::ar 追加后仍未检出 Init_zlib（zlib 运行时不可用）"
          fi
        else
          echo "合并后 Init_zlib: OK"
        fi
      else
        echo "::warning::zlib_ext.o 未生成（头文件路径？），zlib 仍不可用"
      fi
    fi
    # 关键自检：libruby 里必须能找到 Init_zlib（require 'zlib' 运行时的实体）
    if [ -n "$RUBY_A" ]; then
      if nm "$RUBY_A" 2>/dev/null | grep "Init_zlib" >/dev/null; then
        echo "libruby contains Init_zlib: OK"
      else
        echo "::error::libruby-static.a 里没有 Init_zlib——require zlib 运行时必失败"
      fi
    fi
    cp -f "$RUBY_A" "$PREFIX/lib/libruby-static.a"
    cp -f ./*.h "$PREFIX/include" 2>/dev/null || true
    cp -f ../*.h "$PREFIX/include/" 2>/dev/null || true
    # mkxp-z 期望 ruby 版本子目录（如 ruby/version.h, ruby/intern.h）
    cp -rf ../include/ruby/* "$PREFIX/include/ruby/" 2>/dev/null || true
    cp -f ./*.h "$PREFIX/include/ruby/" 2>/dev/null || true
    # 交叉编译生成的本机 arch 头（ruby/config.h 等）在 .ext/include/arm64-darwin/
    cp -rf .ext/include/arm64-darwin/* "$PREFIX/include/" 2>/dev/null || true
    # mkxp-z 直接 #include <ruby.h>，且 ruby.h 内部 #include "defines.h"（裸名引用）。
    # 把这两个头平铺到 include 根（对齐 homebrew ruby 布局），<ruby.h> 从 include 根
    # 即可解析。【切勿】改把 $PREFIX/include/ruby 加进 -I：那会让全部 <assert.h>
    # 被 ruby/assert.h 截胡——它只定义 RUBY_ASSERT_* 系列、不定义标准 assert 宏，
    # 而 mkxp-z 有 26 处 #include <assert.h>，会齐炸 'use of undeclared identifier assert'。
    cp -f "$PREFIX/include/ruby/ruby.h" "$PREFIX/include/ruby.h" 2>/dev/null || true
    cp -f "$PREFIX/include/ruby/defines.h" "$PREFIX/include/defines.h" 2>/dev/null || true
    ls "$PREFIX/include" >/dev/null && echo "ruby headers staged"
  popd >/dev/null
fi
RUBY_INC=$PREFIX/include
RUBY_LIB=$PREFIX/lib/libruby-static.a

# ---------- 3. 克隆 mkxp-z（上游已放弃 CMake/macOS/iOS，统一用 v2.4.2 + 手搓 CMake） ----------
if [ ! -d "$MKXP_SRC/.git" ]; then
  git clone --depth 1 --branch v2.4.2 --recurse-submodules \
    https://github.com/mkxp-z/mkxp-z.git "$MKXP_SRC" || \
  git clone --depth 1 --branch v2.4.2 https://github.com/mkxp-z/mkxp-z.git "$MKXP_SRC"
fi

# iOS 上 __APPLE__ 为真，上游 src/system/system.h 会把 MKXPZ_PLATFORM 判成
# MKXPZ_PLATFORM_MACOS，可能误走 macOS Cocoa/AppKit 分支（iOS 没有 AppKit，编译必炸）。
# 强制改判为 MKXPZ_PLATFORM_LINUX（POSIX/SDL 路径，iOS 与 Linux 同属 Unix 类，可用）。
# 注意：仅靠 -DMKXPZ_PLATFORM=... 不够——system.h 内的 #define 在源码里后定义会覆盖命令行，
# 所以必须在克隆后直接改源文件。
if [ -f "$MKXP_SRC/src/system/system.h" ]; then
  sed -i '' 's/#define MKXPZ_PLATFORM MKXPZ_PLATFORM_MACOS/#define MKXPZ_PLATFORM MKXPZ_PLATFORM_LINUX/' \
    "$MKXP_SRC/src/system/system.h"
  echo "patched MKXPZ_PLATFORM -> LINUX for iOS"
fi

# iOS 上 __APPLE__ 为真、但 MKXPZ_PLATFORM 已被上面改成 LINUX：config.cpp 有三处
# __APPLE__ 守卫引用了仅 macOS 存在的 Metal 逻辑——isMetalSupported() 仅
# MKXPZ_BUILD_XCODE 下声明（我们没定义，故未声明 → 'undeclared identifier'）；
# Apple arm64 默认开 Metal；以及 ANGLE 平台选择。iOS 走 GLES2，统一收紧为 macOS 专属。
if [ -f "$MKXP_SRC/src/config.cpp" ]; then
  sed -i '' \
    -e 's|^#if defined(__APPLE__) && defined(__aarch64__)$|#if defined(__APPLE__) \&\& defined(__aarch64__) \&\& (MKXPZ_PLATFORM == MKXPZ_PLATFORM_MACOS)|' \
    -e 's|^#ifdef __APPLE__$|#if defined(__APPLE__) \&\& (MKXPZ_PLATFORM == MKXPZ_PLATFORM_MACOS)|' \
    "$MKXP_SRC/src/config.cpp"
  echo "patched config.cpp Metal guards -> macOS-only"
fi

# SDL2_ttf 2.20.0 起把不透明结构体 _TTF_Font 改名为 TTF_Font（vcpkg 现装 2.24.0，
# 头文件为 typedef struct TTF_Font TTF_Font;）。mkxp-z v2.4.2 的 font.h/font.cpp 仍按
# 旧名 forward-declare/返回 _TTF_Font*，而 settingsmenu.cpp 经 SDL_ttf.h 拿到新类型
# TTF_Font*（其私有成员 p->font 即该类型）→ 'incompatible pointer types assigning to
# TTF_Font* from _TTF_Font*'。仅这两个文件引用该类型，统一改名对齐新版。
if [ -f "$MKXP_SRC/src/display/font.h" ]; then
  sed -i '' 's/_TTF_Font/TTF_Font/g' \
    "$MKXP_SRC/src/display/font.h" "$MKXP_SRC/src/display/font.cpp"
  echo "patched _TTF_Font -> TTF_Font (SDL2_ttf >= 2.20 opaque struct rename)"
fi

# iOS 禁用 system()：binding-mri.cpp 的「打开 URL」绑定用 std::system 拼 OPENCMD
# 启动外部程序（open/xdg-open/start），iPhone 上既无对应语义也编译不过
# （'system' is unavailable: not available on iOS）。与坑 #4 的 Ruby vm_dump.c
# 同法：直接把调用点替换为 0，功能静默降级为 no-op（返回 Qnil 不抛错）。
if [ -f "$MKXP_SRC/binding/binding-mri.cpp" ]; then
  sed -i '' 's/std::system(command\.c_str())/0/' "$MKXP_SRC/binding/binding-mri.cpp"
  echo "patched binding-mri.cpp std::system -> 0 (unavailable on iOS)"
fi

# iOS 兼容 shim（引擎适配，不动游戏工程）：
#  1) 顶层 def（实际落在 Object 上）自动以“委托 main 对象”的方式提升为 Kernel
#     单例方法——RGSS 允许 Kernel.pbXxx 显式接收者调用（宝可梦sp 的 Modular
#     Title Screen 等多处），MRI 严格私有语义报
#     "private method `pbShowCommands' called for module Kernel"（实测）；
#     同时保留 module Kernel 内 def -> module_function 的钩子；
#  2) getPlayTime 对 Audio/BGM 返回 -1——Modular Title Screen 依它计算“曲末重启”
#     （pbBGMStop + 视口压暗 51 帧 = “BGM 重启 + 画面闪一下”），mkxp 下时长算不准。
# 钩子在游戏脚本执行【前】装好，经 method_added 在方法定义完成时即时生效。
python3 - "$MKXP_SRC/binding/binding-mri.cpp" "$ROOT/scripts/mkxp-framework/ios_hook.rb" <<'PYEOF'
import sys
p = sys.argv[1]
ruby = open(sys.argv[2], encoding="utf-8").read()
s = open(p, encoding='utf-8').read()
anchor = "    while (true) {\n        for (long i = 0; i < scriptCount; ++i) {"
shim = (
    "    /* iOS compat hook (engine adaptation; game project untouched) */\n"
    '    static const char mkxpIosHook[] = R"HOOK(\n' + ruby + ')HOOK";\n'
    "    evalString(newStringUTF8(mkxpIosHook, sizeof(mkxpIosHook) - 1),\n"
    '               newStringUTF8("mkxp_ios_hook.rb", 16), NULL);\n'
)
if anchor in s and "mkxpIosHook" not in s:
    s = s.replace(anchor, shim + anchor, 1)
    open(p, "w", encoding="utf-8", newline="\n").write(s)
    print("patched binding-mri.cpp: raw-string hook v5 (from ios_hook.rb)")
else:
    print("binding-mri.cpp: anchor missing or already patched (ok)")
PYEOF

# iOS 兼容：Windows 游戏把“大小写不敏感”当理所当然（如 Modular Title Screen 会把
# 叠层文件名 upcase 成 OVERLAYS/SCROLLING001），iOS 文件系统区分大小写：
#   - FileSystem::exists 走 PHYSFS_exists（敏感）→ pbResolveBitmap 判否 →
#     插件 fallback 到错误的 overlay.png（红色图案被拉伸全屏 = “满屏红线”）；
#   - openReadRaw（音频等）同样敏感。
# 修法：两者先经 desensitize()（pathCache 小写->实际名映射，mkxp-z 自带）再查。
python3 - "$MKXP_SRC/src/filesystem/filesystem.cpp" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old_exists = "bool FileSystem::exists(const char *filename) {\n  return PHYSFS_exists(normalize(filename, false, false).c_str());\n}"
new_exists = ("bool FileSystem::exists(const char *filename) {\n"
              "  std::string nm = normalize(filename, false, false);\n"
              "  if (PHYSFS_exists(nm.c_str()))\n"
              "    return true;\n"
              "  /* iOS engine adaptation: games written on Windows take case-\"\n"
              "   * insensitivity for granted (plugin code may upcase filenames);\n"
              "   * resolve via the pathCache lower->actual mapping when possible. */\n"
              "  if (p->havePathCache) {\n"
              "    std::string lower = nm;\n"
              "    for (size_t i = 0; i < lower.size(); ++i)\n"
              "      lower[i] = tolower(lower[i]);\n"
              "    if (p->pathCache.contains(lower))\n"
              "      return PHYSFS_exists(p->pathCache[lower].c_str());\n"
              "  }\n"
              "  return false;\n"
              "}")
old_raw = "PHYSFS_File *handle = PHYSFS_openRead(normalize(filename, 0, 0).c_str());"
new_raw = ("std::string nm_raw = normalize(filename, 0, 0);\n"
           "  if (p->havePathCache && !PHYSFS_exists(nm_raw.c_str())) {\n"
           "    std::string lower = nm_raw;\n"
           "    for (size_t i = 0; i < lower.size(); ++i)\n"
           "      lower[i] = tolower(lower[i]);\n"
           "    if (p->pathCache.contains(lower))\n"
           "      nm_raw = p->pathCache[lower];\n"
           "  }\n"
           "  PHYSFS_File *handle = PHYSFS_openRead(nm_raw.c_str());")
changed = False
if old_exists in s:
    s = s.replace(old_exists, new_exists, 1)
    changed = True
if old_raw in s:
    s = s.replace(old_raw, new_raw, 1)
    changed = True
if changed:
    open(p, 'w', encoding='utf-8').write(s)
    print("patched filesystem.cpp: case-insensitive exists/openReadRaw via pathCache")
else:
    print("filesystem.cpp: anchors missing or already patched (ok)")
PYEOF

# 空格不敏感解析：游戏请求 "Fusion Pixel 12px Monospaced zh_hans.ttf"（带空格），
# 磁盘上却只有 "FusionPixel12pxMonospacedzh_hans.ttf"（无空格）→ 字体回退 →
# 度量不一致 → 消息文字漏末尾 1-2 字。把 pathCache 的键与查找统一按“去空格+
# 小写”归一（与大小写修复同一机制）。
python3 - "$MKXP_SRC/src/filesystem/filesystem.cpp" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'normKey' in s:
    print("filesystem.cpp: space-insensitive already patched (ok)")
else:
    n = 0
    # 1) 归一化助手（小写+去空格）
    helper = ("static void strTolower(std::string &str) {\n"
              "  for (size_t i = 0; i < str.size(); ++i)\n"
              "    str[i] = tolower(str[i]);\n"
              "}\n"
              "/* iOS engine adaptation: Windows games treat spaces as insignificant in\n"
              "   asset names too (font file shipped without the spaces of its name). */\n"
              "static std::string normKey(const std::string &in) {\n"
              "  std::string out;\n"
              "  out.reserve(in.size());\n"
              "  for (size_t i = 0; i < in.size(); ++i)\n"
              "    if (in[i] != ' ')\n"
              "      out.push_back((char)tolower(in[i]));\n"
              "  return out;\n"
              "}\n")
    old_helper = ("static void strTolower(std::string &str) {\n"
                  "  for (size_t i = 0; i < str.size(); ++i)\n"
                  "    str[i] = tolower(str[i]);\n"
                  "}\n")
    if old_helper in s:
        s = s.replace(old_helper, helper, 1); n += 1
    # 2) 枚举建缓存时用归一键
    old_cache = "std::string lowerCase = mixedCase;\n  strTolower(lowerCase);"
    if old_cache in s:
        s = s.replace(old_cache, "std::string lowerCase = normKey(mixedCase);", 1); n += 1
    # 3) openRead 查找键归一（原位压缩空格并更新 len）
    old_lookup = ("  if (p->havePathCache)\n"
                  "    for (size_t i = 0; i < len; ++i)\n"
                  "      buffer[i] = tolower(buffer[i]);")
    new_lookup = ("  if (p->havePathCache)\n"
                  "  {\n"
                  "    for (size_t i = 0; i < len; ++i)\n"
                  "      buffer[i] = tolower(buffer[i]);\n"
                  "    size_t w = 0;\n"
                  "    for (size_t i = 0; i < len; ++i)\n"
                  "      if (buffer[i] != ' ')\n"
                  "        buffer[w++] = buffer[i];\n"
                  "    buffer[w] = '\\0';\n"
                  "    len = w;\n"
                  "  }")
    if old_lookup in s:
        s = s.replace(old_lookup, new_lookup, 1); n += 1
    # 4) exists / openReadRaw 的回退查找同样归一
    old_l1 = "      lower[i] = tolower(lower[i]);\n    if (p->pathCache.contains(lower))"
    new_l1 = ("      lower[i] = tolower(lower[i]);\n"
              "    std::string t; t.reserve(lower.size());\n"
              "    for (size_t i = 0; i < lower.size(); ++i)\n"
              "      if (lower[i] != ' ') t.push_back(lower[i]);\n"
              "    lower = t;\n"
              "    if (p->pathCache.contains(lower))")
    c1 = s.count(old_l1)
    s = s.replace(old_l1, new_l1)
    n += c1
    # 5) fileLists 里的文件名成员同样去空格（openRead 用归一后的 file 比对）
    old_fn = ("    std::string lowerFilename(fname);\n"
              "    strTolower(lowerFilename);\n"
              "    list.push_back(lowerFilename);")
    if old_fn in s:
        s = s.replace(old_fn,
                      "    list.push_back(normKey(fname));", 1)
        n += 1
    # 6) desensitize（字体等直接走它的路径）也归一（只改声明行，后续 transform 幂等无害）
    old_de = "  std::string fn_lower(filename);"
    if old_de in s:
        s = s.replace(old_de, "  std::string fn_lower = normKey(filename);", 1)
        n += 1
    if n >= 3:
        open(p, 'w', encoding='utf-8').write(s)
        print(f"patched filesystem.cpp: space-insensitive resolution ({n} sites)")
    else:
        print(f"filesystem.cpp: space-insensitive anchors incomplete ({n})")
PYEOF

# 混合帧限速（iPhone 11 等 60Hz 屏的顺滑度）：
# FPSLimiter 用 SDL_Delay/nanosleep 粗睡，iOS 上恒过睡 1-2ms，idealDiff 补偿环
# 会把过睡变成 40fps 帧间隔的额外抖动（叠加在 60Hz 采样的固有 judder 上）。
# 改为“粗睡大头 + 末 2ms 忙等”，把帧间隔抖动压到 ~0.1ms（约 5% 单核开销）。
python3 - "$MKXP_SRC/src/display/graphics.cpp" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'spinTicks' in s:
    print("graphics.cpp: hybrid limiter already patched (ok)")
else:
    i = s.find("void delayTicks(uint64_t ticks)")
    if i < 0:
        print("graphics.cpp: delayTicks not found")
    else:
        j = s.find("#endif", i)
        k = s.find("    }", j)
        if j < 0 or k < 0:
            print("graphics.cpp: delayTicks end not found")
        else:
            ls = s.rfind("\n", 0, i) + 1
            end = k + len("    }")
            newfn = (
"    void delayTicks(uint64_t ticks) {\n"
"        /* iOS engine adaptation (hybrid limiter): SDL_Delay granularity is\n"
"         * ~1-2ms and always oversleeps; the idealDiff compensation then turns\n"
"         * that into visible frame-interval wobble at 40fps. Coarse-sleep the\n"
"         * bulk, busy-spin the last ~2ms for tight pacing (~5% of one core). */\n"
"        const uint64_t spinTicks = tickFreqMS * 2; /* 2ms */\n"
"        if (ticks > spinTicks) {\n"
"            SDL_Delay((ticks - spinTicks) / tickFreqMS);\n"
"            uint64_t deadline = SDL_GetPerformanceCounter() + spinTicks;\n"
"            while (SDL_GetPerformanceCounter() < deadline) { }\n"
"        } else if (ticks > 0) {\n"
"            uint64_t deadline = SDL_GetPerformanceCounter() + ticks;\n"
"            while (SDL_GetPerformanceCounter() < deadline) { }\n"
"        }\n"
"    }")
            s = s[:ls] + newfn + s[end:]
            open(p, 'w', encoding='utf-8').write(s)
            print("patched graphics.cpp: hybrid frame limiter (coarse sleep + 2ms spin)")
PYEOF

# 转场图缺失兜底：Graphics.transition(duration, "Graphics/Maps/xxx") 若图缺失，
# `new Bitmap(filename)` 会抛异常 → transition 中途夭折 → 冻结态不解 →
# 场所转移黑屏超长（实测 真新镇.png 缺失）。回退为默认淡入淡出。
python3 - "$MKXP_SRC/src/display/graphics.cpp" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = "    Bitmap *transMap = *filename ? new Bitmap(filename) : 0;"
new = ("    Bitmap *transMap = 0;\n"
       "    if (*filename) {\n"
       "        /* iOS engine adaptation: a missing custom transition graphic used to\n"
       "         * throw out of Graphics::transition, leaving the screen frozen black\n"
       "         * for the whole transfer. Fall back to the simple fade instead. */\n"
       "        try {\n"
       "            transMap = new Bitmap(filename);\n"
       "        } catch (const Exception &e) {\n"
       "            transMap = 0;\n"
       "        }\n"
       "    }")
if old in s and 'Fall back to the simple fade' not in s:
    s = s.replace(old, new, 1)
    open(p, 'w', encoding='utf-8').write(s)
    print("patched graphics.cpp: missing transition graphic -> simple fade fallback")
else:
    print("graphics.cpp: transition anchor missing or already patched (ok)")
PYEOF

# 解码位图 LRU 缓存（按路径）：拍照点进场、菜单图标等"同一路径反复加载"的
# 场景跳过磁盘 IO + PNG 解码（真新镇第 9 行拍照点=PartyPicture 进场时同步
# 加载 5+ 张跟随精灵表，iPhone 上解码耗时=可感知卡顿；PC 快察觉不到）。
# 内存上限 64MB，超大图不缓存；GIF 路径不缓存（动画语义复杂）。
python3 - "$MKXP_SRC/src/display/bitmap.cpp" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'MKXPIosBmpCache' in s:
    print("bitmap.cpp: decoded-bitmap cache already patched (ok)")
else:
    cache_code = (
"/* iOS engine adaptation: decoded-bitmap LRU cache keyed by path.\n"
" * Repeated loads of the same asset (photo-spot entry, menus) skip disk IO\n"
" * and PNG decode. Memory capped; oversized images are not cached. */\n"
"#include <map>\n"
"#include <list>\n"
"#include <string>\n"
"#include <mutex>\n"
"namespace MKXPIosBmpCache {\n"
"struct Entry { SDL_Surface *surf; size_t bytes; };\n"
"static std::map<std::string, Entry> g_map;\n"
"static std::list<std::string> g_order;\n"
"static size_t g_bytes = 0;\n"
"static std::mutex g_mtx;\n"
"static const size_t CAP_BYTES = 64u * 1024 * 1024;\n"
"static SDL_Surface *get(const std::string &k)\n"
"{\n"
"    std::lock_guard<std::mutex> lock(g_mtx);\n"
"    std::map<std::string, Entry>::iterator it = g_map.find(k);\n"
"    if (it == g_map.end())\n"
"        return 0;\n"
"    g_order.remove(k);\n"
"    g_order.push_back(k);\n"
"    return it->second.surf;\n"
"}\n"
"static void put(const std::string &k, SDL_Surface *s)\n"
"{\n"
"    std::lock_guard<std::mutex> lock(g_mtx);\n"
"    if (g_map.count(k))\n"
"        return;\n"
"    size_t bytes = (size_t)s->w * (size_t)s->h * 4;\n"
"    if (bytes > CAP_BYTES)\n"
"        return;\n"
"    while (g_bytes + bytes > CAP_BYTES && !g_order.empty())\n"
"    {\n"
"        std::string oldKey = g_order.front();\n"
"        g_order.pop_front();\n"
"        std::map<std::string, Entry>::iterator it = g_map.find(oldKey);\n"
"        if (it != g_map.end())\n"
"        {\n"
"            g_bytes -= it->second.bytes;\n"
"            SDL_FreeSurface(it->second.surf);\n"
"            g_map.erase(it);\n"
"        }\n"
"    }\n"
"    Entry e;\n"
"    e.surf = SDL_DuplicateSurface(s);\n"
"    e.bytes = bytes;\n"
"    if (!e.surf)\n"
"        return;\n"
"    g_map[k] = e;\n"
"    g_bytes += bytes;\n"
"    g_order.push_back(k);\n"
"}\n"
"}\n")
    old_ctor = "Bitmap::Bitmap(const char *filename)\n{\n    BitmapOpenHandler handler;"
    new_ctor = cache_code + "\n" + old_ctor
    c1 = old_ctor in s
    old_swap = "    SDL_Surface *imgSurf = handler.surface;"
    new_swap = ("    /* iOS engine adaptation: decoded-surface LRU cache */\n"
                "    std::string cacheKey(filename);\n"
                "    SDL_Surface *cachedSurf = MKXPIosBmpCache::get(cacheKey);\n"
                "    SDL_Surface *imgSurf;\n"
                "    bool cacheMiss;\n"
                "    if (cachedSurf)\n"
                "    {\n"
                "        if (handler.surface) SDL_FreeSurface(handler.surface);\n"
                "        imgSurf = SDL_DuplicateSurface(cachedSurf);\n"
                "        cacheMiss = false;\n"
                "    }\n"
                "    else\n"
                "    {\n"
                "        imgSurf = handler.surface;\n"
                "        cacheMiss = true;\n"
                "    }")
    c2 = old_swap in s
    old_upload = "        TEX::uploadImage(p->gl.width, p->gl.height, imgSurf->pixels, GL_RGBA);\n        \n        SDL_FreeSurface(imgSurf);"
    new_upload = ("        TEX::uploadImage(p->gl.width, p->gl.height, imgSurf->pixels, GL_RGBA);\n"
                  "        \n"
                  "        if (cacheMiss)\n"
                  "            MKXPIosBmpCache::put(cacheKey, imgSurf);\n"
                  "        SDL_FreeSurface(imgSurf);")
    c3 = old_upload in s
    if c1 and c2 and c3:
        s = s.replace(old_ctor, new_ctor, 1)
        s = s.replace(old_swap, new_swap, 1)
        s = s.replace(old_upload, new_upload, 1)
        open(p, 'w', encoding='utf-8').write(s)
        print("patched bitmap.cpp: decoded-bitmap LRU cache (64MB cap)")
    else:
        print(f"bitmap.cpp: anchors missing (ctor={c1} swap={c2} upload={c3})")
PYEOF

# ---------- 3a-2. iOS 横线修复：tainted 区域非法矩形护栏 ----------
# 设备日志里反复出现 "pixman_region_union_rect: Invalid rectangle passed"，
# 来源是 Bitmap::addTaintedArea / substractTaintedArea 收到宽高<=0 或越界的
# 矩形（blit 整块被裁掉 / Plane 零范围）。pixman 拒绝该矩形并污染 tainted
# 区域，导致下一帧 GL 子上传用错矩形 -> 地图出现横向错位带（室内也有轻微）。
# 此补丁在 pristine 上、framework-entry.patch 之前应用，锚点稳定。
python3 - "$MKXP_SRC/src/display/bitmap.cpp" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

# Guard 1: addTaintedArea
old_add = (
"    void addTaintedArea(const IntRect &rect)\n"
"    {\n"
"        IntRect norm = normalizedRect(rect);\n"
"        pixman_region_union_rect\n"
"        (&tainted, &tainted, norm.x, norm.y, norm.w, norm.h);\n"
"    }")
new_add = (
"    void addTaintedArea(const IntRect &rect)\n"
"    {\n"
"        IntRect norm = normalizedRect(rect);\n"
"        /* iOS: a fully-clipped / zero-extent blit yields norm.w<=0 or\n"
"         * norm.h<=0; pixman rejects it (\"Invalid rectangle passed\") and\n"
"         * corrupts the tainted region, so the next GL sub-upload uses a\n"
"         * wrong rectangle -> horizontal band artifacts. Skip + log. */\n"
"        if (norm.w <= 0 || norm.h <= 0)\n"
"        {\n"
"            static int _skipped = 0;\n"
"            if (_skipped < 30)\n"
"                fprintf(stderr, \"rgss: tainted skip w=%d h=%d x=%d y=%d\\\",\n"
"                        norm.w, norm.h, norm.x, norm.y), _skipped++;\n"
"            return;\n"
"        }\n"
"        pixman_region_union_rect\n"
"        (&tainted, &tainted, norm.x, norm.y, norm.w, norm.h);\n"
"    }")

# Guard 2: substractTaintedArea
old_sub = (
"    void substractTaintedArea(const IntRect &rect)\n"
"    {\n"
"        if (!touchesTaintedArea(rect))\n"
"            return;\n"
"        \n"
"        pixman_region16_t m_reg;\n"
"        pixman_region_init_rect(&m_reg, rect.x, rect.y, rect.w, rect.h);\n"
"        \n"
"        pixman_region_subtract(&tainted, &m_reg, &tainted);\n"
"        \n"
"        pixman_region_fini(&m_reg);\n"
"    }")
new_sub = (
"    void substractTaintedArea(const IntRect &rect)\n"
"    {\n"
"        if (!touchesTaintedArea(rect))\n"
"            return;\n"
"        /* iOS: guard invalid rect (zero/negative extent) for pixman */\n"
"        if (rect.w <= 0 || rect.h <= 0)\n"
"            return;\n"
"        \n"
"        pixman_region16_t m_reg;\n"
"        pixman_region_init_rect(&m_reg, rect.x, rect.y, rect.w, rect.h);\n"
"        \n"
"        pixman_region_subtract(&tainted, &m_reg, &tainted);\n"
"        \n"
"        pixman_region_fini(&m_reg);\n"
"    }")

c1 = old_add in s
c2 = old_sub in s
if c1 and c2:
    s = s.replace(old_add, new_add, 1)
    s = s.replace(old_sub, new_sub, 1)
    open(p, 'w', encoding='utf-8').write(s)
    print("patched bitmap.cpp: tainted-region rect guards (iOS horizontal-band fix)")
else:
    print(f"bitmap.cpp: tainted anchors missing (add={c1} sub={c2})")
PYEOF

# ---------- 3a-3. iOS 文本缺字诊断：drawText 视口裁剪日志 ----------
# dtp 追踪已确认到达 draw_text 的字符串完整（valid=true，无丢字）；且 drawText
# 会把文本 squeeze 进 rect.w（水平不裁切）。所以“缺字”只能是逐字绘制时该字的
# x 超出窗口位图（被视口裁掉）。本补丁在文本表面被 bitmap 边界裁掉时记录，用于
# 一锤定音确认“缺字=视口裁切”（典型诱因：自定义像素字体 FusionPixelMonoPatched
# 在 iOS 未加载成功、回退默认字体导致整行略宽溢出）。
python3 - "$MKXP_SRC/src/display/bitmap.cpp" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old_clip = (
"                if (inters.w != txtRect.w || inters.h != txtRect.h)\n"
"                {\n"
"                    /* Clip the text surface */\n"
"                    subSrcX = inters.x - txtRect.x;\n")
new_clip = (
"                if (inters.w != txtRect.w || inters.h != txtRect.h)\n"
"                {\n"
"                    /* Clip the text surface */\n"
"                    /* iOS: text surface partially outside the bitmap == the window\n"
"                     * viewport. The game lays out per-char x with its font metrics;\n"
"                     * if the requested custom font failed to load and mkxp fell back\n"
"                     * to a default, metrics differ -> line overflow -> last chars\n"
"                     * clipped. Log to confirm the missing-char cause. */\n"
"                    static int _clip = 0;\n"
"                    if (_clip < 40)\n"
"                    {\n"
"                        fprintf(stderr, \"rgss: text clipped surf=%dx%d vis=%dx%d x=%d y=%d str=%s\\\",\n"
"                                txtRect.w, txtRect.h, inters.w, inters.h, txtRect.x, txtRect.y, str);\n"
"                        _clip++;\n"
"                    }\n"
"                    subSrcX = inters.x - txtRect.x;\n")
if old_clip in s:
    s = s.replace(old_clip, new_clip, 1)
    open(p, 'w', encoding='utf-8').write(s)
    print("patched bitmap.cpp: drawText viewport-clip diagnostic (iOS missing-char triage)")
else:
    print("bitmap.cpp: drawText clip anchor missing")
PYEOF

# ---------- 3b. 框架化补丁（M1-A：把独立 app 变成可嵌入库） ----------
# framework-entry.patch（git diff，LF 行尾）：
#   1. src/main.cpp: int main() -> extern "C" int mkxp_z_main()
#      （原符号会与 Flutter App 的 main 冲突，且需按 C 约定被框架层调用）
#   2. src/input/input.cpp: applyBindingDesc 里重建 rgssKey->scancode 反查表
#      （带 mutex：RGSS 线程写、UI 线程读）
# mkxp_framework.cpp 拷入 src/ 后由 CMake 的 SRC 清单编译（mkxp_run/mkxp_key/mkxp_quit）。
if [ -f "$MKXP_SRC/.git/config" ]; then
  # 首选严格 git apply（能精确暴露真正的源码不匹配）；若因 hunk 行数写错而失败，
  # 回退到 patch -p1（按上下文模糊匹配，对计数不敏感），避免手工维护 diff 时计数漂移
  # 导致整块 "corrupt patch"。两者都失败才真正报错。
  git -C "$MKXP_SRC" apply "$ROOT/scripts/mkxp-framework/framework-entry.patch" 2>/dev/null \
   || { echo "WARN: git apply 失败，回退 patch -p1 -f（可能静默丢弃不匹配 hunk）"; \
        patch -p1 -f --no-backup-if-mismatch -d "$MKXP_SRC" \
        < "$ROOT/scripts/mkxp-framework/framework-entry.patch" \
        || { echo "FATAL: framework-entry.patch 应用失败（v2.4.2 源码对不上？）"; exit 1; }; }
  echo "applied framework-entry.patch"

  # 零死角校验：确认关键补丁 hunk 真的落进源码（避免 patch -f 静默丢弃）。
  # 任何签名缺失 = 对应修复没生效 = 构建直接失败，绝不让“试探包”流到真机。
  for sig in "rgss: bgm heal attempt" "rgss: slow decode" "rgss: decode-cache" "rgss: tainted skip" "rgss: text clipped" "tilesets/" "swapInterval="; do
    if ! grep -rqF "$sig" "$MKXP_SRC/src"; then
      echo "FATAL: 关键补丁签名缺失: $sig （hunk 可能被丢弃，修复未生效）"; exit 1
    fi
  done
  echo "verified: all critical patch signatures present"
else
  echo "FATAL: $MKXP_SRC 不是 git 仓库，无法 apply framework-entry.patch"
  exit 1
fi

# BGM 诊断日志：Audio.bgm_play / bgm_stop 调用落盘（定位“切图后 BGM 消失”）。
# 注意必须在 framework-entry.patch 之后执行——它也会改 audio-binding.cpp，
# 先改会破坏官方补丁的 hunk 上下文（曾致 2/10 hunks failed → FATAL）。
python3 - "$MKXP_SRC/binding/audio-binding.cpp" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = "    GUARD_EXC( shState->audio().bgmPlay(filename, volume, pitch, pos, track); )"
new = ("    {\n"
       "      /* RGSS 语义：同一 BGM 重复 bgm_play 时【继续播放不重启】——PC 版 RGSS1\n"
       "        * 引擎内置该行为（换地图同曲不换），mkxp 缺失导致每次切图/转移都重启\n"
       "        * 混音通道（= BGM 反复重头 + 顿挫）。仅当 BGM 被 bgm_stop / bgm_fade\n"
       "        * 显式终止后才允许重新播放。 */\n"
       "      if (s_bgmActive && s_curBgm == filename) {\n"
       "        fprintf(stderr, \"[mkxp-audio] continue same bgm '%s' (no restart)\\n\", filename);\n"
       "        return Qnil;\n"
       "      }\n"
       "      s_curBgm = filename;\n"
       "      s_bgmActive = true;\n"
       "      /* 带扩展名探测（音频后端内部补 .ogg/.wav/.mp3），仅诊断用 */\n"
       "      bool fex = shState->fileSystem().exists(filename)\n"
       "              || shState->fileSystem().exists((std::string(filename) + \".ogg\").c_str())\n"
       "              || shState->fileSystem().exists((std::string(filename) + \".wav\").c_str())\n"
       "              || shState->fileSystem().exists((std::string(filename) + \".mp3\").c_str());\n"
       "      fprintf(stderr, \"[mkxp-audio] bgm_play '%s' vol=%d pitch=%d exists=%d\\n\",\n"
       "              filename, volume, pitch, (int)fex);\n"
       "      if (!fex) {\n"
       "        fprintf(stderr, \"[mkxp-audio] !! missing, Audio/BGM contents:\");\n"
       "        PHYSFS_enumerate(\"Audio/BGM\", bgmEnumCb, nullptr);\n"
       "        fprintf(stderr, \"\\n\");\n"
       "      }\n"
       "    }\n"
       "    GUARD_EXC( shState->audio().bgmPlay(filename, volume, pitch, pos, track); )")
old_cb = "RB_METHOD(audio_bgmPlay)"
new_cb = ("static std::string s_curBgm;\n"
          "static bool s_bgmActive = false;\n"
          "\n"
          "static PHYSFS_EnumerateCallbackResult bgmEnumCb(void *, const char *, const char *fname) {\n"
          "  fprintf(stderr, \" %s\", fname);\n"
          "  return PHYSFS_ENUM_OK;\n"
          "}\n"
          "\n"
          "RB_METHOD(audio_bgmPlay)")
old2 = "RB_METHOD(audio_bgmStop)\n{\n    RB_UNUSED_PARAM;\n    int track = -127;\n    rb_get_args(argc, argv, \"|i\", &track RB_ARG_END);\n    shState->audio().bgmStop(track);"
new2 = ("RB_METHOD(audio_bgmStop)\n{\n    RB_UNUSED_PARAM;\n    int track = -127;\n    rb_get_args(argc, argv, \"|i\", &track RB_ARG_END);\n"
        "    fprintf(stderr, \"[mkxp-audio] bgm_stop track=%d\\n\", track);\n"
        "    s_curBgm.clear();\n"
        "    s_bgmActive = false;\n"
        "    shState->audio().bgmStop(track);")
old3 = ("RB_METHOD(audio_bgmFade)\n"
        "{\n"
        "    RB_UNUSED_PARAM;\n"
        "    int time;\n"
        "    int track = -127;\n"
        "    rb_get_args(argc, argv, \"i|i\", &time, &track RB_ARG_END);\n"
        "    shState->audio().bgmFade(time, track);")
new3 = ("RB_METHOD(audio_bgmFade)\n"
        "{\n"
        "    RB_UNUSED_PARAM;\n"
        "    int time;\n"
        "    int track = -127;\n"
        "    rb_get_args(argc, argv, \"i|i\", &time, &track RB_ARG_END);\n"
        "    s_curBgm.clear();\n"
        "    s_bgmActive = false;\n"
        "    shState->audio().bgmFade(time, track);")
changed = False
# 回调定义必须先插（守卫以定义文本为准；调用点文本里也含 bgmEnumCb，不能用作守卫）
if old_cb in s and 'static PHYSFS_EnumerateCallbackResult bgmEnumCb' not in s:
    s = s.replace(old_cb, new_cb, 1)
    changed = True
if old in s:
    s = s.replace(old, new, 1)
    changed = True
if old2 in s:
    s = s.replace(old2, new2, 1)
    changed = True
if old3 in s:
    s = s.replace(old3, new3, 1)
    changed = True
if changed:
    if '#include <cstdio>' not in s:
        s = s.replace('#include "audio.h"',
                      '#include <cstdio>\n#include <physfs.h>\n#include "filesystem.h"\n#include "audio.h"', 1)
    open(p, 'w', encoding='utf-8').write(s)
    print("patched audio-binding.cpp: bgm RGSS continue-semantics + diagnostics")
else:
    print("audio-binding.cpp: anchors missing or already patched (ok)")
PYEOF

# ios-winsize.patch：修 iOS 黑屏（画面缩在窗口左下角）。
# 根因：GraphicsPrivate::winSize 在构造时被初始化成 config 的 defScreenW/H(512x384)，
# 且只在收到 SDL resize 事件时才更新；iOS 上 SDL 直接建全屏窗口(828x1792)且从不派发
# resize 事件 -> winSize 永远停在 512x384 -> GLMeta::blitBeginScreen(winSize) 把画面
# blit 到窗口左下角的小方块里，其余为黑（表现为黑屏）。补丁让首帧用真实的
# SDL_GetWindowSize / SDL_GL_GetDrawableSize 同步一次，之后 mkxp 自身的
# scOffset/scSize 会算出正确的 letterbox。
git -C "$MKXP_SRC" apply "$ROOT/scripts/mkxp-framework/ios-winsize.patch" 2>/dev/null \
 || patch -p1 -f --no-backup-if-mismatch -d "$MKXP_SRC" \
      < "$ROOT/scripts/mkxp-framework/ios-winsize.patch" \
 || { echo "FATAL: ios-winsize.patch 应用失败（v2.4.2 源码对不上？）"; exit 1; }
echo "applied ios-winsize.patch (iOS 黑屏修复：winSize 同步真实窗口尺寸)"

cp -f "$ROOT/scripts/mkxp-framework/mkxp_framework.cpp" "$MKXP_SRC/src/mkxp_framework.cpp"
echo "installed mkxp_framework.cpp"
cp -f "$ROOT/scripts/mkxp-framework/ios_embed.mm" "$MKXP_SRC/src/ios_embed.mm"
echo "installed ios_embed.mm (Objective-C++, UIKit 窗口提升)"

# ---------- 4. 编译 mkxp-z 为静态库 libmkxp.a（手搓 CMake，链接 vcpkg + 静态 Ruby） ----------
# 确保构建工具（CI macos runner 可能缺 xxd；默认用 Unix Makefiles 生成器，无需 ninja）
brew install xxd >/dev/null 2>&1 || true
command -v xxd >/dev/null 2>&1 || brew reinstall xxd >/dev/null 2>&1 || true
MKXP_CMAKE=$ROOT/scripts/mkxp-cmake
cmake -B "$MKXP_SRC/build-ios" \
  -S "$MKXP_CMAKE" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=$ARCH \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_IOS \
  -DCMAKE_BUILD_TYPE=Release \
  -DMKXP_SRC="$MKXP_SRC" \
  -DVCPKG_INSTALL="$VCPKG_INSTALL" \
  -DSDLSOUND_PREFIX="$SDLSOUND_PREFIX" \
  -DRUBY_INC="$RUBY_INC" \
  -DRUBY_LIB="$RUBY_LIB"
cmake --build "$MKXP_SRC/build-ios" -j"$(sysctl -n hw.ncpu)"
echo "mkxp static lib: $(ls -1 "$MKXP_SRC"/build-ios/libmkxp.a 2>/dev/null || echo NONE)"

# ---------- 5. 合并为静态 framework ----------
echo "== package MKXP.framework =="
rm -rf "$FW_DIR"
mkdir -p "$FW_DIR/Headers" "$FW_DIR/Modules"

# 收集 .a 分两组（App 侧链接策略：核心 force_load + 依赖按需加载，见 ios-link-mkxp.rb）：
#   CORE  = libmkxp + ruby + SDL2_sound —— 合并成框架二进制，-force_load 全量载入
#           （顺序无关，保证引擎完整）；
#   DEPS  = vcpkg 各静态库 —— 单独放进框架 Libs/，在 -force_load 之后按需加载。
#           按需加载天然去重：同一符号被多个归档定义（libc++/fmt 的符号被嵌进
#           libopenal/libfmt/libmkxp 多处）时 ld 只取第一个定义，不会 duplicate；
#           若把这些也 force_load 进来，实测炸 454 个 duplicate symbols。
# 去重与排除：
#   - 按真实路径去重：vcpkg 的 libpng.a 是 libpng16.a 的符号链接，find 会同时
#     命中两个路径，同一份内容会进两遍 Libs；
#   - 排除 libSDL2main.a：iOS 上 SDL 不接管 main，且 main 已改名 mkxp_z_main
#     （SDL_main 引用由 mkxp_framework.cpp 的桩兜底）。
CORE_LIBS=()
[ -f "$MKXP_SRC/build-ios/libmkxp.a" ] && CORE_LIBS+=("$MKXP_SRC/build-ios/libmkxp.a")
CORE_LIBS+=("$RUBY_LIB")
# SDL2_sound 是 vcpkg 外的自编静态库——曾漏合并，导致 App 链接期
# Sound_Init/Sound_Decode 等齐 undefined。
[ -f "$SDLSOUND_PREFIX/lib/libSDL2_sound.a" ] && CORE_LIBS+=("$SDLSOUND_PREFIX/lib/libSDL2_sound.a")

DEP_LIBS=()
SEEN=""
while IFS= read -r f; do
  real=$(python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$f")
  case " ${SEEN} " in *" ${real} "*) continue ;; esac
  SEEN="${SEEN} ${real}"
  DEP_LIBS+=("${real}")
done < <(find "$VCPKG_INSTALL/lib" -name '*.a' ! -name 'libSDL2main.a' | sort)

libtool -static -o "$FW_DIR/MKXP" "${CORE_LIBS[@]}"
mkdir -p "$FW_DIR/Libs"
for a in "${DEP_LIBS[@]}"; do cp -f "$a" "$FW_DIR/Libs/$(basename "$a")"; done
echo "framework core: $(ls -l "$FW_DIR/MKXP" | awk '{print $5}') bytes; deps: ${#DEP_LIBS[@]} 个 .a 进 Libs/"

# ---------- 5b. 跨归档符号冲突诊断 ----------
# 按需加载不报 duplicate，但这里仍对账全部输入，输出 COLLISION 行（含涉及的归档），
# 供 build-mkxp.yml 的发布步骤推到 ci-status，便于观察依赖面变化。
echo "== 跨归档符号冲突诊断（CORE+DEPS 全量） =="
SYMMAP="$ROOT/deps/symmap.txt"
: > "$SYMMAP"
for a in "${CORE_LIBS[@]}" "${DEP_LIBS[@]}"; do
  b=$(basename "$a")
  nm -g "$a" 2>/dev/null | grep -v '):$' | awk 'NF>=3 {print $NF}' | sort -u \
    | awk -v b="$b" '{print $1, b}'
done | sort -u > "$SYMMAP"
awk '{print $1}' "$SYMMAP" | uniq -d > "$ROOT/deps/dupsyms.txt"
DUPN=$(wc -l < "$ROOT/deps/dupsyms.txt" | tr -d ' ')
echo "COLLISION_COUNT $DUPN"
head -100 "$ROOT/deps/dupsyms.txt" | while read -r sym; do
  files=$(grep -m 8 "^$sym " "$SYMMAP" | awk '{print $2}' | tr '\n' ',')
  echo "COLLISION $sym -> $files"
done

# 公开头（供桥接调用 mkxp_run）
cat > "$FW_DIR/Headers/MKXP.h" <<'EOF'
#ifndef MKXP_H
#define MKXP_H
#ifdef __cplusplus
extern "C" {
#endif
// 启动 MKXP 运行 gamePath 下的 RGSS 游戏（SDL 自建全屏窗口，详见 README「嵌入方式决策」）。
// 必须在后台线程调用（原 eventThread.process() 阻塞）。返回 0 成功。
int mkxp_run(const char* gamePath);
void mkxp_key(int rgssKey, int down);
void mkxp_quit(void);
// >0 = 引擎已把第一帧画面送上屏（Flutter 加载提示据此收起）
int mkxp_ios_firstFrameShown(void);
#ifdef __cplusplus
}
#endif
#endif
EOF

cat > "$FW_DIR/Modules/module.modulemap" <<'EOF'
framework module MKXP {
  header "MKXP.h"
  export *
}
EOF

cat > "$FW_DIR/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>MKXP</string>
  <key>CFBundleIdentifier</key><string>com.yourapp.mkxp</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>MinimumOSVersion</key><string>14.0</string>
</dict></plist>
EOF

echo "== MKXP.framework built =="
ls -lh "$FW_DIR/MKXP"
echo "== [$(date)] done =="
