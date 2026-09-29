"""Pre-compress the built web app so the server never gzips per request.
Usage: python tool/precompress.py build/web_prod"""
import gzip, os, sys
root = sys.argv[1]
exts = ('.wasm', '.js', '.mjs', '.json', '.html', '.ttf', '.otf', '.css', '.svg')
n = saved = 0
for d, _, files in os.walk(root):
    for f in files:
        p = os.path.join(d, f)
        if not f.endswith(exts) or os.path.getsize(p) < 1024:
            continue
        with open(p, 'rb') as src, gzip.open(p + '.gz', 'wb', compresslevel=9) as dst:
            dst.write(src.read())
        n += 1
        saved += os.path.getsize(p) - os.path.getsize(p + '.gz')
print(f'compressed {n} files, {saved // 1024} KB smaller')
