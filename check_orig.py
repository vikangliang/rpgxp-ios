import collections, sys
from PIL import Image

p = r'D:\pokemon kit\开发工具\宝可梦sp4\Graphics\Characters\fuente.png'
im = Image.open(p)
print('mode:', im.mode, 'size:', im.size, file=sys.stderr)
im = im.convert('RGBA')
px = im.load()
W, H = im.size

c = collections.Counter()
for y in range(H):
    for x in range(W):
        r, g, b, a = px[x, y]
        if a > 0:
            c[(r, g, b)] += 1
print('visible colors:', len(c), file=sys.stderr)
for col, n in c.most_common(30):
    print(col, n, file=sys.stderr)
