import collections
from PIL import Image

im = Image.open(r'c:\Users\Lenovo\CodeBuddy\20260908220535\fuente.png').convert('RGBA')
print('size:', im.size)
c = collections.Counter(im.getdata())
for col, n in c.most_common(50):
    print(col, n)
