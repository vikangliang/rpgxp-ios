class Tone; def initialize(*a); end; def self._load(s); Tone.new; end; end
class Color; def initialize(*a); end; def self._load(s); Color.new; end; end
class Table; def initialize(*a); end; def self._load(s); Table.new; end; end
module RPG; end
def RPG.const_missing(name)
  c = Class.new do
    def initialize(*a); end
    def self._load(s); self.new; end
  end
  const_set(name, c)
  c
end

require 'find'
roots = [
  "D:/pokemon kit/开发工具/宝可梦sp4",
  "D:/pokemon kit/开发工具/宝可梦sp",
  "D:/pokemon kit/开发工具/宝可梦sp_new1",
  "D:/pokemon kit/开发工具/宝可梦sp_new2",
  "D:/pokemon kit/开发工具/宝可梦sp_new3"
]
def iv(obj, name); obj.instance_variable_get("@#{name}"); end

roots.each do |root|
  next unless File.directory?(root)
  path = File.join(root, "Data", "Map184.rxdata")
  next unless File.exist?(path)
  begin
    map = Marshal.load(File.binread(path))
    events = iv(map, "events") || {}
    targets = {}
    events.each do |eid, ev|
      (iv(ev, "pages") || []).each do |page|
        (iv(page, "list") || []).each do |cmd|
          code = iv(cmd, "code"); params = iv(cmd, "parameters") || []
          if code == 201
            mid = params[1]
            targets[mid] ||= 0
            targets[mid] += 1
          end
        end
      end
    end
    puts "#{root}/Data/Map184.rxdata  尺寸=#{File.size(path)}  出口目标统计: #{targets.inspect}"
  rescue => e
    puts "#{root}: 读取失败 #{e.class}: #{e.message}"
  end
end
