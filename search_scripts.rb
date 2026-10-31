# 用 Ruby 全局搜脚本定义（避开 findstr 编码问题）
require 'find'
ROOT = "D:/pokemon kit/开发工具/宝可梦sp4"
terms = ["pbTransferPlayer", "pbCaveExit", "pbCaveEntrance", "escapePoint", "def pbTransfer"]
Find.find(ROOT) do |path|
  next if File.directory?(path)
  # 跳过明显的非脚本大二进制（地图/数据），但 .rxdata 脚本档案也搜
  begin
    data = File.binread(path)
  rescue
    next
  end
  hits = {}
  terms.each do |t|
    idx = 0; cnt = 0
    while (i = data.index(t, idx))
      cnt += 1
      idx = i + t.length
      break if cnt > 3
    end
    hits[t] = cnt if cnt > 0
  end
  next if hits.empty?
  size = File.size(path)
  # 文本文件打得开就读几行上下文
  puts "FILE: #{path} (#{size} bytes) 命中: #{hits.inspect}"
  if path =~ /\.(rb|txt)$/i
    begin
      File.foreach(path).with_index do |line, li|
        if terms.any? { |t| line.include?(t) }
          puts "   L#{li+1}: #{line.strip[0,160]}"
        end
      end
    rescue; end
  end
end
puts "SEARCH_DONE"
