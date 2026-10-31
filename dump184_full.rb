# 全量 dump 地图184 的全部事件/页/指令，查找所有传送与 78 相关
class Tone; def initialize(*a); end; def self._load(s); Tone.new; end; end
class Color; def initialize(*a); end; def self._load(s); Color.new; end; end
class Table; def initialize(*a); end; def self._load(s); Table.new; end; end
module RPG; end
class RPG::Map; attr_accessor :width, :height; end
class RPG::Event; end
class RPG::Event::Page; attr_accessor :condition, :list, :move_route; end
class RPG::Event::Page::Condition; end
class RPG::Event::Page::Graphic; end
class RPG::EventCommand; attr_accessor :code, :parameters; end
class RPG::MoveRoute; end
class RPG::MoveCommand; end
class RPG::Tileset; end
class RPG::AudioFile; end
class RPG::Weather; end
class RPG::MapInfo; end

BASE = "D:/pokemon kit/开发工具/宝可梦sp4/Data"
def iv(obj, name); obj.instance_variable_get("@#{name}"); end

map = Marshal.load(File.binread(File.join(BASE, "Map184.rxdata")))
puts "184 尺寸: #{iv(map,'width')} x #{iv(map,'height')}"
events = iv(map, "events") || {}
puts "事件总数: #{events.size}"
puts "======== 全部事件 ========"
events.each do |eid, ev|
  ex = iv(ev, "x"); ey = iv(ev, "y"); nm = iv(ev, "name").to_s
  (iv(ev, "pages") || []).each_with_index do |page, pi|
    trig = iv(page, "trigger")
    puts "\n-- 事件#{eid} [#{nm}] @(#{ex},#{ey}) 页#{pi} trigger=#{trig} --"
    (iv(page, "list") || []).each_with_index do |cmd, ci|
      code = iv(cmd, "code"); params = iv(cmd, "parameters") || []
      ps = params.inspect
      # 把所有看起来相关的都打出来，含 78/81/119/184 数字及传送/条件/脚本
      flag = (code == 201) || (code == 355 || code == 655) || (code == 111 || code == 411) ||
             (code == 108 || code == 408) || ps =~ /78|81|119|184|Transfer|Cave/i
      if flag
        puts "   [#{ci}] code=#{code} #{ps[0,240]}"
      end
    end
  end
end
# 额外：专门列所有 code==201
puts "\n======== 全部 code=201 传送指令 ========"
events.each do |eid, ev|
  ex = iv(ev, "x"); ey = iv(ev, "y"); nm = iv(ev, "name").to_s
  (iv(ev, "pages") || []).each_with_index do |page, pi|
    (iv(page, "list") || []).each do |cmd|
      next unless iv(cmd, "code") == 201
      puts "  事件#{eid} [#{nm}] @(#{ex},#{ey}) 页#{pi} => #{iv(cmd,'parameters').inspect}"
    end
  end
end
