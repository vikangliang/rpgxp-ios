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
if [ ! -d "$VCPKG/.git" ]; then
  git clone --depth 1 https://github.com/microsoft/vcpkg "$VCPKG"
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
  sdl2 sdl2-image sdl2-ttf \
  physfs openal-soft \
  libtheora libvorbis libogg \
  freetype pixman libpng libjpeg-turbo zlib uchardet
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
    export CPPFLAGS="-I$STUB -I$PREFIX/include"
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
      cflags="$ARCH_FLAGS" LDFLAGS="$ARCH_FLAGS" \
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
    make libruby.3.3-static.a -j"$(sysctl -n hw.ncpu)" \
      MINIRUBY="$HOST_RUBY" BUILTRUBY="$HOST_RUBY" PREP="$HOST_RUBY"
    # 交叉编译不能跑 make install（会执行目标架构二进制），手动收集产物。
    # 静态库可能叫 libruby.a 或 libruby-static.a，挑存在的那个。
    mkdir -p "$PREFIX/lib" "$PREFIX/include/ruby"
    RUBY_A=""
    [ -f libruby.3.3-static.a ] && RUBY_A=libruby.3.3-static.a
    [ -f libruby-static.a ] && RUBY_A=libruby-static.a
    [ -f libruby.a ] && RUBY_A=libruby.a
    echo "ruby static lib: ${RUBY_A:-NONE}"
    cp -f "$RUBY_A" "$PREFIX/lib/libruby-static.a"
    cp -f ./*.h "$PREFIX/include" 2>/dev/null || true
    cp -f ../*.h "$PREFIX/include/" 2>/dev/null || true
    # mkxp-z 期望 ruby 版本子目录（如 ruby/version.h, ruby/intern.h）
    cp -rf ../include/ruby/* "$PREFIX/include/ruby/" 2>/dev/null || true
    cp -f ./*.h "$PREFIX/include/ruby/" 2>/dev/null || true
    # 交叉编译生成的本机 arch 头（ruby/config.h 等）在 .ext/include/arm64-darwin/
    cp -rf .ext/include/arm64-darwin/* "$PREFIX/include/" 2>/dev/null || true
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

# 收集全部 .a（libmkxp + vcpkg + ruby）
LIBS=()
[ -f "$MKXP_SRC/build-ios/libmkxp.a" ] && LIBS+=("$MKXP_SRC/build-ios/libmkxp.a")
while IFS= read -r f; do LIBS+=("$f"); done < <(find "$VCPKG_INSTALL/lib" -name '*.a')
LIBS+=("$RUBY_LIB")

libtool -static -o "$FW_DIR/MKXP" "${LIBS[@]}"

# 公开头（供桥接调用 mkxp_run）
cat > "$FW_DIR/Headers/MKXP.h" <<'EOF'
#ifndef MKXP_H
#define MKXP_H
#ifdef __cplusplus
extern "C" {
#endif
// 在指定 UIView 中启动 MKXP，运行 gamePath 下的 RGSS 游戏；返回 0 成功
int mkxp_run(const char* gamePath, void* uiView);
void mkxp_key(int rgssKey, int down);
void mkxp_quit(void);
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
