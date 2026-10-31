import collections, sys
from PIL import Image

im = Image.open(r'c:\Users\Lenovo\CodeBuddy\20260908220535\fuente.png').convert('RGBA')
W, H = im.size
print('size', W, H, file=sys.stderr)

px = im.load()

# overall visible bbox
minx, miny, maxx, maxy = W, H, -1, -1
for y in range(H):
    for x in range(W):
        if px[x, y][3] > 0:
            minx = min(minx, x); maxx = max(maxx, x)
            miny = min(miny, y); maxy = max(maxy, y)
print('visible bbox x:', minx, maxx, 'y:', miny, maxy, file=sys.stderr)

c = collections.Counter()
for y in range(260, 460):
    for x in range(100, 300):
        r, g, b, a = px[x, y]
        if a > 0:
            c[(r, g, b)] += 1
print('region colors:', len(c), file=sys.stderr)
for col, n in c.most_common(25):
    print(col, n, file=sys.stderr)
