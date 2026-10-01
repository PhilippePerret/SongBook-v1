#!/usr/bin/env python3
# Usage: sf_title.py <modele.screenflow> <sortie.screenflow> <titre> <performer> [<export.mp4>]
import sys, os, shutil, struct, plistlib, subprocess, math
from plistlib import UID

TPL_TITLE = "COMME D'HABITUDE"
TPL_PERF = "Claude François"
F_X, F_SIZE, F_TEXT = 24, 46, 65
MEASURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "measure.swift")

src, dst, title, perf = sys.argv[1:5]
mp4 = os.path.abspath(sys.argv[5]) if len(sys.argv) > 5 else None
if os.path.exists(dst): sys.exit("La sortie existe déjà.")
shutil.copytree(src, dst)
path = os.path.join(dst, "ScreenFlowDocument.dat")
d = open(path, "rb").read()
_, _, do, dl = struct.unpack(">QQQQ", d[16:48])
tail = d[48:64]
archive = plistlib.loads(d[do:do+dl])
meta = d[do+dl:]
objs = archive["$objects"]

def clip_of(text):
    si = objs.index(text)
    ai = next(i for i, o in enumerate(objs) if isinstance(o, dict) and o.get("NSString") == UID(si))
    ci = next(i for i, o in enumerate(objs) if isinstance(o, dict) and o.get("NS.objects", [None]*66)[F_TEXT:F_TEXT+1] == [UID(ai)])
    return si, ai, objs[ci]["NS.objects"]

def font_of(ai):
    attrs = objs[objs[ai]["NSAttributes"].data]
    for k, v in zip(attrs["NS.keys"], attrs["NS.objects"]):
        if objs[k.data] == "NSFont":
            f = objs[v.data]
            return objs[f["NSName"].data], f["NSSize"]

def width(text, font, size):
    out = subprocess.run(["swift", MEASURE, font, str(size), text], capture_output=True, text=True, check=True).stdout
    return math.ceil(float(out.strip().split()[-2]))

def set_val(fields, idx, value):
    objs.append(value)
    fields[idx] = UID(len(objs) - 1)

for old, new, center in ((TPL_TITLE, title, True), (TPL_PERF, perf, False)):
    si, ai, fields = clip_of(old)
    objs[si] = new
    font, size = font_of(ai)
    h = objs[fields[F_SIZE].data].strip("{}").split(",")[1].strip()
    set_val(fields, F_SIZE, "{%d, %s}" % (width(new, font, size), h))
    if center:
        set_val(fields, F_X, 0.0)

if mp4:
    ki = objs.index("filePath")
    for o in objs:
        if isinstance(o, dict) and UID(ki) in o.get("NS.keys", []) and objs.index("outputWidth") in [k.data for k in o["NS.keys"]]:
            objs.append(mp4)
            o["NS.objects"][o["NS.keys"].index(UID(ki))] = UID(len(objs) - 1)

body = plistlib.dumps(archive, fmt=plistlib.FMT_BINARY, sort_keys=False)
header = d[:16] + struct.pack(">QQQQ", 64 + len(body), len(meta), 64, len(body)) + tail
open(path, "wb").write(header + body + meta)
print("Fait :", dst)
