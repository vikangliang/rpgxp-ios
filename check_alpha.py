import collections, sys
from PIL import Image

im = Image.open(r'c:\Users\Lenovo\CodeBuddy\20260908220535\fuente.png').convert('RGBA')
W, H = im.size
px = im.load()

# alpha histogram 全图
alpha_counter = collections.Counter()
for y in range(H):
    for x in range(W):
        alpha_counter[px[x, y][3]] += 1
print('alpha histogram:', sorted(alpha_counter.items()), file=sys.stderr)

# 鱼区域 (约 x 0-110, y 300-420) 的 RGB+alpha
c = collections.Counter()
for y in range(300, 430):
    for x in range(0, 115):
        c[px[x, y]] += 1
print('fish region top colors:', file=sys.stderr)
for col, n in c.most_common(12):
    print(col, n, file=sys.stderr)
