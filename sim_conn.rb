# 只读模拟：忠实复刻 Game_MapFactory 连接逻辑，实测 81↔78 是否活、落在哪
class Tone; def initialize(*a); end; def self._load(s); Tone.new; end; end
class Color; def initialize(*a); end; def self._load(s); Color.new; end; end
class Table; def initialize(*a); end; def self._load(s); Table.new; end; end
module RPG; end
class RPG::Map
  attr_accessor :width, :height
end
class RPG::Event; end
class RPG::Event::Page
  attr_accessor :condition, :list, :move_route
end
class RPG::Event::Page::Condition; end
class RPG::Event::Page::Graphic; end
class RPG::EventCommand
  attr_accessor :code, :parameters
end
class RPG::MoveRoute; end
class RPG::MoveCommand; end
class RPG::Tileset; end
class RPG::AudioFile; end
class RPG::Weather; end
class RPG::MapInfo; end

BASE = "D:/pokemon kit/开发工具/宝可梦sp4/Data"
DIM_CACHE = {}

def getMapDims(id)
  return DIM_CACHE[id] if DIM_CACHE[id]
  map = Marshal.load(File.binread(File.join(BASE, sprintf("Map%03d.rxdata", id))))
  DIM_CACHE[id] = [map.width, map.height]
end

def getMapEdge(id, edge)
  return 0 if ["N", "W"].include?(edge)
  dims = getMapDims(id)
  return dims[0] if edge == "E"
  return dims[1] if edge == "S"
  dims[0]
end

def normalized_conns_for(id, conns)
  result = []
  conns.each do |conn|
    d = conn.dup
    e1 = getMapEdge(d[0], d[1])
    case d[1]
    when "N", "S"
      d[1] = d[2]; d[2] = e1
    when "E", "W"
      d[1] = e1
    end
    e2 = getMapEdge(d[3], d[4])
    case d[4]
    when "N", "S"
      d[4] = d[5]; d[5] = e2
    when "E", "W"
      d[4] = e2
    end
    result.push(d) if (d[0] == id || d[3] == id)
  end
  result
end

def getNewMap(id, px, py, conns)
  normalized_conns_for(id, conns).each do |conn|
    if conn[0] == id
      mapidB = conn[3]; mapB = getMapDims(conn[3])
      newx = conn[4] - conn[1] + px
      newy = conn[5] - conn[2] + py
    else
      mapidB = conn[0]; mapB = getMapDims(conn[0])
      newx = conn[1] - conn[4] + px
      newy = conn[2] - conn[5] + py
    end
    if newx >= 0 && newx < mapB[0] && newy >= 0 && newy < mapB[1]
      return [mapidB, newx, newy]
    end
  end
  nil
end

conns = Marshal.load(File.binread(File.join(BASE, "map_connections.dat")))
puts "81 尺寸: #{getMapDims(81).inspect}"
puts "78 尺寸: #{getMapDims(78).inspect}"
c = conns.select { |x| (x[0]==78&&x[3]==81)||(x[0]==81&&x[3]==78) }
puts "78/81 原始连接: #{c.inspect}"

puts "\n=== 184 落点 (38,43) 在 81 上，逐步向南走 ==="
(43..60).each do |y|
  r = getNewMap(81, 38, y, conns)
  puts "  81 (38,#{y}) -> #{r.inspect}"
end

puts "\n=== 81 底边缘(y=57 与 y=58)各 x 的连接去向 ==="
[57, 58].each do |y|
  hits = []
  (0..getMapDims(81)[0]).each do |x|
    r = getNewMap(81, x, y, conns)
    hits << [x, r] if r
  end
  puts "  y=#{y}: #{hits.inspect}"
end

puts "\n=== 反向：78 顶边缘(y=-1,0)各 x 的连接去向 ==="
[-1, 0].each do |y|
  hits = []
  (0..getMapDims(78)[0]).each do |x|
    r = getNewMap(78, x, y, conns)
    hits << [x, r] if r
  end
  puts "  y=#{y}: #{hits.inspect}"
end
