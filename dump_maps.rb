# 只读诊断脚本：dump map_connections.dat 与 Map184.rxdata / Map081.rxdata
# 仅读取并打印，不写入/不修改任何工程文件。
BASE = "D:/pokemon kit/开发工具/宝可梦sp4/Data"

# ---- 健壮的 Marshal 加载：遇到未定义类时动态补齐后重试 ----
def safe_load(path)
  data = File.binread(path)
  loop do
    begin
      return Marshal.load(data)
    rescue ArgumentError => e
      m = e.message.match(/undefined class\/module (\S+)/)
      raise e unless m
      name = m[1]
      parts = name.split("::")
      mod = Object
      parts.each do |p|
        if mod.const_defined?(p, false)
          mod = mod.const_get(p)
        else
          cls = Class.new
          mod.const_set(p, cls)
          mod = cls
        end
      end
    end
  end
end

def iv(obj, name)
  obj.instance_variable_get("@#{name}")
end

# ---- RGSS 自定义序列化类（仅加载用，_load 返回占位对象即可）----
class Tone
  def initialize(*a); end
  def self._load(str); Tone.new; end
end
class Color
  def initialize(*a); end
  def self._load(str); Color.new; end
end
class Table
  def initialize(*a); end
  def self._load(str); Table.new; end
end

puts "===== map_connections.dat ====="
begin
  conns = safe_load(File.join(BASE, "map_connections.dat"))
  puts "总连接条数: #{conns.size}"
  conns.each_with_index do |c, i|
    next unless c.inspect.include?("184")
    puts "  [#{i}] #{c.inspect}"
  end
  puts "--- 含 78 或 81 的连接（上下文）---"
  conns.each_with_index do |c, i|
    s = c.inspect
    next unless s.include?("78") || s.include?("81")
    puts "  [#{i}] #{s}"
  end
rescue => e
  puts "读取 map_connections.dat 失败: #{e.class}: #{e.message}"
end

puts
puts "===== Map184.rxdata 全部事件(每页每条指令, 含所有疑似地图ID) ====="
begin
  map184 = safe_load(File.join(BASE, "Map184.rxdata"))
  puts "184 尺寸: #{iv(map184, 'width')} x #{iv(map184, 'height')}"
  events = iv(map184, "events") || {}
  puts "事件总数: #{events.size}"
  events.each do |eid, ev|
    ex = iv(ev, "x"); ey = iv(ev, "y")
    name = iv(ev, "name")
    pages = iv(ev, "pages") || []
    pages.each_with_index do |page, pi|
      list = iv(page, "list") || []
      # 只打印与传送/地图跳转/变量相关的指令，避免海量输出
      list.each do |cmd|
        code = iv(cmd, "code")
        params = iv(cmd, "parameters") || []
        ps = params.inspect
        if code == 201 || code == 355 || code == 655 || code == 111 || code == 411
          tag = case code
                when 201 then "内建传送"
                when 355,655 then "脚本"
                when 111,411 then "条件"
                end
          puts "  事件#{eid}(#{name})@(#{ex},#{ey}) 页#{pi} [#{code}=#{tag}] #{ps[0,200]}"
        end
      end
    end
  end
rescue => e
  puts "读取 Map184.rxdata 失败: #{e.class}: #{e.message}"
  puts e.backtrace.first(5)
end

puts
puts "===== Map078.rxdata 传送事件(查是否有通往184的入口) ====="
begin
  map78 = safe_load(File.join(BASE, "Map078.rxdata"))
  puts "78 尺寸: #{iv(map78, 'width')} x #{iv(map78, 'height')}"
  events78 = iv(map78, "events") || {}
  events78.each do |eid, ev|
    ex = iv(ev, "x"); ey = iv(ev, "y")
    (iv(ev, "pages") || []).each_with_index do |page, pi|
      (iv(page, "list") || []).each do |cmd|
        code = iv(cmd, "code"); params = iv(cmd, "parameters") || []
        if code == 201
          puts "  事件#{eid}@(#{ex},#{ey}) 页#{pi} [201] 原始参数=#{params.inspect}"
        elsif code == 355 || code == 655
          s = params[0].to_s
          puts "  事件#{eid}@(#{ex},#{ey}) 页#{pi} [#{code}] 脚本: #{s.strip[0,160]}" if s =~ /Transfer|Cave|184/i
        end
      end
    end
  end
rescue => e
  puts "读取 Map078.rxdata 失败: #{e.class}: #{e.message}"
end
