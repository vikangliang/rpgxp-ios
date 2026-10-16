Pod::Spec.new do |s|
  s.name             = 'mkxp'
  s.version          = '0.0.1'
  s.summary          = 'Native bridge for MKXP-Z (RPG Maker XP / Essentials 21.1) in Flutter.'
  s.description      = 'Hosts the MKXP-Z RGSS engine and exposes a UiKitView for rendering RPG XP games.'
  s.homepage         = 'https://example.com'
  s.license          = { :type => 'MIT' }
  s.author           = { 'rpgxp_loader' => 'local@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '14.0'
  s.swift_version    = '5.0'
  s.static_framework = true
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  # M1：链接 MKXP-Z 静态框架（build-mkxp.yml 产出，ios.yml 下载到此目录）
  s.vendored_frameworks = 'MKXP.framework'
  # libtool -static 合并的静态库不携带依赖信息，最终链接所需的系统框架/库在此补齐，
  # 与 scripts/mkxp-cmake/CMakeLists.txt 的 target_link_libraries 对应。
  # （vcpkg 的 C 依赖如 bz2/z 已作为 .a 合入 framework，无需再列）
  s.frameworks = %w[
    UIKit Foundation QuartzCore CoreGraphics GameController
    Metal AudioToolbox CoreAudio CoreHaptics AVFoundation OpenGLES
  ]
  s.libraries = ['c++', 'z', 'iconv']
end
