# 全树找所有 Map184.rxdata，比对哈希与出口目标；并定位 pbTransferPlayer 定义
require 'find'
require 'digest'
ROOT = "D:/pokemon kit"
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

puts "===== 所有 Map184.rxdata 副本 ====="
Find.find(ROOT) do |path|
  if File.basename(path) == "Map184.rxdata"
    begin
      h = Digest::MD5.file(path).hexdigest[0,10]
      sz = File.size(path)
      map = Marshal.load(File.binread(path))
      evs = iv(map, "events") || {}
      targets = Hash.new(0)
      evs.each do |eid, ev|
        (iv(ev, "pages") || []).each do |page|
          (iv(page, "list") || []).each do |cmd|
            next unless iv(cmd, "code") == 201
            mid = iv(cmd, "parameters")[1]
            targets[mid] += 1
          end
        end
      end
      puts "#{path}\n   size=#{sz} md5=#{h} 出口目标=#{targets.inspect}"
    rescue => e
      puts "#{path}\n   读取失败: #{e.class}: #{e.message}"
    end
  end
end

puts "\n===== pbTransferPlayer 定义位置 ====="
Find.find(ROOT) do |path|
  next unless path =~ /\.(rb|rxdata)$/i
  next if File.directory?(path)
  begin
    data = File.binread(path)
  rescue; next; end
  if data.include?("def pbTransferPlayer") || data.include?("pbTransferPlayer")
    # 只关心 .rb 文本里的定义
    if path =~ /\.rb$/i
      File.foreach(path).with_index do |line, li|
        puts "  #{path}:L#{li+1}: #{line.strip[0,120]}" if line.include?("def pbTransferPlayer")
      end
    else
      puts "  (二进制) #{path} 含 pbTransferPlayer"
    end
  end
end
puts "DONE"
