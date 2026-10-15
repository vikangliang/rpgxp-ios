# =============================================================================
# mkxp-z (v2.4.2) iOS 静态库手搓构建
# 上游已放弃 CMake/macOS/iOS，改 Meson；这里直接编译其 src/binding/shader/assets
# 成静态库 libmkxp.a，链接 vcpkg 依赖 + 自编静态 Ruby。
# iOS 交叉参数由命令行 -DCMAKE_SYSTEM_NAME=iOS 等传入。
# =============================================================================
cmake_minimum_required(VERSION 3.20)
project(mkxp-ios C CXX)

set(MKXP_SRC      "" CACHE PATH "mkxp-z 源码根目录")
set(VCPKG_INSTALL "" CACHE PATH "vcpkg installed/arm64-ios")
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

# ---- 在 vcpkg 静态安装里找库 ----
function(find_mkxp_lib var)
  find_library(${var} NAMES ${ARGN} PATHS ${DEP_LIB} NO_DEFAULT_PATH REQUIRED)
endfunction()

find_mkxp_lib(L_SDL2      SDL2)
find_mkxp_lib(L_SDL2SOUND SDL2_sound sdl2_sound)
find_mkxp_lib(L_SDL2IMAGE SDL2_image sdl2_image)
find_mkxp_lib(L_SDL2TTF   SDL2_ttf sdl2_ttf)
find_mkxp_lib(L_PHYSFS    physfs)
find_mkxp_lib(L_OPENAL    openal OpenAL)
find_mkxp_lib(L_THEORA    theora)
find_mkxp_lib(L_VORBIS    vorbis)
find_mkxp_lib(L_VORBISFILE vorbisfile)
find_mkxp_lib(L_OGG       ogg)
find_mkxp_lib(L_FREETYPE  freetype)
find_mkxp_lib(L_PIXMAN    pixman-1 pixman)
find_mkxp_lib(L_PNG       png libpng png16)
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
  ${RUBY_INC}
)

# ---- xxd 嵌入 shader/asset（还原上游 meson 的 custom_target） ----
find_program(XXD NAMES xxd REQUIRED)
set(GEN ${CMAKE_CURRENT_BINARY_DIR}/gen)
file(MAKE_DIRECTORY ${GEN})

set(SHADERS
  common.h transSimple.frag trans.frag hue.frag sprite.frag plane.frag gray.frag
  bitmapBlit.frag flatColor.frag simple.frag simpleColor.frag simpleAlpha.frag simpleAlphaUni.frag
  tilemap.frag flashMap.frag lanczos3.frag minimal.vert simple.vert simpleColor.vert sprite.vert
  tilemap.vert tilemapvx.vert blur.frag blurH.vert blurV.vert simpleMatrix.vert)
set(ASSETS icon.png gamecontrollerdb.txt liberation.ttf)

set(EMBED_SRCS)
foreach(f ${SHADERS} ${ASSETS})
  if(EXISTS ${MKXP_SRC}/shader/${f})
    set(src ${MKXP_SRC}/shader/${f})
  else()
    set(src ${MKXP_SRC}/assets/${f})
  endif()
  add_custom_command(
    OUTPUT ${GEN}/${f}.c
    COMMAND ${XXD} -i ${src} ${GEN}/${f}.c
    DEPENDS ${src} MAIN_DEPENDENCY ${src})
  list(APPEND EMBED_SRCS ${GEN}/${f}.c)
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

add_library(mkxp STATIC ${SRC_FULL} ${EMBED_SRCS})

target_include_directories(mkxp PRIVATE ${MKXP_INC})
target_compile_definitions(mkxp PRIVATE
  MKXPZ_BUILD_MESON
  MKXPZ_VERSION="2.4.2"
  HAVE_NANOSLEEP
  MKXPZ_INIT_GL_LATER
  AL_LIBTYPE_STATIC
  MKXPZ_ALCDEVICE=ALCdevice
  GLES2_HEADER
  MKXPZ_MINIFFI
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
