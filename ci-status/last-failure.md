# iOS build success
run: https://github.com/vikangliang/rpgxp-ios/actions/runs/39086301218
commit: 2a783c2 fix(ios): coalesce soft-present main-thread image updates (atomic pending flag) to stop dispatch_async block pile-up that balloons memory and gets jetsammed every few seconds; this is the likely cause of the 'crash every few seconds + BGM restarts'
date: 2026-10-18T01:27:29Z
## error lines
```
68:Xcode build done.                                           63.0s
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
Resolving dependencies...
Downloading packages...
  code_assets 1.2.1 (2.1.0 available)
  cross_file 0.3.5+5 (0.4.0 available)
  flutter_lints 4.0.0 (6.0.0 available)
  hooks 2.0.2 (2.2.0 available)
  lints 4.0.0 (6.1.0 available)
  material_color_utilities 0.13.0 (0.13.1 available)
  meta 1.18.3 (1.19.0 available)
  objective_c 9.5.0 (9.6.2 available)
  petitparser 7.0.2 (7.1.0 available)
  record_use 0.6.0 (1.1.1 available)
  test_api 0.7.12 (0.7.15 available)
  vector_math 2.4.0 (2.4.3 available)
  xml 7.0.1 (7.1.0 available)
Got dependencies!
13 packages have newer versions incompatible with dependency constraints.
Try `flutter pub outdated` for more information.
Warning: Building for device with codesigning disabled. You will have to manually codesign before deploying to device.
Building com.yourapp.rpgxpLoader for device (ios-release)...
The following plugins do not support Swift Package Manager for ios:
  - mkxp
This will become an error in a future version of Flutter. Please contact the plugin maintainers to request Swift Package Manager adoption.
Running pod install...                                           1,287ms
Running Xcode build...                                          
Xcode build done.                                           63.0s
✓ Built build/ios/iphoneos/Runner.app (34.6MB)
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
  adding: Payload/Runner.app/Frameworks/objective_c.framework/objective_c (deflated 84%)
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
