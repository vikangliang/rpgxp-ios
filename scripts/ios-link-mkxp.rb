#!/usr/bin/env ruby
# frozen_string_literal: true

# 把 MKXP.framework 显式链进 Flutter 生成的 Runner target（CI 专用）。
#
# 背景：mkxp 插件因含 Swift，podspec 必须 s.static_framework = true。而静态
# framework 的 pod target 只归档【自己的】对象、不解析外部依赖——podspec 里的
# vendored_frameworks 仅让 pod 编译期能找到 MKXP 模块（import MKXP），App 的
# 最终链接阶段看不到该框架，于是 Undefined symbol: _mkxp_run/_mkxp_key/_mkxp_quit。
#
# 故在 flutter create 生成工程后、flutter build ios 前，用本脚本给 Runner 补：
#   1. FRAMEWORK_SEARCH_PATHS：插件目录（Runner 在 ios/，框架在仓库根 mkxp/ios/）；
#   2. OTHER_LDFLAGS：-framework MKXP + 引擎所需系统框架/静态库（与
#      scripts/mkxp-cmake/CMakeLists.txt 的 target_link_libraries 对应）。
#
# 注意【不要】再加 -force_load，也【不要】再把框架加进 "Link Binary With Libraries"：
# 两种机制与 -framework 重复加载同一个静态归档会产生大量 duplicate symbols
# （实测 875 个）。按需加载即可——引擎内部高度互联，mkxp_run 被引用会递归拉起
# 所有依赖成员。
#
# 用法： ruby scripts/ios-link-mkxp.rb [Runner.xcodeproj 路径] [MKXP.framework 路径]

require 'pathname'
require 'xcodeproj'

proj_path = ARGV[0] || 'ios/Runner.xcodeproj'
fw_rel    = ARGV[1] || 'mkxp/ios/MKXP.framework'

abort "project not found: #{proj_path}" unless File.directory?(proj_path)

# 两个入参都相对当前工作目录（CI 里的仓库根）
fw_abs = File.expand_path(fw_rel)
abort "framework not found: #{fw_abs} (download it first)" unless File.exist?(fw_abs)

project = Xcodeproj::Project.open(proj_path)
target = project.targets.find { |t| t.name == 'Runner' }
abort "Runner target not found in #{proj_path}" unless target

# 引擎（libtool -static 合并产物）不携带依赖信息，App 链接所需的系统框架/库在此补齐。
ENGINE_FRAMEWORKS = %w[
  UIKit Foundation QuartzCore CoreGraphics GameController
  Metal AudioToolbox CoreAudio CoreHaptics AVFoundation OpenGLES
  CoreMotion CoreBluetooth
].freeze
ENGINE_LIBS = %w[c++ z iconv].freeze

target.build_configurations.each do |config|
  settings = config.build_settings

  # 1) 框架搜索路径（Runner 在 ios/，插件在仓库根 mkxp/ios）
  search = settings['FRAMEWORK_SEARCH_PATHS'] || ['$(inherited)']
  search = [search] if search.is_a?(String)
  marker = '"$(SRCROOT)/../mkxp/ios"'
  search << marker unless search.include?(marker)
  settings['FRAMEWORK_SEARCH_PATHS'] = search

  # 2) 链接参数：-framework MKXP + 系统框架/库
  flags = settings['OTHER_LDFLAGS'] || ['$(inherited)']
  flags = [flags] if flags.is_a?(String)
  fw_flag = '-framework "MKXP"'
  flags << fw_flag unless flags.include?(fw_flag)
  ENGINE_FRAMEWORKS.each do |fw|
    flag = %(-framework "#{fw}")
    flags << flag unless flags.include?(flag)
  end
  ENGINE_LIBS.each do |lib|
    flag = %(-l"#{lib}")
    flags << flag unless flags.include?(flag)
  end
  settings['OTHER_LDFLAGS'] = flags
end

project.save
puts "saved #{proj_path} (-framework MKXP + #{ENGINE_FRAMEWORKS.size} frameworks + #{ENGINE_LIBS.size} libs)"
