#!/usr/bin/env ruby
# frozen_string_literal: true

# 把 MKXP.framework 链进 Flutter 生成的 Runner target（CI 专用，flutter build 前跑）。
#
# 背景：mkxp 插件因含 Swift，podspec 必须 s.static_framework = true。而静态
# framework 的 pod target 只归档【自己的】对象、不解析外部依赖——App 的最终
# 链接阶段看不到引擎框架，于是 Undefined symbol: _mkxp_run/_mkxp_key/_mkxp_quit。
#
# 本脚本做三件事：
#   1. 把 MkxpLinkAnchor.m（链接锚点，见该文件注释）加入 Runner 的编译源——
#      Runner 自身引用三个 C 符号，防止 dead_strip 把引擎成员当无用代码剥掉；
#   2. 用 -force_load 全量载入 MKXP.framework 的静态归档（实证唯一稳的加载方式：
#      -framework MKXP 无论放 OTHER_LDFLAGS 还是 frameworks 阶段都拉不到符号，
#      疑似 Xcode/ld 对「框架壳+归档内核」的处理问题；force_load 直接指定归档路径，
#      无视链接顺序。代价是全量载入会暴露归档内部的重叠符号，已在合并阶段去重排除）；
#   3. 补齐引擎所需的系统框架/静态库（libtool -static 合并产物不携带依赖信息，
#      与 scripts/mkxp-cmake/CMakeLists.txt 的 target_link_libraries 对应）。
#
# 已排除的错路（都实测炸过）：
#   - podspec 用 vendored_frameworks：会被 pod 并进 Pods-mkxp.framework，与 App 侧
#     加载重复；
#   - -framework MKXP（OTHER_LDFLAGS 或 frameworks 阶段）：符号就是拉不到。
#
# 用法： ruby scripts/ios-link-mkxp.rb [Runner.xcodeproj 路径] [MKXP.framework 路径] [锚点 .m 路径]

require 'pathname'
require 'xcodeproj'

proj_path   = ARGV[0] || 'ios/Runner.xcodeproj'
fw_rel      = ARGV[1] || 'mkxp/ios/MKXP.framework'
anchor_rel  = ARGV[2] || 'ios/Runner/MkxpLinkAnchor.m'

abort "project not found: #{proj_path}" unless File.directory?(proj_path)

# 入参都相对当前工作目录（CI 里的仓库根）
fw_abs = File.expand_path(fw_rel)
anchor_abs = File.expand_path(anchor_rel)
abort "framework not found: #{fw_abs} (download it first)" unless File.exist?(fw_abs)
abort "anchor not found: #{anchor_abs} (copy it into ios/Runner first)" unless File.exist?(anchor_abs)

project = Xcodeproj::Project.open(proj_path)
target = project.targets.find { |t| t.name == 'Runner' }
abort "Runner target not found in #{proj_path}" unless target

proj_dir = File.expand_path(File.dirname(proj_path))
fw_rel_from_proj = Pathname.new(fw_abs).relative_path_from(Pathname.new(proj_dir)).to_s
anchor_rel_from_proj = Pathname.new(anchor_abs).relative_path_from(Pathname.new(proj_dir)).to_s

# 1) 链接锚点加入 Runner 编译源（路径要相对【组】目录——Runner 组的基准是 ios/Runner/）
runner_group = project.main_group['Runner'] || project.main_group
group_dir = runner_group.real_path.to_s
anchor_rel_from_group = Pathname.new(anchor_abs).relative_path_from(Pathname.new(group_dir)).to_s
anchor_ref = runner_group.files.find { |f| f.real_path.to_s == anchor_abs }
anchor_ref ||= runner_group.new_file(anchor_rel_from_group)
sources_phase = target.source_build_phase
if sources_phase.files_references.include?(anchor_ref)
  puts "anchor already in compile sources"
else
  sources_phase.add_file_reference(anchor_ref)
  puts "added #{anchor_rel_from_proj} to Runner compile sources"
end

# 2) force_load 引擎归档（实证唯一稳的加载方式，见文件头注释）
# 3) 引擎所需的系统框架/静态库
ENGINE_FRAMEWORKS = %w[
  UIKit Foundation QuartzCore CoreGraphics GameController
  Metal AudioToolbox CoreAudio CoreHaptics AVFoundation OpenGLES
  CoreMotion CoreBluetooth
].freeze
ENGINE_LIBS = %w[c++ z iconv].freeze

target.build_configurations.each do |config|
  settings = config.build_settings

  # 框架搜索路径（Runner 在 ios/，插件在仓库根 mkxp/ios）
  search = settings['FRAMEWORK_SEARCH_PATHS'] || ['$(inherited)']
  search = [search] if search.is_a?(String)
  marker = '"$(SRCROOT)/../mkxp/ios"'
  search << marker unless search.include?(marker)
  settings['FRAMEWORK_SEARCH_PATHS'] = search

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
puts "saved #{proj_path} (anchor + -force_load MKXP + #{ENGINE_FRAMEWORKS.size} frameworks + #{ENGINE_LIBS.size} libs)"
