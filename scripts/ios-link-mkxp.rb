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
#      让 Runner 自己的目标文件直接引用三个 C 符号，未决状态在链接最开始就存在，
#      MKXP.framework 在链接线任何位置都能被按需拉中；
#   2. 把 MKXP.framework 加进 Runner 的 "Link Binary With Libraries"（按需加载）；
#   3. 补齐引擎所需的系统框架/静态库（libtool -static 合并产物不携带依赖信息，
#      与 scripts/mkxp-cmake/CMakeLists.txt 的 target_link_libraries 对应）。
#
# 已排除的错路（都实测炸过）：
#   - podspec 用 vendored_frameworks：会被 pod 并进 Pods-mkxp.framework，与 App 侧
#     加载重复（duplicate symbols）；
#   - -force_load 全量载入：Ruby static-linked-ext 与 vcpkg 的 libz/libpng 符号重叠，
#     全量载入炸 800+ duplicate symbols（按需加载只取第一个定义，天然无冲突）；
#   - 仅 -framework MKXP 放 OTHER_LDFLAGS：排在 Pods 之前扫描，引用方还没进场（undefined）。
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

# 1) 链接锚点加入 Runner 编译源
runner_group = project.main_group['Runner'] || project.main_group
anchor_ref = runner_group.files.find { |f| f.real_path.to_s == anchor_abs }
anchor_ref ||= runner_group.new_file(anchor_rel_from_proj)
sources_phase = target.source_build_phase
if sources_phase.files_references.include?(anchor_ref)
  puts "anchor already in compile sources"
else
  sources_phase.add_file_reference(anchor_ref)
  puts "added #{anchor_rel_from_proj} to Runner compile sources"
end

# 2) MKXP.framework 加入 "Link Binary With Libraries"（按需加载）
fw_ref = project.main_group.files.find { |f| f.real_path.to_s == fw_abs }
fw_ref ||= project.main_group.new_file(fw_rel_from_proj)
frameworks_phase = target.frameworks_build_phase
if frameworks_phase.files_references.include?(fw_ref)
  puts "framework already in link phase"
else
  frameworks_phase.add_file_reference(fw_ref)
  puts "added #{fw_rel_from_proj} to Runner Link Binary With Libraries"
end

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

  # 只放系统框架/库：不放 -framework MKXP（顺序在 Pods 前会拉不到），
  # 更不放 -force_load（与 Ruby 扩展符号重叠，全量载入必炸）。
  flags = settings['OTHER_LDFLAGS'] || ['$(inherited)']
  flags = [flags] if flags.is_a?(String)
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
puts "saved #{proj_path} (anchor + -framework MKXP via link phase + #{ENGINE_FRAMEWORKS.size} frameworks + #{ENGINE_LIBS.size} libs)"
