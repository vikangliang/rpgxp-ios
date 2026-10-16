# =============================================================================
# mkxp-z (v2.4.2) iOS 静态库手搓构建
# 上游已放弃 CMake/macOS/iOS，改 Meson；这里直接编译其 src/binding/shader/assets
# 成静态库 libmkxp.a，链接 vcpkg 依赖 + 自编静态 Ruby。
# iOS 交叉参数由命令行 -DCMAKE_SYSTEM_NAME=iOS 等传入。
# =============================================================================
cmake_minimum_required(VERSION 3.20)
project(mkxp-ios C CXX)

set(MKXP_SRC      "" CACHE PATH "mkxp-z 源码根目录")
set(VCPKG_INSTALL "" CACHE PATH "vcpkg installed/arm64-ios-static")
set(SDLSOUND_PREFIX "" CACHE PATH "SDL2_sound 安装前缀（源码交叉编译）")
set(RUBY_INC      "" CACHE PATH "ruby 头目录")
set(RUBY_LIB      "" CACHE FILEPATH "libruby-static.a")

if(NOT MKXP_SRC OR NOT VCPKG_INSTALL OR NOT RUBY_INC OR NOT RUBY_LIB)
  message(FATAL_ERROR "必须传入 -DMKXP_SRC= -DVCPKG_INSTALL= -DRUBY_INC= -DRUBY_LIB=")
endif()

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(DEP_INC ${VCPKG_INSTALL}/include)
set(DEP_LIB ${VCPKG_INSTALL}/lib)

# ---- 在 vcpkg 静态安装里找库（递归 glob .a，兼容各种命名/子目录） ----
message(STATUS "VCPKG_INSTALL = ${VCPKG_INSTALL}")
message(STATUS "DEP_LIB       = ${DEP_LIB}")
message(STATUS "SDLSOUND_PREFIX = ${SDLSOUND_PREFIX}")
file(GLOB_RECURSE _DEP_ALL_A "${DEP_LIB}/*.a")
message(STATUS "DEP_LIB 下 .a 数量 = ${_DEP_ALL_A}")

# 不依赖 find_library 的命名猜测：直接在 DEP_LIB / SDLSOUND_PREFIX 下递归找
# lib<name>.a（也允许 framework 内同名）。命中任意一个候选即采用。
function(find_mkxp_lib var)
  set(_found "")
  foreach(_n ${ARGN})
    file(GLOB_RECURSE _cands
      "${DEP_LIB}/lib${_n}.a"
      "${DEP_LIB}/${_n}.a"
      "${DEP_LIB}/lib${_n}.framework/lib${_n}"
      "${DEP_LIB}/${_n}.framework/${_n}"
      "${DEP_LIB}/${_n}.framework/Versions/A/${_n}"
      "${SDLSOUND_PREFIX}/lib/lib${_n}.a"
      "${SDLSOUND_PREFIX}/lib/${_n}.a")
    if(_cands)
      list(GET _cands 0 _found)
      break()
    endif()
  endforeach()
  if(NOT _found)
    message(FATAL_ERROR "find_mkxp_lib: 在 ${DEP_LIB} / ${SDLSOUND_PREFIX} 下找不到 ${ARGN} 的 .a")
  endif()
  message(STATUS "find_mkxp_lib ${var} = ${_found}")
  set(${var} "${_found}" PARENT_SCOPE)
endfunction()

find_mkxp_lib(L_SDL2      SDL2)
find_mkxp_lib(L_SDL2SOUND SDL2_sound sdl2_sound)
find_mkxp_lib(L_SDL2IMAGE SDL2_image sdl2_image)
find_mkxp_lib(L_SDL2TTF   SDL2_ttf sdl2_ttf)
find_mkxp_lib(L_PHYSFS    physfs)
find_mkxp_lib(L_OPENAL    openal OpenAL libopenal openal32)
find_mkxp_lib(L_THEORA    theora)
find_mkxp_lib(L_VORBIS    vorbis)
find_mkxp_lib(L_VORBISFILE vorbisfile)
find_mkxp_lib(L_OGG       ogg)
find_mkxp_lib(L_FREETYPE  freetype)
find_mkxp_lib(L_PIXMAN    pixman-1 pixman)
find_mkxp_lib(L_PNG       png libpng png16 libpng16)
find_mkxp_lib(L_JPEG      jpeg turbojpeg libjpeg)
find_mkxp_lib(L_ZLIB      z)
find_mkxp_lib(L_UCHARDET  uchardet)

# ---- mkxp-z 头搜索路径 ----
set(MKXP_INC
  ${MKXP_SRC}/src
  ${MKXP_SRC}/src/audio
  ${MKXP_SRC}/src/crypto
  ${MKXP_SRC}/src/display
  ${MKXP_SRC}/src/display/gl
  ${MKXP_SRC}/src/display/libnsgif
  ${MKXP_SRC}/src/display/libnsgif/utils
  ${MKXP_SRC}/src/etc
  ${MKXP_SRC}/src/filesystem
  ${MKXP_SRC}/src/filesystem/ghc
  ${MKXP_SRC}/src/input
  ${MKXP_SRC}/src/net
  ${MKXP_SRC}/src/system
  ${MKXP_SRC}/src/util
  ${MKXP_SRC}/src/util/sigslot
  ${MKXP_SRC}/src/util/sigslot/adapter
  ${MKXP_SRC}/binding
  ${DEP_INC}
  ${DEP_INC}/SDL2
  ${DEP_INC}/freetype2
  ${SDLSOUND_PREFIX}/include
  ${RUBY_INC}
)

# ---- vcpkg / 自编依赖的子目录头文件（勿删：不是所有 port 都平铺在 include/ 根下） ----
# 以下布局均按对应 port 的安装规则核实过，缺一个就炸一个 'xxx.h' file not found：
#   openal-soft → include/AL/{al,alc,alext}.h      （mkxp-z 以 <al.h> 引用，无 AL/ 前缀；
#                                                  上游 Linux 靠 pkg-config 的 -I.../include/AL）
#   uchardet    → include/uchardet/uchardet.h       （uchardet 0.0.8 的 CMake 装入
#                                                  ${CMAKE_INSTALL_INCLUDEDIR}/uchardet）
#   pixman      → include/pixman-1/pixman.h         （对应 meson 的 pkg-config pixman-1）
#   SDL2_sound  → <prefix>/include/SDL2/SDL_sound.h（icculus v2.0.6 CMake 装进 SDL2/）
#   ruby        → <prefix>/include/ruby/ruby.h      （mkxp-z 直接 <ruby.h>；Debian 布局
#                                                  把 ruby.h 平铺在版本目录根，iOS 没有）
list(APPEND MKXP_INC
  ${DEP_INC}/AL
  ${DEP_INC}/uchardet
  ${DEP_INC}/pixman-1
  ${SDLSOUND_PREFIX}/include/SDL2
  ${RUBY_INC}/ruby
)
# 兜底：把 vcpkg / SDL2_sound 两个 include 根下的【全部子目录】都纳入搜索，
# 这样即使某个 port 升级后换了布局（如 uchardet 平铺回根目录），也无需改这里。
file(GLOB _DEP_INC_SUBDIRS LIST_DIRECTORIES true "${DEP_INC}/*")
foreach(_d ${_DEP_INC_SUBDIRS})
  if(IS_DIRECTORY "${_d}")
    list(APPEND MKXP_INC "${_d}")
  endif()
endforeach()
if(SDLSOUND_PREFIX)
  file(GLOB _SDLSOUND_SUBDIRS LIST_DIRECTORIES true "${SDLSOUND_PREFIX}/include/*")
  foreach(_d ${_SDLSOUND_SUBDIRS})
    if(IS_DIRECTORY "${_d}")
      list(APPEND MKXP_INC "${_d}")
    endif()
  endforeach()
endif()
message(STATUS "MKXP include dirs = ${MKXP_INC}")

# ---- xxd 嵌入 shader/asset（还原上游 meson 的 custom_target） ----
# 关键 1：符号名由【相对构建目录】的输入路径决定。上游 meson 在 build/ 下执行
#   xxd -i ../shader/simple.frag  →  ___shader_simple_frag
# （".."→"__" 再接 "/"→"_"，共 3 个下划线）。shader.cpp 的 INIT_SHADER 宏正是
# 引用 ___shader_##vert##_vert / ___shader_common_h。若像原先那样传绝对路径，
# 符号会变成 _Users_runner_..._shader_simple_frag，链接期必然炸。
# 关键 2：输出必须叫 <file>.xxd——源码里写的是 #include "simple.frag.xxd"。
# 关键 3：这些 .xxd 由 shader.cpp / main.cpp / eventthread.cpp / font.cpp
# 直接 #include，绝不参与编译；否则同一数组在两个 TU 各定义一次 → 重复符号。
find_program(XXD NAMES xxd REQUIRED)
set(GEN ${CMAKE_CURRENT_BINARY_DIR}/gen)
file(MAKE_DIRECTORY ${GEN})

set(SHADERS
  common.h transSimple.frag trans.frag hue.frag sprite.frag plane.frag gray.frag
  bitmapBlit.frag flatColor.frag simple.frag simpleColor.frag simpleAlpha.frag simpleAlphaUni.frag
  tilemap.frag flashMap.frag lanczos3.frag minimal.vert simple.vert simpleColor.vert sprite.vert
  tilemap.vert tilemapvx.vert blur.frag blurH.vert blurV.vert simpleMatrix.vert)
set(ASSETS icon.png gamecontrollerdb.txt liberation.ttf)

set(EMBED_HDRS)
foreach(f ${SHADERS} ${ASSETS})
  if(EXISTS ${MKXP_SRC}/shader/${f})
    set(src ${MKXP_SRC}/shader/${f})
  else()
    set(src ${MKXP_SRC}/assets/${f})
  endif()
  # 相对构建目录 → 正确的 xxd 符号前缀（___shader_* / ___assets_*）
  file(RELATIVE_PATH rel ${CMAKE_CURRENT_BINARY_DIR} ${src})
  add_custom_command(
    OUTPUT ${GEN}/${f}.xxd
    COMMAND ${CMAKE_COMMAND} -E chdir ${CMAKE_CURRENT_BINARY_DIR}
            ${XXD} -i ${rel} ${GEN}/${f}.xxd
    DEPENDS ${src} MAIN_DEPENDENCY ${src})
  list(APPEND EMBED_HDRS ${GEN}/${f}.xxd)
endforeach()

# ---- 源文件清单（来自上游 src/meson.build + binding/meson.build，miniffi=on） ----
set(SRC
  src/main.cpp src/config.cpp src/eventthread.cpp src/settingsmenu.cpp src/sharedstate.cpp
  src/audio/alstream.cpp src/audio/audio.cpp src/audio/audiostream.cpp src/audio/fluid-fun.cpp
  src/audio/midisource.cpp src/audio/sdlsoundsource.cpp src/audio/soundemitter.cpp src/audio/vorbissource.cpp
  src/theoraplay/theoraplay.c
  src/crypto/rgssad.cpp
  src/display/autotiles.cpp src/display/autotilesvx.cpp src/display/bitmap.cpp src/display/font.cpp
  src/display/graphics.cpp src/display/plane.cpp src/display/sprite.cpp src/display/tilemap.cpp
  src/display/tilemapvx.cpp src/display/viewport.cpp src/display/window.cpp src/display/windowvx.cpp
  src/display/libnsgif/libnsgif.c src/display/libnsgif/lzw.c
  src/display/gl/gl-debug.cpp src/display/gl/gl-fun.cpp src/display/gl/gl-meta.cpp src/display/gl/glstate.cpp
  src/display/gl/scene.cpp src/display/gl/shader.cpp src/display/gl/texpool.cpp src/display/gl/tileatlas.cpp
  src/display/gl/tileatlasvx.cpp src/display/gl/tilequad.cpp src/display/gl/vertex.cpp
  src/util/iniconfig.cpp src/util/win-consoleutils.cpp
  src/etc/etc.cpp src/etc/table.cpp
  src/filesystem/filesystem.cpp src/filesystem/filesystemImpl.cpp
  src/input/input.cpp src/input/keybindings.cpp
  src/net/LUrlParser.cpp src/net/net.cpp
  src/system/systemImpl.cpp
  binding/binding-mri.cpp binding/binding-util.cpp binding/table-binding.cpp binding/etc-binding.cpp
  binding/bitmap-binding.cpp binding/font-binding.cpp binding/graphics-binding.cpp binding/input-binding.cpp
  binding/sprite-binding.cpp binding/viewport-binding.cpp binding/plane-binding.cpp binding/window-binding.cpp
  binding/tilemap-binding.cpp binding/audio-binding.cpp binding/module_rpg.cpp binding/filesystem-binding.cpp
  binding/windowvx-binding.cpp binding/tilemapvx-binding.cpp binding/http-binding.cpp
  binding/miniffi-binding.cpp binding/miniffi.cpp
)

set(SRC_FULL)
foreach(s ${SRC})
  list(APPEND SRC_FULL ${MKXP_SRC}/${s})
endforeach()

add_library(mkxp STATIC ${SRC_FULL})
# .xxd 仅被 #include，不参与编译；但必须保证在编译前生成，故挂一个自定义目标
add_custom_target(mkxp_embed_xxd ALL DEPENDS ${EMBED_HDRS})
add_dependencies(mkxp mkxp_embed_xxd)

target_include_directories(mkxp PRIVATE ${MKXP_INC} ${GEN})
target_compile_definitions(mkxp PRIVATE
  MKXPZ_BUILD_MESON
  MKXPZ_VERSION="2.4.2"
  HAVE_NANOSLEEP
  MKXPZ_INIT_GL_LATER
  AL_LIBTYPE_STATIC
  MKXPZ_ALCDEVICE=ALCdevice
  GLES2_HEADER
  MKXPZ_MINIFFI
  # iOS 没有 Windows/Cocoa 专属 API，必须显式声明为非 Windows 平台，
  # 否则 #if MKXPZ_PLATFORM != MKXPZ_PLATFORM_WINDOWS 因两宏均未定义而
  # 误走 Windows 分支（GetUserDefaultLangID 等不存在）。上游 Linux 构建
  # 即设为 MKXPZ_PLATFORM_LINUX，iOS 复用同一 POSIX/SDL 路径。
  MKXPZ_PLATFORM=MKXPZ_PLATFORM_LINUX
  # Essentials 中文 UI 字体兜底
  MKXPZ_CJK_FONT
)
target_compile_options(mkxp PRIVATE
  -fdeclspec
  -Wno-non-virtual-dtor -Wno-reorder -Wno-uninitialized -Wno-unknown-pragmas -Wno-stringop-truncation
  -Wno-undefined-var-template -Wno-delete-non-abstract-non-virtual-dtor
  -fvisibility=hidden
)

target_link_libraries(mkxp PRIVATE
  ${L_SDL2} ${L_SDL2SOUND} ${L_SDL2IMAGE} ${L_SDL2TTF}
  ${L_PHYSFS} ${L_OPENAL} ${L_THEORA} ${L_VORBIS} ${L_VORBISFILE} ${L_OGG}
  ${L_FREETYPE} ${L_PIXMAN} ${L_PNG} ${L_JPEG} ${L_ZLIB} ${L_UCHARDET}
  ${RUBY_LIB}
  -lbz2 -liconv -ldl -lobjc -lpthread
  "-framework UIKit" "-framework Foundation" "-framework QuartzCore"
  "-framework CoreGraphics" "-framework GameController" "-framework Metal"
  "-framework AudioToolbox" "-framework CoreAudio" "-framework CoreHaptics"
  "-framework AVFoundation" "-framework OpenGLES"
)
