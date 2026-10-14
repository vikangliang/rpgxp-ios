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
  # M1：取消下行注释并放入 MKXP.framework，即可链接引擎
  # s.vendored_frameworks = 'MKXP.framework'
end
