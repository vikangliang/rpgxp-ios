# 在 .rb 中定位传送处理函数（command_201 / TransferPlayer / pbTransfer 等）
require 'find'
ROOT = "D:/pokemon kit/开发工具/宝可梦sp4/Data/Scripts"
terms = ["TransferPlayer", "command_201", "def pbTransfer", "pbMapTransfer", "def pbFadeOutIn", "player_new_map_id"]
Find.find(ROOT) do |path|
  next unless path =~ /\.rb$/i
  next if File.directory?(path)
  begin
    File.foreach(path).with_index do |line, li|
      if terms.any? { |t| line.include?(t) }
        puts "#{path}:L#{li+1}: #{line.strip[0,160]}"
      end
    end
  rescue; end
end
puts "DONE"
