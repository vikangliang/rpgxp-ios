# =============================================================================
# 自定义 vcpkg triplet：iOS arm64 全静态链接
# 用途：把全部 C 依赖（SDL2*、openal-soft、theora/vorbis、freetype、physfs…）
#       编成 .a，便于后续 libtool -static 合并进 MKXP.framework 单一静态框架。
# 注意：iOS 不能静态链接系统 CRT，故 VCPKG_CRT_LINKAGE 必须为 dynamic（链接
#       libSystem/libc++），只有第三方库本身编成静态。
# =============================================================================
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME iOS)
