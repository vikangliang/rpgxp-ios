$__mkxp_main = self
$__mkxp_rcache = {}
$__mkxp_miss = {}
$__mkxp_resolve = lambda do |s|
  str = s.to_s
  next str if str.empty?
  cached = $__mkxp_rcache[str]
  next cached if cached
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
$stderr.puts "[mkxp-ios] compat hooks v5 installed"
