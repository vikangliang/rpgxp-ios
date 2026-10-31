# dump 地图81 全部传送目标 + 78 的全部连接
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
def iv(obj, name); obj.instance_variable_get("@#{name}"); end
BASE = "D:/pokemon kit/开发工具/宝可梦sp4/Data"

# 1) 地图81 全部传送/脚本
map = Marshal.load(File.binread(File.join(BASE, "Map081.rxdata")))
puts "81 尺寸: #{iv(map,'width')} x #{iv(map,'height')}"
events = iv(map, "events") || {}
puts "81 事件总数: #{events.size}"
puts "=== 81 全部 code=201 传送 & 含 Transfer/Cave 脚本 ==="
events.each do |eid, ev|
  ex = iv(ev, "x"); ey = iv(ev, "y"); nm = iv(ev, "name").to_s
  (iv(ev, "pages") || []).each_with_index do |page, pi|
    trig = iv(page, "trigger")
    (iv(page, "list") || []).each do |cmd|
      code = iv(cmd, "code"); params = iv(cmd, "parameters") || []
      if code == 201
        puts "  事件#{eid} [#{nm}] @(#{ex},#{ey}) trig=#{trig} => #{params.inspect}"
      elsif code == 355 || code == 655
        s = params[0].to_s
        puts "  事件#{eid} [#{nm}] @(#{ex},#{ey}) trig=#{trig} [#{code}] #{s.strip[0,160]}" if s =~ /Transfer|Cave|78/i
      end
    end
  end
end

# 2) 78 的全部连接
conns = Marshal.load(File.binread(File.join(BASE, "map_connections.dat")))
puts "\n=== 含 78 或 119 的连接 ==="
conns.each do |c|
  if (c[0]==78 || c[3]==78 || c[0]==119 || c[3]==119)
    puts "  #{c.inspect}"
  end
end
