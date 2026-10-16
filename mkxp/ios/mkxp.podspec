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
  # M1：引擎框架的链接【不】用 vendored_frameworks——静态 framework 的 pod target
  # 会把它并进 Pods-mkxp.framework，与 App 侧的加载重复（875 duplicate symbols），
  # 且 pod target 本身不解析外部依赖、对 App 链接毫无帮助。这里只给 pod 编译期
  # 提供模块搜索路径（Swift 的 import MKXP 需要），真正链接由 CI 的
  # scripts/ios-link-mkxp.rb 在 App 层用 -force_load 完成（单一加载者）。
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'FRAMEWORK_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}"'
  }
  # libtool -static 合并的静态库不携带依赖信息，最终链接所需的系统框架/库在此补齐，
  # 与 scripts/mkxp-cmake/CMakeLists.txt 的 target_link_libraries 对应。
  # （vcpkg 的 C 依赖如 bz2/z 已作为 .a 合入 framework，无需再列）
  s.frameworks = %w[
    UIKit Foundation QuartzCore CoreGraphics GameController
    Metal AudioToolbox CoreAudio CoreHaptics AVFoundation OpenGLES
    CoreMotion CoreBluetooth
  ]
  s.libraries = ['c++', 'z', 'iconv']
end
