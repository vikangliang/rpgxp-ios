#!/usr/bin/env ruby
# frozen_string_literal: true

# 把 MKXP.framework 显式链进 Flutter 生成的 Runner target（CI 专用）。
#
# 背景：mkxp 插件因含 Swift，podspec 必须 s.static_framework = true。而静态
# framework 的 pod target 只归档【自己的】对象、不解析外部依赖——App 的最终
# 链接阶段看不到引擎框架，于是 Undefined symbol: _mkxp_run/_mkxp_key/_mkxp_quit。
#
# 已排除的两条错路（都实测炸过）：
#   1. podspec 用 vendored_frameworks：静态 framework 的 pod 会把引擎归档并进
#      Pods-mkxp.framework，与 App 侧加载重复 → 875 duplicate symbols；
#   2. App 侧用 -framework MKXP 按需加载：引用方 MkxpBridge.o 在 pod 的归档里，
#      ld 单遍按需扫描走到 MKXP.framework 时还没有未决符号，过后不回头 → 仍 undefined。
#
# 正解=单一加载者：podspec 只留编译期 FRAMEWORK_SEARCH_PATHS（import MKXP 用），
# App 侧用 -force_load 全量载入引擎归档（force_load 无视顺序，一定全进）。
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

  # 2) 链接参数：force_load 引擎归档（唯一加载者）+ 系统框架/库
  flags = settings['OTHER_LDFLAGS'] || ['$(inherited)']
  flags = [flags] if flags.is_a?(String)
  force = %(-force_load "$(SRCROOT)/../mkxp/ios/MKXP.framework/MKXP")
  flags << force unless flags.include?(force)
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
puts "saved #{proj_path} (-force_load MKXP + #{ENGINE_FRAMEWORKS.size} frameworks + #{ENGINE_LIBS.size} libs)"
