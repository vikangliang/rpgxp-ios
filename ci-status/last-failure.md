# iOS build success
run: https://github.com/vikangliang/rpgxp-ios/actions/runs/43609475500
commit: 50c096f 修复: 商店文本绘制延迟 —— Bitmap#text_size 结果缓存
date: 2026-11-14T15:23:30Z
## error lines
```
50:Xcode build done.                                           112.7s
```
## duplicate/undefined symbols (aggregated)
```
```
## ios-build.log (tail 160)
```
Headers
Info.plist
Libs
MKXP
Modules

mkxp/ios/MKXP.framework/Headers:
MKXP.h

mkxp/ios/MKXP.framework/Libs:
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
libpng16.a
libSDL2_image.a
libSDL2_ttf.a
libSDL2.a
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

mkxp/ios/MKXP.framework/Modules:
module.modulemap
added MkxpLinkAnchor.m to Runner compile sources
deps (on-demand): 26 archives in Libs/
saved ios/Runner.xcodeproj (anchor + -force_load core + 26 on-demand deps + 13 frameworks + 3 libs)
Warning: Building for device with codesigning disabled. You will have to manually codesign before deploying to device.
Building com.yourapp.rpgxpLoader for device (ios-release)...
The following plugins do not support Swift Package Manager for ios:
  - mkxp
This will become an error in a future version of Flutter. Please contact the plugin maintainers to request Swift Package Manager adoption.
Running pod install...                                           1,478ms
Running Xcode build...                                          
Xcode build done.                                           112.7s
✓ Built build/ios/iphoneos/Runner.app (35.3MB)
  adding: Payload/ (stored 0%)
  adding: Payload/Runner.app/ (stored 0%)
  adding: Payload/Runner.app/file_picker_darwin_file_picker_darwin.bundle/ (stored 0%)
  adding: Payload/Runner.app/file_picker_darwin_file_picker_darwin.bundle/PrivacyInfo.xcprivacy (deflated 34%)
  adding: Payload/Runner.app/file_picker_darwin_file_picker_darwin.bundle/Info.plist (deflated 28%)
  adding: Payload/Runner.app/AppIcon60x60@2x.png (stored 0%)
  adding: Payload/Runner.app/Runner (deflated 62%)
  adding: Payload/Runner.app/share_plus_share_plus.bundle/ (stored 0%)
  adding: Payload/Runner.app/share_plus_share_plus.bundle/PrivacyInfo.xcprivacy (deflated 40%)
  adding: Payload/Runner.app/share_plus_share_plus.bundle/Info.plist (deflated 26%)
  adding: Payload/Runner.app/Base.lproj/ (stored 0%)
  adding: Payload/Runner.app/Base.lproj/Main.storyboardc/ (stored 0%)
  adding: Payload/Runner.app/Base.lproj/Main.storyboardc/UIViewController-BYZ-38-t0r.nib (deflated 35%)
  adding: Payload/Runner.app/Base.lproj/Main.storyboardc/BYZ-38-t0r-view-8bC-Xf-vdC.nib (deflated 42%)
  adding: Payload/Runner.app/Base.lproj/Main.storyboardc/Info.plist (deflated 42%)
  adding: Payload/Runner.app/Base.lproj/LaunchScreen.storyboardc/ (stored 0%)
  adding: Payload/Runner.app/Base.lproj/LaunchScreen.storyboardc/01J-lp-oVM-view-Ze5-6b-2t3.nib (deflated 42%)
  adding: Payload/Runner.app/Base.lproj/LaunchScreen.storyboardc/UIViewController-01J-lp-oVM.nib (deflated 35%)
  adding: Payload/Runner.app/Base.lproj/LaunchScreen.storyboardc/Info.plist (deflated 42%)
  adding: Payload/Runner.app/Assets.car (deflated 50%)
  adding: Payload/Runner.app/AppFrameworkInfo.plist (deflated 28%)
  adding: Payload/Runner.app/AppIcon76x76@2x~ipad.png (stored 0%)
  adding: Payload/Runner.app/Frameworks/ (stored 0%)
  adding: Payload/Runner.app/Frameworks/objective_c.framework/ (stored 0%)
  adding: Payload/Runner.app/Frameworks/objective_c.framework/_CodeSignature/ (stored 0%)
  adding: Payload/Runner.app/Frameworks/objective_c.framework/_CodeSignature/CodeResources (deflated 77%)
  adding: Payload/Runner.app/Frameworks/objective_c.framework/objective_c (deflated 82%)
  adding: Payload/Runner.app/Frameworks/objective_c.framework/Info.plist (deflated 58%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/ (stored 0%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/_CodeSignature/ (stored 0%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/_CodeSignature/CodeResources (deflated 70%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/icudtl.dat (deflated 47%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/Flutter (deflated 57%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/Headers/ (stored 0%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/Headers/FlutterSceneDelegate.h (deflated 48%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/Headers/FlutterEngine.h (deflated 79%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/Headers/FlutterChannels.h (deflated 85%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/Headers/FlutterPlugin.h (deflated 75%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/Headers/FlutterAppDelegate.h (deflated 53%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/Headers/FlutterTexture.h (deflated 58%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/Headers/FlutterEngineGroup.h (deflated 71%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/Headers/FlutterPlatformViews.h (deflated 57%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/Headers/FlutterHeadlessDartRunner.h (deflated 73%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/Headers/FlutterCodecs.h (deflated 75%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/Headers/Flutter.h (deflated 60%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/Headers/FlutterViewController.h (deflated 67%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/Headers/FlutterMacros.h (deflated 58%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/Headers/FlutterDartProject.h (deflated 67%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/Headers/FlutterHourFormat.h (deflated 45%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/Headers/FlutterPluginAppLifeCycleDelegate.h (deflated 78%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/Headers/FlutterBinaryMessenger.h (deflated 67%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/Headers/FlutterCallbackCache.h (deflated 60%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/Headers/FlutterSceneLifeCycle.h (deflated 73%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/PrivacyInfo.xcprivacy (deflated 62%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/Modules/ (stored 0%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/Modules/module.modulemap (deflated 20%)
  adding: Payload/Runner.app/Frameworks/Flutter.framework/Info.plist (deflated 57%)
  adding: Payload/Runner.app/Frameworks/App.framework/ (stored 0%)
  adding: Payload/Runner.app/Frameworks/App.framework/_CodeSignature/ (stored 0%)
  adding: Payload/Runner.app/Frameworks/App.framework/_CodeSignature/CodeResources (deflated 72%)
  adding: Payload/Runner.app/Frameworks/App.framework/App (deflated 60%)
  adding: Payload/Runner.app/Frameworks/App.framework/flutter_assets/ (stored 0%)
  adding: Payload/Runner.app/Frameworks/App.framework/flutter_assets/NOTICES.Z (stored 0%)
  adding: Payload/Runner.app/Frameworks/App.framework/flutter_assets/NativeAssetsManifest.json (deflated 25%)
  adding: Payload/Runner.app/Frameworks/App.framework/flutter_assets/FontManifest.json (deflated 16%)
  adding: Payload/Runner.app/Frameworks/App.framework/flutter_assets/shaders/ (stored 0%)
  adding: Payload/Runner.app/Frameworks/App.framework/flutter_assets/shaders/ink_sparkle.frag (deflated 66%)
  adding: Payload/Runner.app/Frameworks/App.framework/flutter_assets/shaders/stretch_effect.frag (deflated 77%)
  adding: Payload/Runner.app/Frameworks/App.framework/flutter_assets/AssetManifest.bin (stored 0%)
  adding: Payload/Runner.app/Frameworks/App.framework/flutter_assets/fonts/ (stored 0%)
  adding: Payload/Runner.app/Frameworks/App.framework/flutter_assets/fonts/MaterialIcons-Regular.otf (deflated 35%)
  adding: Payload/Runner.app/Frameworks/App.framework/Info.plist (deflated 58%)
  adding: Payload/Runner.app/Info.plist (deflated 38%)
  adding: Payload/Runner.app/PkgInfo (stored 0%)
```
