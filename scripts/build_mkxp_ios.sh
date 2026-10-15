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

RUBY_VER=3.2.5
PREFIX=$ROOT/deps/ruby-ios   # Ruby 安装前缀（缓存）
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
brew install --formula cmake ninja automake libtool pkg-config 2>/dev/null || true

# ---------- 1. vcpkg 安装 C 依赖（arm64-ios 静态） ----------
if [ ! -d "$VCPKG/.git" ]; then
  git clone --depth 1 https://github.com/microsoft/vcpkg "$VCPKG"
fi
pushd "$VCPKG" >/dev/null
  ./bootstrap-vcpkg.sh
popd >/dev/null

echo "== install C deps via vcpkg (arm64-ios) =="
"$VCPKG/vcpkg" install --triplet arm64-ios \
  sdl2 sdl2-image sdl2-ttf "sdl2-mixer[libvorbis]" \
  libpng zlib pixman freetype physfs sqlite3 \
  boost-system boost-filesystem boost-interprocess
VCPKG_INSTALL=$VCPKG/installed/arm64-ios

# ---------- 2. MRI Ruby 交叉编译（iOS arm64） ----------
# 用主机 ruby 引导 miniruby；本体编成静态库供 MKXP 链接。
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
    autoconf
    mkdir -p build-ios && cd build-ios
    # 关键交叉参数：--host 让 configure 走交叉路径；用主机 ruby 充当 MINIRUBY
    ../configure --host=aarch64-apple-darwin \
      --prefix="$PREFIX" \
      --enable-static --disable-shared \
      --disable-install-doc --disable-jit-support \
      --with-static-linked-ext \
      --without-ext=win32,win32ole,dbm,gdbm,coverage,fiddle,pty \
      cflags="$ARCH_FLAGS" LDFLAGS="$ARCH_FLAGS" \
      CROSS_COMPILING=yes \
      ac_cv_func_getentropy=no \
      ac_cv_func_fcntl=yes
    make -j"$(sysctl -n hw.ncpu)" libruby-static.a
    # 交叉编译不能跑 make install（会执行目标架构二进制），手动收集产物
    mkdir -p "$PREFIX/lib" "$PREFIX/include/ruby"
    cp -f libruby-static.a "$PREFIX/lib/"
    cp -f ./*.h "$PREFIX/include" 2>/dev/null || true
    cp -f ../*.h "$PREFIX/include/" 2>/dev/null || true
    cp -f ./*.h "$PREFIX/include/" 2>/dev/null || true
    # mkxp-z 期望 ruby 版本子目录（如 ruby/version.h, ruby/intern.h）
    cp -rf ../include/ruby/* "$PREFIX/include/ruby/" 2>/dev/null || true
    cp -f ./*.h "$PREFIX/include/ruby/" 2>/dev/null || true
    ls "$PREFIX/include" >/dev/null && echo "ruby headers staged"
  popd >/dev/null
fi
RUBY_INC=$PREFIX/include
RUBY_LIB=$PREFIX/lib/libruby-static.a

# ---------- 3. 克隆 mkxp-z ----------
if [ ! -d "$MKXP_SRC/.git" ]; then
  git clone --depth 1 https://github.com/mkxp-z/mkxp-z.git "$MKXP_SRC"
fi

# ---------- 4. 编译 mkxp-z（链接 vcpkg 依赖 + 静态 Ruby） ----------
pushd "$MKXP_SRC" >/dev/null
  # 准备 Ruby 头（mkxp-z 期望 ruby 版本子目录）
  RUBY_HDR=$RUBY_INC/ruby
  if [ ! -d "$RUBY_HDR" ]; then
    mkdir -p "$RUBY_HDR"
    cp -f "$RUBY_INC"/*.h "$RUBY_HDR/" 2>/dev/null || true
  fi
  cmake -G Ninja -B build-ios \
    -DCMAKE_TOOLCHAIN_FILE="$VCPKG/scripts/buildsystems/vcpkg.cmake" \
    -DVCPKG_TARGET_TRIPLET=arm64-ios \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES=$ARCH \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_IOS \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DWITH_AUDIO=ON -DWITH_MIDI=OFF \
    -DRUBY_INCLUDE_DIR="$RUBY_INC" \
    -DRUBY_LIBRARY="$RUBY_LIB" \
    -DCMAKE_PREFIX_PATH="$VCPKG_INSTALL"
  cmake --build build-ios -j"$(sysctl -n hw.ncpu)"
popd >/dev/null

# ---------- 5. 合并为静态 framework ----------
echo "== package MKXP.framework =="
rm -rf "$FW_DIR"
mkdir -p "$FW_DIR/Headers" "$FW_DIR/Modules"

# 收集全部 .a（mkxp-z + vcpkg + ruby）
LIBS=()
while IFS= read -r f; do LIBS+=("$f"); done < <(find "$MKXP_SRC/build-ios" -name '*.a')
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
