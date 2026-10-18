$__mkxp_main = self
$__mkxp_rcache = {}
$__mkxp_miss = {}
$__mkxp_probe = 0
$__mkxp_resolve = lambda do |s|
  str = s.to_s
  next str if str.empty?
  cached = $__mkxp_rcache[str]
  next cached if cached
  # 精灵 charset 解析探针："？"精灵 = check_graphic_file 全候选失败回退
  # Graphics/Characters/Followers/000.png。这里记录真实设备上每条 charset
  # 路径的 File.exist? 真值——直接区分"文件缺失(导入丢文件)"与"判定链路故障"。
  if $__mkxp_probe < 16 && str.index("Characters/")
    $__mkxp_probe += 1
    ex = begin
      File.exist?(str)
    rescue StandardError
      :err
    end
    $stderr.puts "[mkxp-fs] probe##{$__mkxp_probe} exist=#{ex} '#{str}'"
  end
  resolved = begin
    if File.exist?(str)
      str
    else
      leading = str.start_with?("/") ? "/" : ""
      acc = leading
      ok = true
      parts = str.split("/").reject { |seg| seg.empty? }
      parts.each_with_index do |seg, idx|
        last = (idx >= parts.length - 1)
        cand = acc + seg
        if File.exist?(cand)
          acc = cand + (last ? "" : "/")
        else
          parent = (acc.empty? || acc == "/") ? "/" : acc.chomp("/")
          parent = "." if parent == ""
          m = nil
          begin
            m = Dir.children(parent).find { |n| n.casecmp(seg) == 0 || n.delete(" ").casecmp(seg.delete(" ")) == 0 }
          rescue StandardError
            ok = false
            break
          end
          if m.nil? && last && [".gif", ".png", ".jpg", ".jpeg"].any? { |e| seg.downcase.end_with?(e) }
            base = seg[0, seg.rindex(".")]
            [".png", ".gif", ".jpg", ".jpeg"].each do |ext|
              alt = base + ext
              mm = Dir.children(parent).find { |n| n.casecmp(alt) == 0 || n.delete(" ").casecmp(alt.delete(" ")) == 0 }
              if mm
                m = mm
                break
              end
            end
          end
          if m.nil?
            ok = false
            break
          end
          acc += m + (last ? "" : "/")
        end
      end
      if ok && !acc.empty?
        acc
      else
        $__mkxp_miss[str] = ($__mkxp_miss[str] || 0) + 1
        $stderr.puts "[mkxp-fs] miss: #{str}" if $__mkxp_miss[str] == 1
        str
      end
    end
  rescue StandardError
    str
  end
  $__mkxp_rcache[str] = resolved
  resolved
end
class << Object
  def method_added(m)
    return if $__mkxp_busy
    $__mkxp_busy = true
    begin
      if m == :getPlayTime
        orig = instance_method(:getPlayTime)
        define_method(:getPlayTime) do |file|
          return -1 if file.to_s.start_with?("Audio/BGM")
          orig.bind(self).call(file)
        end
      elsif m == :pbGetFileChar
        orig = instance_method(:pbGetFileChar)
        res = $__mkxp_resolve
        define_method(:pbGetFileChar) do |file|
          orig.bind(self).call(res.call(file))
        end
      elsif m == :pbTryString
        orig2 = instance_method(:pbTryString)
        res2 = $__mkxp_resolve
        define_method(:pbTryString) do |x|
          r = res2.call(x)
          ret = orig2.bind(self).call(r)
          next nil_or_empty?(ret) ? nil : r
        end
      elsif m == :ow_sprite_filename
        # VOWE/跟随精灵的图名解析（顶层 def）。"？"精灵=它回退到 000.png。
        # 包一层：凡命中 000 回退就打出物种/形态/性别/闪光度——失败现场直出。
        orig3 = instance_method(:ow_sprite_filename)
        define_method(:ow_sprite_filename) do |*args, &blk|
          r = orig3.bind(self).call(*args, &blk)
          if r.to_s.include?("000.png")
            $stderr.puts "[mkxp-ow] '?' fallback! species=#{args[2].inspect} " \
                         "form=#{args[3].inspect} gender=#{args[4].inspect} " \
                         "shiny=#{args[5].inspect} -> '#{r}'"
          end
          r
        end
      elsif m != :method_added
        k = ::Kernel
        unless k.respond_to?(m)
          main = $__mkxp_main
          k.define_singleton_method(m) { |*args, &blk| main.send(m, *args, &blk) }
        end
      end
    rescue StandardError
    ensure
      $__mkxp_busy = false
    end
  end
end
class << Kernel
  def method_added(m)
    begin; Kernel.send(:module_function, m); rescue StandardError; end
  end
end
$stderr.puts "[mkxp-ios] compat hooks v6 installed (charset probe + ow_sprite_filename fallback log)"
