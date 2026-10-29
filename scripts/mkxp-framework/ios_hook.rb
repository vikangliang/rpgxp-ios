$__mkxp_main = self
# ---- 根治：iOS MRI 3.x 的 private 方法显式接收者调用 NoMethodError ----
# RPG Maker XP / Essentials 21.1 生态（Gen 9 Pack、Deluxe Battle Kit、
# Following Pokemon EX 等）大量"显式接收者调用 private 方法"，PC 上老 RGSS
# Ruby 不报（同一游戏 PC 正常），但 iOS mkxp-z 的 Ruby 3.x 严格禁止 ->
# NoMethodError -> execute_script rescue 包成 EventScriptError 弹窗。
# 已逐个修过 has_follower / calculate_entry_hazard_damage，但这类 private 调用
# 散落各插件，逐个打补丁不可持续。根治：游戏脚本加载前把 Module#private /
# Module#private_class_method 变 no-op —— 所有方法保持 public，所有显式接收者
# 调用都合法。private 仅是访问控制，不改变任何逻辑；Ruby stdlib 与 MKXP C++ 绑定
# 已在 ios_hook 注入前加载完，不受此重定义影响。保留 has_follower / ai_hazard
# 定向补丁作为双保险（公开已是 public 的方法等于 no-op）。
unless defined?($__mkxp_private_neutered) && $__mkxp_private_neutered
  $__mkxp_private_neutered = true
  begin
    class Module
      alias_method :__mkxp_orig_private, :private
      def private(*args, &blk)
        # no-op：def 保持 public，显式接收者调用合法（根治 iOS private-call）
      end
      alias_method :__mkxp_orig_private_class_method, :private_class_method
      def private_class_method(*args, &blk)
        # no-op
      end
    end
    $stderr.puts "[mkxp-ios] Module#private neutered (iOS Ruby 3.x private-call compat; has_follower/ai_hazard now redundant but kept)"
  rescue StandardError => e
    $stderr.puts "[mkxp-ios] private neuter failed: #{e.class}: #{e.message}"
  end
end
$__mkxp_rcache = {}

# ---- 诊断总开关（性能关键） ----
# 默认关：生产版不包装 draw_text / draw_text_ex / pbDrawTextPositions 等每帧热路径。
# 这些包装当初为查"文本缺字/？精灵"而加，每帧几百次 draw_text 调用都执行
# args.index + String#dup + force_encoding + valid_encoding?，在 iPhone 上累积成
# 显著 CPU 开销 -> 卡顿 -> 内存压力 -> iOS jetsam 闪退；App 卡死后日志页也打不开。
# 非诊断期务必关。需重新诊断文本/精灵问题时把本常量改 true 并重 CI（iOS 沙盒取
# 不到自定义 env，故用编译期常量而非 MKXP_DIAG env）。？精灵/BGM 等功能修复（非
# 每帧）不受本开关影响，始终生效。
$__mkxp_diag = false
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

# ---- map-entry timing diagnostic（定位室内→室外 ~10s 卡顿；纯计时、不改逻辑）----
# lazy 安装 + 开关 + begin/rescue，绝不影响游戏功能。首次精灵解析时安装
# （彼时 Game_Map/Spriteset_Map/Tilemap/Graphics 均已定义），此后各次进图
# 打出每阶段 ms 分解——哪一段吃掉 ~10s 一目了然。诊断完把 $__mkxp_timing
# 改 false（或整段删）即零开销。
$__mkxp_timing = true
$__mkxp_t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
$__mkxp_timing_done = false
def __mkxp_ms
  ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - $__mkxp_t0) * 1000).to_i
rescue StandardError
  -1
end
def __mkxp_time_wrap(cls, mname, label)
  im = (cls.instance_method(mname) rescue nil)
  return unless im
  cls.send(:define_method, mname) do |*a, &b|
    t = __mkxp_ms
    r = im.bind(self).call(*a, &b)
    $stderr.puts "[map-timing] #{label} +#{__mkxp_ms - t}ms (end t=#{__mkxp_ms})"
    r
  end
rescue StandardError => e
  $stderr.puts "[map-timing] wrap #{label} failed: #{e.class}"
end
def __mkxp_wrap_new(cls, label)
  return unless cls && cls.respond_to?(:new)
  return if cls.instance_variable_get(:@__mkxp_new_wrapped)
  cls.instance_variable_set(:@__mkxp_new_wrapped, true)
  orig = cls.method(:new)
  cls.define_singleton_method(:new) do |*a, &b|
    t = __mkxp_ms
    r = orig.call(*a, &b)
    $stderr.puts "[map-timing] #{label} +#{__mkxp_ms - t}ms"
    r
  end
rescue StandardError => e
  $stderr.puts "[map-timing] wrap-new #{label} failed: #{e.class}"
end
# 更狠定位：Spriteset_Map#init 期间开 TracePoint，把内部每个方法调用计时，
# >500ms 的连调用深度一起打出来——7.3s 藏在哪个方法(Ruby 或 Ruby→C++ 如
# Tilemap.new/tileset=)直接现形，不依赖那些"在框架里却不执行"的 C++ 计时。
# 安全阀：只测前 3 次进图；单次事件数上限 200000 防 TracePoint 拖垮；找到
# >1500ms 的方法后当场关掉 TracePoint（定位到即停，避免无谓开销）。
$__mkxp_tp_budget = 3
def __mkxp_install_tracepoint_profiler
  return unless defined?(::Spriteset_Map)
  return if ::Spriteset_Map.instance_variable_get(:@__mkxp_tp_done)
  ::Spriteset_Map.instance_variable_set(:@__mkxp_tp_done, true)
  im = ::Spriteset_Map.instance_method(:initialize)
  ::Spriteset_Map.send(:define_method, :initialize) do |*a, &b|
    if $__mkxp_tp_budget <= 0
      return im.bind(self).call(*a, &b)  # 预算用完，退回普通路径，零开销
    end
    $__mkxp_tp_budget -= 1
    stack = []
    ev = 0
    found = false
    tp = TracePoint.new(:call, :return) do |t|
      begin
        ev += 1
        if ev > 200000 || found
          tp.disable
          next
        end
        mid = t.method_id.to_s
        next if mid.start_with?('__mkxp')
        full = "#{t.defined_class}##{mid}"
        if t.event == :call
          stack.push([full, __mkxp_ms])
        else
          e = stack.pop
          if e
            d = __mkxp_ms - e[1]
            if d > 500
              chain = stack.map { |m| m[0] }.join(' > ')
              $stderr.puts "[tp] #{e[0]} +#{d}ms  <= #{chain}"
              found = true if d > 1500  # 定位到即停
            end
          end
        end
      rescue StandardError
      end
    end
    t0 = __mkxp_ms
    tp.enable
    begin
      r = im.bind(self).call(*a, &b)
    ensure
      tp.disable
      $stderr.puts "[map-timing] Spriteset_Map#init +#{__mkxp_ms - t0}ms (traced, ev=#{ev})"
    end
    r
  end
rescue StandardError => e
  $stderr.puts "[tp] install failed: #{e.class}"
end
# ---- autotile 展开探查+缓存（排查室内→室外卡顿：AutotileExpander#expand 数千次 GPU blit）----
# 游戏脚本加载、TilemapRenderer::AutotileExpander 定义后安装；
# 记录每次 expand 的签名与耗时，并按"Bitmap 用尺寸 + 其它参数"作稳定 key 缓存返回值，
# 命中即跳过数千次 GPU blit（首次慢、重进/同 tileset 快）。begin/rescue 兜底，绝不影响游戏。
def __mkxp_install_autotile_cache
  return unless defined?(::TilemapRenderer) && ::TilemapRenderer.const_defined?(:AutotileExpander)
  cls = ::TilemapRenderer::AutotileExpander
  return if cls.instance_variable_get(:@__mkxp_at_wrapped)
  orig = (cls.method(:expand) rescue nil)
  return unless orig
  cls.instance_variable_set(:@__mkxp_at_wrapped, true)
  store = {}
  order = []          # LRU 顺序（最近使用在尾部）
  cls.instance_variable_set(:@__mkxp_at_store, store)
  cls.define_singleton_method(:expand) do |*a, &b|
    key = a.map do |x|
      if x.is_a?(Bitmap)
        # 尺寸 + 全图步进采样指纹。此前仅 16 个采样点太稀：两个不同 autotile
        # （同尺寸、底色相近，如草丛/花圃）极易碰撞 -> 误命中 -> 串图，
        # 表现为"花底部缺失/组合错乱"（实际显示成了另一张展开图）。
        # 步进 4px + 行间交错覆盖全图，碰撞概率≈0；开销仅在 MISS 时一次，
        # 相比 expand 本身（数千次 blit、秒级）可忽略。
        w = x.width; h = x.height
        fp = 0
        begin
          y = 0
          while y < h
            xx = (y / 4) % 4   # 行间交错起点，避免只采固定几列
            while xx < w
              c = x.get_pixel(xx, y)
              fp = (fp * 33 + c.red.to_i * 3 + c.green.to_i * 5 +
                    c.blue.to_i * 7 + c.alpha.to_i * 13) & 0x3FFFFFFF
              xx += 4
            end
            y += 4
          end
        rescue StandardError
          fp = 0
        end
        "B#{w}x#{h}##{fp}"
      elsif x.is_a?(Array) || x.is_a?(Hash)
        x.hash.to_s(36)
      else
        x.inspect
      end
    end.join('|')
    tpl = store[key] if store.key?(key)
    if tpl.is_a?(Bitmap) && tpl.disposed?
      # 模板失效（被 GC/淘汰前已 dispose）：丢弃并重展，绝不交出死对象
      store.delete(key)
      order.delete(key)
      tpl = nil
      $stderr.puts "[autotile-cache] template disposed -> re-expand"
    end
    if tpl
      order.delete(key)
      order.push(key)
      $stderr.puts "[autotile-cache] HIT argc=#{a.size}"
      # 交出【副本】：游戏 dispose 的是它持有的那张，缓存模板必须与之解耦，
      # 否则命中时返回已被 dispose 的 bitmap -> RGSSError: disposed bitmap
      __mkxp_clone_bitmap(tpl)
    else
      t = (Process.clock_gettime(Process::CLOCK_MONOTONIC) rescue 0)
      r = orig.call(*a, &b)
      dt = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).to_i rescue -1
      $stderr.puts "[autotile-cache] MISS +#{dt}ms arity=#{orig.arity} argc=#{a.size} args=[#{a.map(&:class).join(',')}] ret=#{r.class} key=#{key[0,80]}"
      store[key] = __mkxp_clone_bitmap(r)
      order.push(key)
      # 有界 LRU：autotile 组合本身很少，但若地图很多仍可能累积，故设上限
      while order.size > 64
        old = order.shift
        store.delete(old)
      end
      r
    end
  end
  $stderr.puts "[autotile-cache] installed (TilemapRenderer::AutotileExpander.expand wrapped)"
rescue StandardError => e
  $stderr.puts "[autotile-cache] install failed: #{e.class}: #{e.message}"
end

## 复制 Bitmap：缓存里只放【模板】，交给游戏的一律是新副本。
## 原因：游戏切图时会 dispose 它持有的 autotile bitmap；若缓存直接复用同一对象，
## 再次命中就会交出已 dispose 的 bitmap，触发 RGSSError: disposed bitmap。
def __mkxp_clone_bitmap(src)
  return src unless src.is_a?(Bitmap)
  begin
    cp = Bitmap.new(src.width, src.height)
    cp.blt(0, 0, src, Rect.new(0, 0, src.width, src.height))
    cp
  rescue StandardError
    src
  end
end

def __mkxp_install_map_timing
  return if $__mkxp_timing_done
  $__mkxp_timing_done = true
  return unless $__mkxp_timing
  __mkxp_time_wrap(::Game_Map, :setup, "Game_Map#setup") if defined?(::Game_Map)
  __mkxp_install_tracepoint_profiler if defined?(::Spriteset_Map)
  __mkxp_wrap_new(::Tilemap, "Tilemap.new") if defined?(::Tilemap)
  __mkxp_wrap_new(::Sprite_Character, "Sprite_Character.new") if defined?(::Sprite_Character)
  $stderr.puts "[map-timing] installed; Spriteset_Map#init now TracePoint-profiled"
rescue StandardError => e
  $stderr.puts "[map-timing] install failed: #{e.class}"
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
      # 根治（通用）：每个方法定义完成即强制 public。覆盖 Module#private no-op
      # 中和未生效的情况（如 Following Pokemon EX 的 has_follower）。Ruby 3.x 严禁
      # "私有方法+显式接收者"调用 -> NoMethodError -> EventScriptError。强制 public
      # 后显式接收者调用合法，且不改变任何游戏逻辑（无接收者调用与 send 本就不受
      # 可见性限制；private 仅是访问控制）。一次性的加载期开销，可忽略。
      begin
        self.send(:public, m)
      rescue StandardError
      end
      __mkxp_install_autotile_cache if defined?(::TilemapRenderer) && ::TilemapRenderer.const_defined?(:AutotileExpander)
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
            __mkxp_install_map_timing
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
          __mkxp_install_map_timing
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
      elsif m == :pbDrawTextPositions
        # 消息框/多行文本逐字绘制的汇聚点（def pbDrawTextPositions(bitmap, textpos)，
        # drawTextEx/Window_Message 都汇到这里）。记录每条文本行实际收到的字符序列：
        # 若用户看到缺字而本日志字符齐全 → 字被"绘制裁剪"（宽度测量/视口问题）；
        # 本日志里就缺 → 上游切片丢字。二者一锤定音。
        # 仅 $__mkxp_diag 时包装（每帧 textpos.map.join + force_encoding 在 iOS 上卡）；
        # 否则保持原 MKXP 实现，零 Ruby 开销。
        if $__mkxp_diag
          origP = ::Object.instance_method(:pbDrawTextPositions)
          ::Object.send(:define_method, :pbDrawTextPositions) do |bitmap, textpos|
            begin
              $__mkxp_logs["dtp"] += 1
              if $__mkxp_logs["dtp"] <= 40
                chars = textpos.map { |e| e[0].to_s }.join
                u = chars.dup.force_encoding(Encoding::UTF_8)
                fn = begin
                  bitmap.font.name
                rescue StandardError
                  "?"
                end
                $stderr.puts "[mkxp-dtp]##{$__mkxp_logs['dtp']} entries=#{textpos.size} " \
                             "bytes=#{u.bytesize} chars=#{u.length} valid=#{u.valid_encoding?} " \
                             "font=#{fn.inspect} text=#{chars.inspect[0, 120]}"
              end
            rescue StandardError
              # 日志永不影响绘制
            end
            origP.bind(self).call(bitmap, textpos)
          end
        end
      elsif m == :has_follower
        # Following Pokemon EX 跟宠插件用显式接收者调 $game_player.has_follower，
        # 该方法在插件里是 private；Module#private no-op 中和（8-30 行）竟未覆盖此
        # 定义（真机日志证实 has_follower 仍 private，且原 public 修复只挂诊断开关下的
        # 文本包装、生产默认关从不跑）。故改在方法定义完成时显式改 public —— 与
        # calculate_entry_hazard_damage 同机制，生产构建即生效，不依赖诊断开关。
        __mkxp_public_has_follower
      elsif m == :calculate_entry_hazard_damage
        # Battle::AI 私有方法被显式接收者调用（Gen 9 Pack + Deluxe Battle Kit 冲突）。
        # 与 Game_Player#has_follower 同根：私有方法+显式接收者 -> Ruby 3.3 NoMethodError。
        # 引擎侧放开可见性绕过（game project untouched）。
        __mkxp_public_ai_hazard
      elsif m == :mainFunctionDebug
        # 顶层主循环安全网（根治"闪退"）：Essentials 的 mainFunctionDebug 只
        # rescue Hangup，其它 StandardError（NoMethodError/RuntimeError...）在
        # MKXP 下会冒泡到顶层未捕获 -> 进程 signal=5 退出。这里包裹主循环，
        # 捕获任何未处理异常、打印真实 backtrace 到 mkxp.log，并回到标题画面
        # 而非退出进程（游戏继续可玩，读档/某场景崩了也只是回标题）。
        begin
          mfd = ::Object.instance_method(:mainFunctionDebug)
          ::Object.send(:define_method, :mainFunctionDebug) do
            __mkxp_patch_mega_bitmap   # 启动期一次性给基类 Sprite/Plane#bitmap= 打 mega-surface 降采样根治(判定已改用 mega?,不会误伤游戏 TilesetWrapper 的合法高 tileset)
            __mkxp_main_safe(mfd)
          end
        rescue StandardError
        end
      elsif m == :draw_text || m == :draw_text_ex
        # 文本缺字诊断+防御（④）：拦截 Bitmap#draw_text / draw_text_ex。
        # 诊断：记录字节数 vs 可见字符数并打出上游调用栈，定位 Essentials
        # 里"按字节而非码点切片多字节字符"的脚本方法。防御：对不完整的
        # UTF-8 尾部字节安全剥离，避免末尾多字节被切半产生乱码；合法 UTF-8
        # 字符串完全不受影响。
        __mkxp_wrap_text_method(m)
      elsif m == :getLineBrokenChunks
        # [Bug1] 二次取证：该方法此刻才刚被 Essentials 定义完成（ios_hook 注入时
        # 它还不存在，早前装在文件末尾会 skip），且会被 Plugins/中文文本处理
        # /Tools.rb 二次覆盖 —— 每次定义都重新包一层，确保最终包住生效版本。
        __mkxp_install_lbc_diag
      elsif m == :execute_script
        # [诊断] 战斗/事件脚本 command_111 抛 EventScriptError 时，Interpreter#execute_script
        # 内部 rescue 会把原始异常包成 EventScriptError 并把真实消息吞掉（日志只剩空壳
        # 'EventScriptError (EventScriptError)'），无从定位根因。这里包一层：一旦它抛
        # EventScriptError，把正在 eval 的脚本原文(@parameters[0])打出来——下次日志带
        # [mkxp-ess] 行即能看到具体哪句报错，从而从根上修掉（让游戏不再 error，而非吞错
        # 继续）。纯日志、零逻辑改动；begin/rescue 不抛异常时开销可忽略；不影响 sp4 行为。
        if defined?(::Interpreter) && ::Interpreter.method_defined?(:execute_script)
          im = ::Interpreter.instance_method(:execute_script)
          unless ::Interpreter.instance_variable_get(:@__mkxp_es_wrapped)
            ::Interpreter.instance_variable_set(:@__mkxp_es_wrapped, true)
            ::Interpreter.send(:define_method, :execute_script) do |*a, &b|
              begin
                im.bind(self).call(*a, &b)
              rescue EventScriptError => e
                begin
                  params = self.instance_variable_get(:@parameters)
                  script = params.is_a?(Array) ? (params[0].to_s rescue "") : (params.to_s rescue "")
                  $stderr.puts "[mkxp-ess] EventScriptError in execute_script: " \
                               "script=#{script[0, 500].inspect}\n  at=#{(e.backtrace rescue [])[0, 6].inspect}"
                rescue StandardError
                end
                raise
              end
            end
          end
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
# ---- EventScriptError 根治：Game_Player#has_follower 改 public ----
# 真机日志坐实：`[Following Pokemon EX]` 插件用显式接收者调用 Game_Player 的
# 私有方法 has_follower（如 $player.has_follower），Ruby 3.3 严禁"私有方法+显式
# 接收者" -> NoMethodError -> execute_script rescue 包成 EventScriptError -> 弹窗。
# 这是游戏脚本/插件 bug（PC 旧 Ruby 不报），引擎侧把该方法改 public 即可绕过。
# has_follower 在游戏脚本里定义（ios_hook 运行时还不存在），故惰性修复：在
# draw_text 包裹（进地图画地名/HUD 就会调用，保证在事件执行前）首次触发时改 public。
$__mkxp_hf_fixed = false
def __mkxp_public_has_follower
  return if $__mkxp_hf_fixed
  return unless defined?(::Game_Player)
  begin
    ::Game_Player.send(:public, :has_follower)
    $__mkxp_hf_fixed = true
    $stderr.puts "[mkxp-ios] Game_Player#has_follower -> public (Following Pokemon EX private-call fix)"
  rescue StandardError => e
    # has_follower 尚未定义（NameError）等：下次再试，不打断主流程
  end
end

# ---- Battle::AI#calculate_entry_hazard_damage 改 public ----
# 真机 NoMethodError：private method 'calculate_entry_hazard_damage' called for
# Battle::AI (Gen 9 Pack Battle_AI.rb:647 在 block 里显式接收者调用，由
# Deluxe Battle Kit Command Menu Refactor.rb:442 pbDefaultChooseEnemyCommand 触发
# -> pbChooseToSwitchOut -> should_switch?)。与 Game_Player#has_follower 同根：
# 私有方法+显式接收者 -> Ruby 3.3 报错。PC 旧 Ruby 不报（同一游戏 PC 正常）。
# 引擎侧放开该方法可见性绕过（game project untouched）。
# 方法在游戏脚本定义（ios_hook 运行时还不存在），故惰性修复：在 method_added
# 捕获其定义时、以及 draw_text 包裹（战斗绘制文本必触发）首次调用时改 public。
$__mkxp_aih_fixed = false
def __mkxp_public_ai_hazard
  return if $__mkxp_aih_fixed
  return unless defined?(::Battle) && defined?(::Battle::AI)
  begin
    if ::Battle::AI.method_defined?(:calculate_entry_hazard_damage)
      ::Battle::AI.send(:public, :calculate_entry_hazard_damage)
      $__mkxp_aih_fixed = true
      $stderr.puts "[mkxp-ios] Battle::AI#calculate_entry_hazard_damage -> public (Gen9Pack/DBK private-call fix)"
    end
  rescue StandardError
    # 方法尚未定义（NameError）等：下次再试
  end
end

# ---- [根治] Sprite/Plane#bitmap= 在 iOS 遇 mega surface 崩溃 ----
# 真机坐实(dcf87a5 构建日志 [mkxp-ess] + MKXPError 栈): 战斗(Dynamax/变身)动画里
# MosaicBattlerSprite#bitmap=([DBK] Animated Pokémon System [006] Battler Sprites.rb:263)
# 调 super(Sprite#bitmap=), 传入的宝可梦精灵 Bitmap 超过设备 GPU maxTexSize, MKXP 做成
# "mega surface"(仅内存、禁止 Sprite/Plane 使用), 其 bitmap= 的 GUARD_MEGA 抛 MKXPError
# 'Operation not supported for mega surfaces' -> execute_script rescue 包成 EventScriptError
# -> 游戏崩。PC 上 RMXP 无纹理尺寸上限故正常。
# 根为引擎层限制: 任意 Sprite/Plane 被赋超过 maxTexSize 的 Bitmap 即崩。故在【基类
# Sprite#bitmap= 与 Plane#bitmap=】统一拦截: 赋值前把超 maxTexSize(无 API 时退回 2048 兜底,
# 低于所有 iOS 设备 maxTexSize>=2048)的位图降采样成普通位图再存储, 精灵/背景照常渲染。
# 游戏画面仅 512x384、精灵显示 ~100px, 降采样视觉无损。RGSS 仅 Sprite/Plane 有 bitmap=,
# 故这两条覆盖全部显示对象(战斗宝可梦/地图行走图/跟随精灵/战斗背景/地图滚动平面), 根治
# "下次又来"。引擎注入层修复, 不改动游戏 Plugins 文件。
# 判定: 只用引擎真实暴露的 Bitmap#mega?(游戏侧 script_00054/00055 亦用此名); 仅当
# mega? 不存在时才退回 isMega, 最后才退回尺寸 >2048 兜底。绝不让 >2048 盲判命中游戏
# TilesetWrapper 重排的合法高 tileset(高=Bitmap.max_size, iOS≥4096, 非 mega)。
# 降采样: Bitmap.new(nw,nh)+stretch_blt。已读 framework-entry.patch stretchBlt 实现
# (PATH=B/C 走 source.megaSurface() 的 RAM 路径, 安全处理 mega 源, 不依赖无效 gl.tex),
# 且 Bitmap#rect() 对 mega 取 v.rect 安全 -> 该写法对 mega 位图安全。
# 启动期一次性打补丁(mainFunctionDebug 包裹里), 哨兵防重复包装; rescue 失败仅打日志。
$__mkxp_mega_fixed = false
def __mkxp_patch_mega_bitmap
  return if $__mkxp_mega_fixed
  [[:Sprite, defined?(::Sprite) ? ::Sprite : nil],
   [:Plane,  defined?(::Plane)  ? ::Plane  : nil]].each do |_, k|
    next unless k
    begin
      # 已被本补丁包过(__mkxp_orig_bitmap_set 存在)则跳过, 避免重复包装
      next if k.method_defined?(:__mkxp_orig_bitmap_set)
      # alias 捕获 C++ 原生 bitmap=(保证可调用), 再用 Ruby 方法包一层拦截降采样
      k.send(:alias_method, :__mkxp_orig_bitmap_set, :bitmap=)
      k.send(:define_method, :bitmap=) do |value|
        v = value
        # 判定只用引擎真实暴露的 mega?（游戏侧 script_00054/00055 都用 bitmap.mega?）。
        # 绝不用 width/height>2048 兜底盲判：游戏 TilesetWrapper.wrapTileset 会把大 tileset
        # 重排成 高=Bitmap.max_size(≥4096) 的【合法、非 mega】位图，盲判会误伤 → 1000+ TileSprite
        # 各建一份降采样副本 → OOM/瓦片错位 → 进图闪退。仅真·mega(超 GPU 上限、引擎 GUARD_MEGA
        # 会抛错)才降采样，保住 Dynamax/变身等 mega 精灵的崩溃修复。
        if v.is_a?(Bitmap) &&
           (v.respond_to?(:mega?) ? v.mega? : (v.respond_to?(:isMega) ? v.isMega : (v.width > 2048 || v.height > 2048)))
          nw = [v.width, 2048].min
          nh = [v.height, 2048].min
          nb = Bitmap.new(nw, nh)
          nb.stretch_blt(Rect.new(0, 0, nw, nh), v, v.rect)
          v = nb
        end
        __mkxp_orig_bitmap_set(v)
      end
    rescue StandardError => e
      $stderr.puts "[mkxp-ios] mega-bitmap patch failed for #{k}: #{e.class}: #{e.message}"
    end
  end
  $__mkxp_mega_fixed = true
  $stderr.puts "[mkxp-ios] Sprite/Plane#bitmap= patched (downscale >maxTexSize mega-surface fix)"
end

# ---- 文本缺字诊断+防御（④） ----
# 拦截 Bitmap#draw_text / draw_text_ex：记录字节 vs 可见字符并打上游调用栈，
# 定位 Essentials 按字节切片多字节字符的脚本方法；并对不完整 UTF-8 尾部做安全
# 剥离（合法 UTF-8 不受影响）。
def __mkxp_wrap_text_method(name)
  return unless $__mkxp_diag          # 非诊断期不包装每帧热路径，零 Ruby 开销
  return unless defined?(::Bitmap)
  return unless ::Bitmap.method_defined?(name)
  orig = :"__mkxp_orig_#{name}"
  return if ::Bitmap.method_defined?(orig)
  ::Bitmap.send(:alias_method, orig, name)
  ::Bitmap.send(:define_method, name) do |*args, &blk|
    __mkxp_public_has_follower
    __mkxp_public_ai_hazard
    ai = args.index { |a| a.is_a?(String) }
    if ai
      s = args[ai]
      u = s.dup.force_encoding(Encoding::UTF_8)
      if !u.valid_encoding?
        $stderr.puts "[mkxp-text] INCOMPLETE UTF-8 #{name} bytes=#{u.bytesize} " \
                     "caller=#{(caller[0..5]).inspect} str=#{s.inspect[0, 80]}"
        i = u.length
        fixed = ""
        while i > 0
          begin
            t = u[0, i]
            if t.valid_encoding?
              fixed = t
              break
            end
          rescue StandardError; end
          i -= 1
        end
        args[ai] = fixed
      else
        $__mkxp_logs["txt"] += 1
        $stderr.puts "[mkxp-text] #{name} bytes=#{u.bytesize} chars=#{u.length} " \
                     "caller=#{(caller[0..3]).inspect}" if $__mkxp_logs["txt"] <= 120
      end
    end
    send(orig, *args, &blk)
  end
rescue StandardError => e
  $stderr.puts "[mkxp-text] wrap #{name} failed: #{e.class}: #{e.message}"
end
__mkxp_wrap_text_method(:draw_text)
__mkxp_wrap_text_method(:draw_text_ex)


class << Kernel
  def method_added(m)
    begin; Kernel.send(:module_function, m); rescue StandardError; end
  end
end
begin
  rgssad = FileTest.exist?("./Game.rgssad") ? "YES" : "no"
  pwd = (Dir.pwd rescue "??")
  $stderr.puts "[mkxp-ios] compat hooks v11 installed (removed mis-diagnosing cursor/diag probes; added main-loop rescue safety net = no more signal-5 crash; Audio call rescue = no SE crash freezing input; + all prior fixes) cwd=#{pwd} rgssad=#{rgssad}"
rescue StandardError => e
  $stderr.puts "[mkxp-ios] compat hooks v11 installed (banner detail failed: #{e.class})"
end

# ---- 顶层主循环安全网（根治"闪退"） ----
# Essentials 的 main 仅 rescue Hangup；任何 StandardError 在 MKXP 下冒泡到顶层
# 未捕获即进程退出(signal=5)。包裹 mainFunctionDebug：捕获未处理异常，打印真实
# backtrace（限频，足以定位根因），并回到标题画面继续运行而非退出。
$__mkxp_rescue_n = 0 unless defined?($__mkxp_rescue_n)
def __mkxp_main_safe(orig)
  begin
    orig.bind(self).call
  rescue SystemExit
    raise
  rescue StandardError => e
    if ($__mkxp_rescue_n += 1) <= 12
      $stderr.puts "[mkxp-rescue] UNHANDLED #{e.class}: #{e.message}\n  bt=#{(e.backtrace rescue [])[0, 24].inspect}"
    end
    # 不退出：回标题继续，至少菜单/其它场景可用（读档/某场景崩了也只是回标题）。
    begin
      $scene = pbCallTitle
      $scene.main until $scene.nil?
    rescue SystemExit
      raise
    rescue StandardError => e2
      if $__mkxp_rescue_n <= 12
        $stderr.puts "[mkxp-rescue] title-retry also failed: #{e2.class}: #{e2.message}"
      end
    end
  end
end

# ---- 音频调用容错（根治"光标冻结"表层因） ----
# SpriteWindow_Selectable#update 每次移动光标会调 pbPlayCursorSE ->
# pbSEPlay -> Audio.se_play。若 MKXP 下音频子系统未就绪/文件解析失败，
# Audio.se_play 抛 StandardError 会冒泡并中断 update，使 @index 不推进 ->
# 光标卡在 0（"冻结"）。包裹 se/me/bgm 调用吞掉异常，输入循环不再被打断。
if defined?(::Audio)
  $__mkxp_audio_n = 0
  [:se_play, :me_play, :bgm_play].each do |am|
    next unless ::Audio.respond_to?(am)
    om = ::Audio.method(am)
    ::Audio.singleton_class.send(:define_method, am) do |*a, &b|
      om.call(*a, &b)
    rescue StandardError => e
      if ($__mkxp_audio_n += 1) <= 8
        $stderr.puts "[mkxp-audio] #{am} rescued: #{e.class}: #{e.message}"
      end
    end
  end
end

# ---- [Bug1] 消息框偶尔少字：iOS 上不存在的字体名兜底 ----
# 证据链（真机 mkxp.log + 源码定位，均为事实，非推断）：
#   1) 日志每 run 一次 "mkxp-font: FALLBACK requested=[Arial] -> out=''"
#      —— iOS 无 Arial，且候选列表里只有 Arial，说明请求名本身就是 Arial/空。
#   2) 上游脚本两处都会退回 "Arial"：
#        Plugins/中文文本处理/Tools.rb:225-228 与
#        Data/Scripts/007_Objects and windows/010_DrawText.rb:143-147
#          defaultfontname = defaultfontname.find { |i| Font.exist?(i) } || "Arial"
#          elsif !Font.exist?(defaultfontname) -> defaultfontname = "Arial"
#   3) MKXP pickExistingFontName 全部候选落空 -> out="" -> 交给上层的是
#      【无效字体】-> 用它渲染的汉字没有字形 -> 屏幕上表现为"少字"。
#      PC 上有 Arial 兜底，所以只在 iOS 复现。
#   4) 已排除：4 个 Fusion Pixel 字体的字形覆盖完整（含"前/年/五/宝/可/梦"，
#      glyphs 29929/31367，无缺失）；上游排版用 each_char（字符安全，非按字节切片）。
# 修法：把"本机不存在"的字体名映射到游戏自带的 FusionPixelMonoPatched
#      （31367 字形，完整简体汉字）。只改变"本来就会失败"的赋值，成功路径零改动；
#      映射结果缓存进 Hash，每帧每字只多一次 Hash 查找，不影响性能。
unless defined?($__mkxp_fontfix) && $__mkxp_fontfix
  $__mkxp_fontfix = true
  begin
    $__mkxp_font_map = {}
    $__mkxp_font_n = 0
    # 优先用游戏自带的像素中文字体（family 在 iOS 上确实存在，扫描日志可见）
    $__mkxp_font_cands = ["FusionPixelMonoPatched",
                           "Fusion Pixel 12px Monospaced zh_hans"]
    def __mkxp_font_repl(name)
      return name unless name.is_a?(String)
      cached = $__mkxp_font_map[name]
      return cached if cached
      exist = (Font.exist?(name) rescue false)
      repl = name
      unless exist
        $__mkxp_font_cands.each do |c|
          ok = (Font.exist?(c) rescue false)
          if ok
            repl = c
            break
          end
        end
        if ($__mkxp_font_n += 1) <= 20
          $stderr.puts "[mkxp-fontfix] font '#{name}' not present on iOS -> use '#{repl}'"
        end
      end
      $__mkxp_font_map[name] = repl
      repl
    end
    # 路径 1：脚本给 Font 对象设名（Tools.rb / 010_DrawText.rb 走这条）
    if defined?(::Font) && ::Font.method_defined?(:name=)
      ::Font.send(:alias_method, :__mkxp_orig_name=, :name=)
      ::Font.send(:define_method, :name=) do |v|
        v = __mkxp_font_repl(v)
        send(:__mkxp_orig_name=, v)
      end
    end
    # 路径 2：原生构造 Font.new("Arial")（不经过 name=）
    if defined?(::Font) && ::Font.respond_to?(:new)
      om = ::Font.method(:new)
      ::Font.singleton_class.send(:define_method, :new) do |*a, &b|
        if a[0].is_a?(String)
          ok = (Font.exist?(a[0]) rescue false)
          a[0] = __mkxp_font_repl(a[0]) unless ok
        end
        om.call(*a, &b)
      end
    end
    # 一次性取证：关键字体是否存在 + 默认字体名（决定少字是否走本修复路径）
    begin
      $stderr.puts "[mkxp-fontfix] exist(FusionPixelMonoPatched)=#{Font.exist?('FusionPixelMonoPatched')} " \
                  "exist(Fusion Pixel 12px Monospaced zh_hans)=#{Font.exist?('Fusion Pixel 12px Monospaced zh_hans')} " \
                  "exist(Arial)=#{Font.exist?('Arial')} " \
                  "default=#{(Font.default.name.inspect rescue 'n/a')}"
    rescue StandardError => e
      $stderr.puts "[mkxp-fontfix] probe failed: #{e.class}: #{e.message}"
    end
    $stderr.puts "[mkxp-fontfix] installed (missing font name -> FusionPixelMonoPatched)"
  rescue StandardError => e
    $stderr.puts "[mkxp-fontfix] install failed: #{e.class}: #{e.message}"
  end
end

# ---- [Bug1] 二次取证：是"上游排版漏字"还是"draw_text 层丢字" ----
# 已确认 drawText 在 subImageFix=1 走 GPU blitRectangle(自动裁剪, 不整字丢),
# 故少字不在上传层。本段比较 getLineBrokenChunks 的【输入文本字符数】与
# 【输出 ret 中各 chunk 字符数之和】：
#   - 若 out < in -> 上游切片漏字(打印丢失的 codepoint), 根因在 Ruby 排版;
#   - 若相等   -> 漏字在逐字 draw_text/GPU 层(需另查重叠/裁剪)。
# 只在出现差异时限频打印, 不影响性能; 不改任何渲染/排版行为。
# 挂载时机很关键：这个方法由 Essentials 脚本定义（010_DrawText.rb 先、
# Plugins/中文文本处理/Tools.rb 后覆盖），ios_hook 注入时它还不存在，
# 所以必须由 class << Object 的 method_added 在"方法刚定义完"时调用本函数，
# 且每次重定义都要重新包一层，才能最终包住真正生效的那个版本。
# 只做计数 + 限频日志，不改任何渲染/排版行为。
def __mkxp_install_lbc_diag
  return unless ::Object.method_defined?(:getLineBrokenChunks) ||
                ::Object.private_method_defined?(:getLineBrokenChunks)
  begin
    orig = ::Object.instance_method(:getLineBrokenChunks)
    ::Object.send(:define_method, :getLineBrokenChunks) do |*a, &b|
      res = orig.bind(self).call(*a, &b)
      # 重入保护：同名方法被二次定义(覆盖)时会形成包装链，内层不再重复统计
      next res if $__mkxp_lbc_busy
      begin
        $__mkxp_lbc_busy = true
        txt = a[0]
        in_n  = txt.respond_to?(:codepoints) ? txt.codepoints.length : txt.to_s.length
        out_n = res.respond_to?(:map) ?
                res.map { |c| (c[0].is_a?(String) && !c[5]) ? c[0].codepoints.length : 0 }.inject(0, :+) : 0
        if out_n != in_n && ($__mkxp_lbc_n ||= 0) < 30
          $__mkxp_lbc_n = ($__mkxp_lbc_n || 0) + 1
          in_s  = txt.to_s
          out_s = res.respond_to?(:map) ?
                  res.map { |c| (c[0].is_a?(String) && !c[5]) ? c[0] : '' }.join : ''
          dropped = in_s.codepoints.to_a - out_s.codepoints.to_a
          $stderr.puts "[mkxp-lbc] MISS in=#{in_n} out=#{out_n} dropped_codepoints=#{dropped.inspect} sample=#{in_s[0,40].inspect}"
        end
        # 零宽字检测：某字测宽 ch[3] <= 0 时，drawText 里 squeeze = rect.w/txtSurf->w
        # 会把该字压成 posRect.w = 0 -> 完全不可见 -> 屏幕表现就是"少字"。
        # 它既不丢请求也不报错，所以此前所有日志（含 draw_text 入参日志）都抓不到。
        if res.respond_to?(:each) && ($__mkxp_lbc_z ||= 0) < 30
          res.each do |c|
            next unless c[0].is_a?(String) && !c[5]
            chu = c[0]
            next if chu == "\n" || chu == "\r" || chu == " "
            if c[3].to_i <= 0
              $__mkxp_lbc_z = ($__mkxp_lbc_z || 0) + 1
              $stderr.puts "[mkxp-lbc] ZEROW char=#{chu.inspect} codepoints=#{chu.codepoints.inspect} width=#{c[3].inspect}"
            end
          end
        end
      rescue StandardError => e
        $stderr.puts "[mkxp-lbc] err #{e.class}: #{e.message}"
      ensure
        $__mkxp_lbc_busy = false
      end
      res
    end
    $stderr.puts "[mkxp-lbc] installed (input vs output char-count on getLineBrokenChunks)"
  rescue StandardError => e
    $stderr.puts "[mkxp-lbc] install failed: #{e.class}: #{e.message}"
  end
end

# ---- [Bug2] 室外横线取证：检测 self-blit（源=目标的 GPU feedback loop）----
# scene_dump(512x384 渲染层)证实横线就在 game FBO 里；特征"中午(tone≈0)不出现、
# 早晚出现"指向随时间变化的 tint/效果路径。GPU 上 src==dst 的 blit 属 feedback
# loop，Metal-GL 下结果未定义，典型表现正是局部行错乱(横线)。此处只检测+限频
# 日志(<=30)，不改变任何绘制行为；equal? 判断每帧几次调用可忽略。
unless defined?($__mkxp_selfblit)
  $__mkxp_selfblit = true
  begin
    if defined?(::Bitmap)
      { blit: 2, stretch_blt: 1 }.each do |mname, src_idx|
        next unless ::Bitmap.method_defined?(mname)
        orig = ::Bitmap.instance_method(mname)
        ::Bitmap.send(:define_method, mname) do |*a, &b|
          src = a[src_idx]
          if src.is_a?(Bitmap) && src.equal?(self) && ($__mkxp_selfblit_n ||= 0) < 30
            $__mkxp_selfblit_n = ($__mkxp_selfblit_n || 0) + 1
            desc = a.map { |v|
              if v.is_a?(Rect) then "[#{v.x},#{v.y},#{v.width},#{v.height}]"
              elsif v.is_a?(Bitmap) then 'Bitmap'
              else v.inspect end
            }.join(',')
            fc = (Graphics.frame_count rescue '?')
            $stderr.puts "[mkxp-blit] SELF-BLIT #{mname} bmp=#{width}x#{height} args=#{desc} frame=#{fc}"
          end
          orig.bind(self).call(*a, &b)
        end
        $stderr.puts "[mkxp-blit] self-blit probe installed: #{mname}"
      end
    end
  rescue StandardError => e
    $stderr.puts "[mkxp-blit] install failed: #{e.class}: #{e.message}"
  end
end
