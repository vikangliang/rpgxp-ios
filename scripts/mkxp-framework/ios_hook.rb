$__mkxp_main = self
$__mkxp_rcache = {}
$__mkxp_miss = {}
$__mkxp_probe = 0
$__mkxp_logs = Hash.new(0)
def __mkxp_rel?(s)
  t = s.to_s
  t =~ /Followers|Swimming|Levitates|Characters\//
end
def __mkxp_log(tag, msg)
  $__mkxp_logs[tag] += 1
  $stderr.puts "[#{tag}##{$__mkxp_logs[tag]}] #{msg}" if $__mkxp_logs[tag] <= 60
rescue StandardError
  # 日志永不影响主流程
end
$__mkxp_resolve = lambda do |s|
  # 【根治】字符串对象所有权：本解析器返回的字符串绝不能与调用方共享。
  # 此前 `str = s.to_s`（String 时返回自身）+ `next cached`（直接返回缓存对象），
  # 而游戏代码会用 gsub! 原地改写返回值（VOWE/FollowingPkmn 的
  # `fname.gsub!("Graphics/Characters/","")`）——缓存里存的值对象被原地改成
  # 裸名，之后同一全路径的查询全部拿到被污染的裸名 → 判定失败 → "？"精灵。
  # 现在统一：输入复制、缓存命中复制、返回复制。
  str = s.to_s.dup
  next str if str.empty?
  cached = $__mkxp_rcache[str]
  next cached.dup if cached
  # 精灵 charset 解析探针："？"精灵 = check_graphic_file 全候选失败回退
  # Graphics/Characters/Followers/000.png。逐步复现 orig pbGetFileChar 的每一步，
  # 失败在哪一环当场打出（rgssad 分支 / FileTest / File.open+异常类）。
  if $__mkxp_probe < 40 &&
     (str.index("Characters/Followers") || str.index("Characters/Swimming") ||
      str.index("Characters/Levitates"))
    $__mkxp_probe += 1
    detail = begin
      if FileTest.exist?("./Game.rgssad")
        "rgssad=YES(load_data branch)"
      elsif !FileTest.exist?(str)
        "FileTest=false"
      else
        begin
          f = File.open(str, "rb")
          c = begin
            f.read(1)
          ensure
            f.close
          end
          "open_ok char=#{c.inspect}"
        rescue StandardError => e
          "open_fail #{e.class}: #{e.message}"
        end
      end
    rescue StandardError => e
      "probe_err #{e.class}: #{e.message}"
    end
    $stderr.puts "[mkxp-fs] probe##{$__mkxp_probe} fds=#{(Dir.children('/dev/fd').size rescue -1)} #{detail} '#{str}'"
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
  resolved.dup   # 返回副本：调用方的 gsub! 原地改写绝不波及缓存
end
class << Object
  def method_added(m)
    return if $__mkxp_busy
    $__mkxp_busy = true
    begin
      # 包装一律替换 Object 的【实例】方法（顶层 def 的真实落点），
      # 使 main 上下文与类上下文的所有调用都被拦截；此前定义在
      # Object 单例类上的包装只拦截类上下文调用，是覆盖不全的根子。
      if m == :getPlayTime
        orig = ::Object.instance_method(:getPlayTime)
        ::Object.send(:define_method, :getPlayTime) do |file|
          return -1 if file.to_s.start_with?("Audio/BGM")
          orig.bind(self).call(file)
        end
      elsif m == :pbGetFileChar
        # 根治"？"精灵：真机日志证明设备上 File.exist? 判定完全正确，但 orig
        # pbGetFileChar 对存在的文件仍返回 nil（根因由逐步探针继续定位）。
        # 兜底：orig 失败但文件确实存在（File.file? 排除目录）→ 返回 truthy
        # 占位字节。pbGetFileChar 只被用于存在性判定（pbTryString/pbRgssExists?），
        # "1" 与真实首字节等价。
        orig = ::Object.instance_method(:pbGetFileChar)
        res = $__mkxp_resolve
        ::Object.send(:define_method, :pbGetFileChar) do |file|
          r = res.call(file)
          ret = orig.bind(self).call(r)
          if nil_or_empty?(ret)
            exists = begin
              File.file?(r)
            rescue StandardError
              false
            end
            __mkxp_log("gfc", "in=#{file.inspect} r=#{r.inspect} orig=#{ret.inspect} file?=#{exists}") if __mkxp_rel?(r)
            if exists
              return "1"
            end
          end
          ret
        end
      elsif m == :pbTryString
        orig2 = ::Object.instance_method(:pbTryString)
        res2 = $__mkxp_resolve
        ::Object.send(:define_method, :pbTryString) do |x|
          r = res2.call(x)
          ret = orig2.bind(self).call(r)
          out = nil_or_empty?(ret) ? nil : r
          __mkxp_log("try", "in=#{x.inspect} -> #{out.inspect}") if __mkxp_rel?(x) || __mkxp_rel?(r)
          next out
        end
      elsif m == :ow_sprite_filename
        # VOWE/跟随精灵的图名解析（顶层 def）。"？"精灵=它回退到 000.png。
        # 包一层：凡命中 000 回退就打出物种/形态/性别/闪光度——失败现场直出。
        # 并在首次调用时把 GameData::Species.check_graphic_file 也包上日志
        # （它是 Species 的单例方法，method_added 钩子够不到，只能延迟包装）。
        orig3 = ::Object.instance_method(:ow_sprite_filename)
        ::Object.send(:define_method, :ow_sprite_filename) do |*args, &blk|
          unless $__mkxp_cgf_done
            $__mkxp_cgf_done = true
            begin
              sp = ::GameData::Species
              ocgf = sp.method(:check_graphic_file)
              sp.define_singleton_method(:check_graphic_file) do |*a, &b|
                rr = ocgf.call(*a, &b)
                __mkxp_log("cgf", "sub=#{a[6].inspect} sp=#{a[1].inspect} " \
                                  "form=#{a[2].inspect} g=#{a[3].inspect} " \
                                  "shiny=#{a[4].inspect} shadow=#{a[5].inspect} -> #{rr.inspect}")
                rr
              end
              __mkxp_log("cgf", "check_graphic_file wrapper installed")
            rescue StandardError => e
              __mkxp_log("cgf", "cgf wrap failed: #{e.class}")
            end
          end
          r = orig3.bind(self).call(*args, &blk)
          if r.to_s.include?("000.png")
            $stderr.puts "[mkxp-ow] '?' fallback! species=#{args[2].inspect} " \
                         "form=#{args[3].inspect} gender=#{args[4].inspect} " \
                         "shiny=#{args[5].inspect} water=#{args[0].inspect},#{args[1].inspect} -> '#{r}'"
          end
          r
        end
      elsif m == :pbResolveBitmap
        # 第二层兜底：orig 全候选失败时，用自研逐段解析器直接判
        # （设备探针已证明 File.exist?+Dir.children 可靠）。charset 名常被
        # 以"裸名"（不含 Graphics/Characters/ 前缀）传入，一并补前缀重试。
        origR = ::Object.instance_method(:pbResolveBitmap)
        resR = $__mkxp_resolve
        ::Object.send(:define_method, :pbResolveBitmap) do |x|
          ret = origR.bind(self).call(x)
          if nil_or_empty?(ret)
            s = x.to_s
            roots = [s]
            roots << ("Graphics/Characters/" + s) unless s.start_with?("Graphics/")
            found = nil
            roots.each do |cand|
              [".png", ".gif"].each do |ext|
                rr = resR.call(cand + ext)
                next if nil_or_empty?(rr)
                ex = begin
                  File.exist?(rr)
                rescue StandardError
                  :err
                end
                fi = begin
                  File.file?(rr)
                rescue StandardError
                  :err
                end
                if fi == true
                  __mkxp_log("rbm", "bypass hit in=#{x.inspect} rr=#{rr.inspect} " \
                                    "exist=#{ex} file=#{fi} enc=#{rr.encoding}")
                  found = rr
                  break
                end
              end
              break if found
            end
            ret = found
          end
          __mkxp_log("rbm", "in=#{x.inspect} -> #{ret.inspect}") if __mkxp_rel?(x) || __mkxp_rel?(ret.to_s)
          ret
        end
      elsif m != :method_added
        k = ::Kernel
        unless k.respond_to?(m)
          main = $__mkxp_main
          k.define_singleton_method(m) { |*args, &blk| main.send(m, *args, &blk) }
        end
      end
    rescue StandardError => e
      $stderr.puts "[mkxp-ios] hook wrap error for #{m.inspect}: #{e.class}"
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
begin
  rgssad = FileTest.exist?("./Game.rgssad") ? "YES" : "no"
  pwd = (Dir.pwd rescue "??")
  $stderr.puts "[mkxp-ios] compat hooks v8 installed (ROOT FIX: resolver string-ownership dup - game's gsub! on returned fname was mutating the shared cache object in place; + bypass, probes, cgf trace) cwd=#{pwd} rgssad=#{rgssad}"
rescue StandardError => e
  $stderr.puts "[mkxp-ios] compat hooks v7 installed (banner detail failed: #{e.class})"
end
