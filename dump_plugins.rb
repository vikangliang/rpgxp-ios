# 只读：在 PluginScripts.rxdata 原始字节里定位关键函数并提取周围源码
BASE = "D:/pokemon kit/开发工具/宝可梦sp4/Data"
raw = File.binread(File.join(BASE, "PluginScripts.rxdata"))
puts "文件大小: #{raw.bytesize}"

def extract_around(raw, needle, before: 200, after: 1800)
  i = raw.index(needle)
  return nil if !i
  s = i - before
  s = 0 if s < 0
  e = [raw.bytesize, i + after].min
  raw[s, e - s]
end

["def pbTransferPlayer", "def pbMapTransfer", "def getNewMap", "def setCurrentMap", "def pbTransfer"].each do |needle|
  ctx = extract_around(raw, needle)
  if ctx
    puts "\n========== #{needle} =========="
    puts ctx
  else
    puts "\n[未找到] #{needle}"
  end
end
