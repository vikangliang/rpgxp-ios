BASE = "D:/pokemon kit/开发工具/宝可梦sp4/PBS"
txt = File.read(File.join(BASE, "map_metadata.txt"))
cur = nil
name = nil
result = {}
txt.each_line do |line|
  if line =~ /^\[(\d+)\]\s*#?\s*(.*)$/
    cur = $1.to_i
  elsif line =~ /^Name\s*=\s*(.+)$/ && cur
    result[cur] = $1.strip
  end
end
[6, 78, 81, 119, 184].each do |id|
  puts "地图 #{id} => #{result[id].inspect}"
end
