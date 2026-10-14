#!/usr/bin/env bash
# =============================================================================
# MKXP-Z iOS 交叉编译脚本（实验性草稿，M1 重点攻坚）
# 目标：产出 MKXP.framework（C++/SDL2/RGSS，MRI 完整 Ruby 绑定，含 OGG/WAV 音频）
# 运行环境：macOS（GitHub Actions macos-latest runner）
# 注意：本脚本在 M0 未接入 CI 主流程；M1 阶段会与 mkxp-z 源码核实后迭代。
# =============================================================================
set -euo pipefail

echo "== MKXP-Z iOS build (DRAFT) =="

# 1) 安装依赖（CI 用 brew；本地 macOS 同理）。|| true 避免已安装时报错中断。
brew install --formula \
  sdl2 sdl2_image sdl2_ttf sdl2_mixer \
  libpng jpeg zlib pixman libvorbis freetype \
  boost sqlite3 physfs \
  cmake ninja || true

# 2) 克隆 mkxp-z（RPG Maker XP/VX/VX Ace 的 RGSS 重实现）
git clone --depth 1 https://github.com/mkxp-z/mkxp-z.git deps/mkxp-z
cd deps/mkxp-z

# 3) iOS 交叉编译工具链（提供 ios.toolchain.cmake）
# git clone https://github.com/leetal/ios-cmake ios-cmake
#
# 4) 用 ios-cmake 工具链编译（需核实 mkxp-z 的 CMake 入口与 MRI Ruby 移植）：
# cmake -G Ninja \
#   -DCMAKE_TOOLCHAIN_FILE=ios-cmake/ios.toolchain.cmake \
#   -DPLATFORM=OS64 -DARCHS=arm64 -DDEPLOYMENT_TARGET=14.0 \
#   -DCMAKE_BUILD_TYPE=Release \
#   -DMKXP_BUILD_TESTS=OFF \
#   -B build-ios
# cmake --build build-ios -j"$(sysctl -n hw.ncpu)"
#
# 5) 产出 framework 后复制到 ios/Runner/mkxp/MKXP.framework，供 Flutter 链接。

echo "== DRAFT: 实际编译步骤需在 M1 结合 mkxp-z 源码核实后实现 =="
