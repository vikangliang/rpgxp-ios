from PIL import Image

im = Image.open(r'c:\Users\Lenovo\CodeBuddy\20260908220535\fuente.png').convert('RGBA')
W, H = im.size
px = im.load()

water = [(40,88,104),(48,112,136),(72,136,160),(88,160,176),(128,208,248),(224,231,241)]
for col in water:
    xs, ys = [], []
    for y in range(H):
        for x in range(W):
            r,g,b,a = px[x,y]
            if a > 0 and (r,g,b) == col:
                xs.append(x); ys.append(y)
    if xs:
        print(col, 'bbox x:', min(xs), max(xs), 'y:', min(ys), max(ys), 'count:', len(xs))
    else:
        print(col, 'not found (visible)')
