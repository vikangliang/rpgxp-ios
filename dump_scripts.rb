# 只读：dump 真正运行的 Data/Scripts.rxdata，提取关键函数源码
class Tone; def initialize(*a); end; def self._load(s); Tone.new; end; end
class Color; def initialize(*a); end; def self._load(s); Color.new; end; end
class Table; def initialize(*a); end; def self._load(s); Table.new; end; end

BASE = "D:/pokemon kit/开发工具/宝可梦sp4/Data"
data = Marshal.load(File.binread(File.join(BASE, "Scripts.rxdata")))
# data 是 [[脚本名, 内容字符串], ...]
puts "脚本总数: #{data.size}"
# 搜索包含关键函数的脚本
targets = ["pbTransferPlayer", "pbMapTransfer", "def setCurrentMap", "def getNewMap", "def pbTransfer", "def setCurrentMap"]
data.each_with_index do |entry, idx|
  name = entry[0]
  content = entry[1].to_s
  hits = targets.select { |t| content.include?(t) }
  next if hits.empty?
  puts "===== [#{idx}] #{name} 命中: #{hits.join(', ')} ====="
end

# 精确提取 pbTransferPlayer / pbMapTransfer 定义
def dump_func(content, funcname, around=60)
  idx = content.index(funcname)
  return if !idx
  start = [0, idx - 200].max
  puts "---- #{funcname} ----"
  puts content[start, 1200]
  puts "------------------------"
end

data.each do |entry|
  content = entry[1].to_s
  if content.include?("def pbTransferPlayer") || content.include?("def pbMapTransfer")
    dump_func(content, "def pbTransferPlayer") if content.include?("def pbTransferPlayer")
    dump_func(content, "def pbMapTransfer") if content.include?("def pbMapTransfer")
  end
end
