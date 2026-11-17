# -*- coding: utf-8 -*-
# 预构建 PkmnAnimations 分片缓存，供 iOS 首次启动直接命中（消除 ~4s 的
# Marshal.load + 1532 次 Marshal.dump 卡顿）。
#
# 用法（在本机、有游戏数据的机器上运行）：
#   ruby tools/build_anim_cache.rb "D:/path/to/game"
# 生成：
#   <game>/Data/mkxp_anims.idx
#   <game>/Data/mkxp_anims.bin
#
# 格式与 ios_hook.rb 的 __mkxp_anim_ensure_cache 完全一致：
#   idx = Marshal.dump(["MKXPANIM1", [size, crc32(head64k)], entries])
#   entries[i] = [offset_in_bin, blob_bytesize, name]
#   bin  = 每个动画 Marshal.dump(anim) 顺序拼接
#
# 关键点：dump 用到的类（PBAnimation/PBAnimTiming/Color）在打包机上没有游戏
# 脚本定义，这里用空壳类 + 手写 Color/Tone._load 复刻 mkxp 的序列化格式。
# Marshal 记录的是【类名字符串 + 实例变量】，不依赖本机的类方法实现，因此
# 在 iOS 端（真实类）可以正常 load。

require "zlib"

game = ARGV[0] or abort "usage: ruby build_anim_cache.rb <game_dir>"
src = File.join(game, "Data", "PkmnAnimations.rxdata")
abort "missing #{src}" unless File.exist?(src)

# ---- 复刻 mkxp 内建类的序列化格式 ----
# 实测原始数据里 Color._load 收到 32 字节 = 4 个 double（pack("d4")）
class Color
  attr_accessor :red, :green, :blue, :alpha
  def self._load(s); o = new; o.red, o.green, o.blue, o.alpha = s.unpack("d4"); o; end
  def _dump(_d); [red, green, blue, alpha].pack("d4"); end
end
class Tone
  attr_accessor :red, :green, :blue, :gray
  def self._load(s); o = new; o.red, o.green, o.blue, o.gray = s.unpack("d4"); o; end
  def _dump(_d); [red, green, blue, gray].pack("d4"); end
end
# 游戏自定义类：Marshal 只需类存在 + 层级正确（PBAnimation < Array）
Object.const_set(:PBAnimation, Class.new(Array)) unless Object.const_defined?(:PBAnimation)
Object.const_set(:PBAnimations, Class.new(Array)) unless Object.const_defined?(:PBAnimations)
# 其它嵌套类自动按需定义（Marshal 遇到未定义类会抛 ArgumentError，名字从消息里取）
def ensure_class(name)
  return if Object.const_defined?(name)
  Object.const_set(name, Class.new(Object))
end

raw = File.binread(src)
head = raw[0, 65536].to_s
sig = [raw.bytesize, (Zlib.crc32(head) rescue 0)]

obj = begin
  Marshal.load(raw)
rescue ArgumentError => e
  # 迭代补齐缺失类
  ok = false
  30.times do
    begin
      obj = Marshal.load(raw); ok = true; break
    rescue ArgumentError => e2
      m = e2.message.match(/undefined class.module ([A-Za-z_]\w*)/)
      abort "cannot load: #{e2.message}" unless m
      ensure_class(m[1])
    end
  end
  abort "gave up loading #{src}" unless ok
  obj
end

arr = obj.instance_variable_get(:@array)
abort "unexpected container" unless arr.is_a?(Array)

idx_path = File.join(game, "Data", "mkxp_anims.idx")
bin_path = File.join(game, "Data", "mkxp_anims.bin")
t = Time.now.to_f
entries = []
File.open(bin_path, "wb") do |f|
  arr.each do |anim|
    blob = Marshal.dump(anim)
    nm = anim.respond_to?(:name) ? anim.name : nil
    entries << [f.tell, blob.bytesize, nm]
    f.write(blob)
  end
end
File.binwrite(idx_path, Marshal.dump(["MKXPANIM1", sig, entries]))
puts "[anim-cache] built n=#{entries.length} sig=#{sig.inspect} " \
     "idx=#{File.size(idx_path)}B bin=#{File.size(bin_path)}B t=#{(Time.now.to_f - t).round(2)}s"
