#!/usr/bin/env ruby
# frozen_string_literal: true

# 把 MKXP.framework 链进 Flutter 生成的 Runner target（CI 专用，flutter build 前跑）。
#
# 背景：mkxp 插件因含 Swift，podspec 必须 s.static_framework = true。而静态
# framework 的 pod target 只归档【自己的】对象、不解析外部依赖——App 的最终
# 链接阶段看不到引擎框架，于是 Undefined symbol: _mkxp_run/_mkxp_key/_mkxp_quit。
#
# 框架布局（由 scripts/build_mkxp_ios.sh 产出）：
#   MKXP.framework/MKXP   —— 核心归档：libmkxp + 静态 Ruby + SDL2_sound
#   MKXP.framework/Libs/*.a —— vcpkg 各静态依赖（SDL2/openal/fmt/png/…）
#
# 本脚本做三件事：
#   1. 把 MkxpLinkAnchor.m（链接锚点，见该文件注释）加入 Runner 的编译源——
#      Runner 自身引用三个 C 符号，未决状态在链接最开始就存在；
#   2. OTHER_LDFLAGS 先 -force_load 核心归档（全量载入、无视链接顺序），
#      【再】逐个追加 Libs/*.a 走按需加载（顺序在 force_load 之后，核心对象的
#      未决引用此时已存在，必然被满足）；
#   3. 补齐引擎所需的系统框架/静态库。
#
# 为什么核心 force_load + 依赖按需：
#   - 全量 force_load 整个框架会炸 duplicate symbols——libc++/fmt 的符号被嵌进
#     libopenal/libfmt/libmkxp 多个归档（实测 454 个重复定义）；
#   - 按需加载天然去重（ld 只取第一个定义），且依赖排在核心之后不会再有顺序问题；
#   - -framework MKXP 无论放 OTHER_LDFLAGS 还是 frameworks 阶段都拉不到符号
#     （疑似 Xcode/ld 对「框架壳+归档内核」的处理问题），故直接指定归档路径。
#
# 用法： ruby scripts/ios-link-mkxp.rb [Runner.xcodeproj 路径] [MKXP.framework 路径] [锚点 .m 路径]

require 'pathname'
require 'xcodeproj'

proj_path  = ARGV[0] || 'ios/Runner.xcodeproj'
fw_rel     = ARGV[1] || 'mkxp/ios/MKXP.framework'
anchor_rel = ARGV[2] || 'ios/Runner/MkxpLinkAnchor.m'

abort "project not found: #{proj_path}" unless File.directory?(proj_path)

# 入参都相对当前工作目录（CI 里的仓库根）
fw_abs = File.expand_path(fw_rel)
anchor_abs = File.expand_path(anchor_rel)
core_bin = File.join(fw_abs, 'MKXP')
abort "framework not found: #{fw_abs} (download it first)" unless File.exist?(core_bin)
abort "anchor not found: #{anchor_abs} (copy it into ios/Runner first)" unless File.exist?(anchor_abs)

project = Xcodeproj::Project.open(proj_path)
target = project.targets.find { |t| t.name == 'Runner' }
abort "Runner target not found in #{proj_path}" unless target

proj_dir = File.expand_path(File.dirname(proj_path))
srcdir_rel = Pathname.new(fw_abs).relative_path_from(Pathname.new(proj_dir)).dirname.to_s # ../mkxp/ios

# 1) 链接锚点加入 Runner 编译源（路径相对【组】目录——Runner 组的基准是 ios/Runner/）
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
  puts "added #{anchor_rel_from_group} to Runner compile sources"
end

# 引擎所需的系统框架/静态库（libtool -static 合并产物不携带依赖信息，
# 与 scripts/mkxp-cmake/CMakeLists.txt 的 target_link_libraries 对应）
ENGINE_FRAMEWORKS = %w[
  UIKit Foundation QuartzCore CoreGraphics GameController
  Metal AudioToolbox CoreAudio CoreHaptics AVFoundation OpenGLES
  CoreMotion CoreBluetooth
].freeze
ENGINE_LIBS = %w[c++ z iconv].freeze

dep_libs = Dir.glob(File.join(fw_abs, 'Libs', '*.a')).sort
puts "deps (on-demand): #{dep_libs.size} archives in Libs/"

target.build_configurations.each do |config|
  settings = config.build_settings

  # 框架搜索路径（Runner 在 ios/，插件在仓库根 mkxp/ios）
  search = settings['FRAMEWORK_SEARCH_PATHS'] || ['$(inherited)']
  search = [search] if search.is_a?(String)
  marker = "\"$(SRCROOT)/#{srcdir_rel}\""
  search << marker unless search.include?(marker)
  settings['FRAMEWORK_SEARCH_PATHS'] = search

  flags = settings['OTHER_LDFLAGS'] || ['$(inherited)']
  flags = [flags] if flags.is_a?(String)

  # 2a) 核心归档：-force_load 全量载入（顺序无关）
  force = %(-force_load "$(SRCROOT)/#{srcdir_rel}/MKXP.framework/MKXP")
  flags << force unless flags.include?(force)

  # 2b) 依赖归档：按需加载，排在 force_load 之后（核心的未决引用此时已存在）
  dep_libs.each do |a|
    rel = Pathname.new(a).relative_path_from(Pathname.new(proj_dir)).to_s
    flag = %("$(SRCROOT)/#{rel}")
    flags << flag unless flags.include?(flag)
  end

  # 3) 系统框架/库
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

# 4) 禁用代码签名：本项目一律不签名——最终由 Sideloadly 在装有免费 Apple ID 的
#    Windows/Mac 侧重签安装。但 Flutter 的 `build ios` 预检仍要求“已选 Development
#    Team”，否则抛 “requires a selected Development Team”；故塞一个占位 Team 让预检
#    通过，实际签名由 CODE_SIGNING_ALLOWED=NO 关掉（Xcode 完全跳过签名阶段）。
#    占位 Team 不得为空字符串（预检要非空），且格式需为 10 位大写字母。
DUMMY_TEAM = 'AAAAAAAAAA'
[project, target].each do |obj|
  obj.build_configurations.each do |config|
    config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
    config.build_settings['CODE_SIGN_IDENTITY'] = ''
    config.build_settings['DEVELOPMENT_TEAM'] = DUMMY_TEAM
  end
end

project.save
puts "saved #{proj_path} (anchor + -force_load core + #{dep_libs.size} on-demand deps + #{ENGINE_FRAMEWORKS.size} frameworks + #{ENGINE_LIBS.size} libs)"
