# MKXP build failure
run: https://github.com/vikangliang/rpgxp-ios/actions/runs/41212732342
commit: 5b0c588 ci: mkxp symbol collisions [skip ci]
date: 2026-10-31T15:00:54Z
## error lines
```
157:error: corrupt patch at /Users/runner/work/rpgxp-ios/rpgxp-ios/scripts/mkxp-framework/framework-entry.patch:501
```
## log tail (120)
```

For compilers to find bison you may need to set:
  export LDFLAGS=-L/opt/homebrew/opt/bison/lib
== vcpkg dir restored from cache (no .git), moved aside ==
Cloning into '/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg'...
Updating files:  73% (10663/14456)Updating files:  74% (10698/14456)Updating files:  75% (10842/14456)Updating files:  76% (10987/14456)Updating files:  77% (11132/14456)Updating files:  78% (11276/14456)Updating files:  79% (11421/14456)Updating files:  80% (11565/14456)Updating files:  81% (11710/14456)Updating files:  82% (11854/14456)Updating files:  83% (11999/14456)Updating files:  84% (12144/14456)Updating files:  85% (12288/14456)Updating files:  86% (12433/14456)Updating files:  87% (12577/14456)Updating files:  88% (12722/14456)Updating files:  89% (12866/14456)Updating files:  90% (13011/14456)Updating files:  91% (13155/14456)Updating files:  92% (13300/14456)Updating files:  93% (13445/14456)Updating files:  94% (13589/14456)Updating files:  95% (13734/14456)Updating files:  96% (13878/14456)Updating files:  97% (14023/14456)Updating files:  98% (14167/14456)Updating files:  99% (14312/14456)Updating files: 100% (14456/14456)Updating files: 100% (14456/14456), done.
From https://github.com/microsoft/vcpkg
 * branch              3cd21e48a75f67acfef289da52893ce79144aaa1 -> FETCH_HEAD
HEAD is now at 3cd21e48 [botan] Update to 3.13.0 (#54405)
== restored cached vcpkg installed/ ==
Downloading vcpkg-macos...
vcpkg package management program version 2026-09-26-51bf87ca6e9bf3e622d84ff323bd202ab1ca0c0b

See LICENSE.txt for license information.
Telemetry
---------
vcpkg collects usage data in order to help us improve your experience.
The data collected by Microsoft is anonymous.
You can opt-out of telemetry by re-running the bootstrap-vcpkg script with -disableMetrics,
passing --disable-metrics to vcpkg on the command line,
or by setting the VCPKG_DISABLE_METRICS environment variable.

Read more about vcpkg telemetry at https://learn.microsoft.com/vcpkg/about/privacy
Read the Microsoft Privacy Statement at https://go.microsoft.com/fwlink/?LinkId=521839
== install C deps via vcpkg (arm64-ios-static) ==
Computing installation plan...
The following packages are already installed:
    freetype[core,zlib,png,bzip2,brotli]:arm64-ios-static@2.14.3
    libjpeg-turbo:arm64-ios-static@3.2.0#1
    libogg:arm64-ios-static@1.3.6#1
    libpng:arm64-ios-static@1.6.59
    libspng:arm64-ios-static@0.7.4#1
    libtheora:arm64-ios-static@1.2.0
    libvorbis:arm64-ios-static@1.3.7#4
    openal-soft:arm64-ios-static@1.25.2
    physfs:arm64-ios-static@3.2.0#1
    pixman:arm64-ios-static@0.46.4#1
    sdl2:arm64-ios-static@2.32.10#1
    sdl2-image[core,libjpeg-turbo]:arm64-ios-static@2.8.12
    sdl2-ttf:arm64-ios-static@2.24.0
    uchardet:arm64-ios-static@0.0.8
    zlib:arm64-ios-static@1.3.2#2
Total install time: 212 us
All requested installations completed successfully in: 212 us
== vcpkg installed 顶层 ==
debug
include
lib
share
tools
== vcpkg installed/lib/*.a (前 200 行) ==
libbrotlicommon.a
libbrotlidec.a
libbrotlienc.a
libbz2.a
libfmt-c.a
libfmt.a
libfreetype.a
libjpeg.a
libogg.a
libopenal.a
libphysfs.a
libpixman-1.a
libpng.a
libpng16.a
libSDL2_image.a
libSDL2_ttf.a
libSDL2.a
libSDL2main.a
libspng_static.a
libtheora.a
libtheoradec.a
libtheoraenc.a
libturbojpeg.a
libuchardet.a
libvorbis.a
libvorbisenc.a
libvorbisfile.a
libz.a
pkgconfig
== SDL2 相关产物 ==
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/include/SDL2
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/lib/pkgconfig/SDL2_image.pc
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/lib/pkgconfig/SDL2_ttf.pc
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/lib/libSDL2_ttf.a
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/lib/libSDL2main.a
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/lib/libSDL2.a
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/lib/libSDL2_image.a
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/debug/lib/pkgconfig/SDL2_image.pc
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/debug/lib/pkgconfig/SDL2_ttf.pc
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/debug/lib/libSDL2maind.a
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/debug/lib/libSDL2_imaged.a
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/debug/lib/libSDL2d.a
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/debug/lib/libSDL2_ttfd.a
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/share/licenses/SDL2_image
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/share/SDL2_ttf
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/share/SDL2_ttf/SDL2_ttf-static-targets-release.cmake
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/share/SDL2_ttf/SDL2_ttf-static-targets-debug.cmake
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/share/SDL2_ttf/SDL2_ttf-static-targets.cmake
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/share/SDL2_ttf/SDL2_ttfConfigVersion.cmake
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/share/SDL2_ttf/SDL2_ttfConfig.cmake
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/share/SDL2_image
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/share/SDL2_image/SDL2_image-static-targets-debug.cmake
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/share/SDL2_image/SDL2_image-static-targets-release.cmake
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/share/SDL2_image/SDL2_imageConfig.cmake
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/share/SDL2_image/SDL2_imageConfigVersion.cmake
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/share/SDL2_image/SDL2_image-static-targets.cmake
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/share/sdl2/SDL2staticTargets-debug.cmake
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/share/sdl2/SDL2staticTargets-release.cmake
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/share/sdl2/SDL2staticTargets.cmake
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/share/sdl2/SDL2mainTargets-release.cmake
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/share/sdl2/SDL2mainTargets.cmake
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/share/sdl2/SDL2Config.cmake
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/share/sdl2/SDL2ConfigVersion.cmake
/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/vcpkg/installed/arm64-ios-static/share/sdl2/SDL2mainTargets-debug.cmake
sdl2_sound static lib: /Users/runner/work/rpgxp-ios/rpgxp-ios/deps/sdl2-sound-ios/lib/libSDL2_sound.a
== Ruby 已缓存，跳过 ==
Cloning into '/Users/runner/work/rpgxp-ios/rpgxp-ios/deps/mkxp-z'...
error: corrupt patch at /Users/runner/work/rpgxp-ios/rpgxp-ios/scripts/mkxp-framework/framework-entry.patch:501
FATAL: framework-entry.patch git apply 失败（deps 非 pristine 或 v2.4.2 源码对不上？）
```
