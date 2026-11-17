#!/usr/bin/env python3
"""SimPilot 技術驗證用的薄包裝（路線 1b：CoreSimulator AX 橋接）。
  sp.py elements --udid U [-o out.json]
  sp.py tap --label 文字 --udid U [-o result.json]
canvas：axdump 回的根 frame 永遠是直向，改用 devicectl（公開）回報的「亮著的那面＋旋轉角」。"""
import argparse, json, os, subprocess, sys, tempfile, time
HERE = os.path.dirname(os.path.abspath(__file__))

def displays(udid):
    with tempfile.NamedTemporaryFile(suffix=".json") as f:
        subprocess.run(["xcrun", "devicectl", "device", "info", "displays", "--device", udid, "-q", "-j", f.name],
                       check=True, capture_output=True)
        return json.load(open(f.name))["result"]

def canvas(udid):
    r = displays(udid)
    act = next(d for d in r["displays"] if d["active"])
    w, h = act["bounds"][1][0] / act["pointScale"], act["bounds"][1][1] / act["pointScale"]
    if act["currentOrientation"] in ("rot90", "rot270"): w, h = h, w
    return [round(w, 2), round(h, 2)], act

def dump(udid, press=None):
    args = [os.path.join(HERE, "axdump"), udid, "0"] + (["--press", press] if press else [])
    p = subprocess.run(args, capture_output=True, text=True)
    if p.returncode: return {"ok": False, "error": (p.stdout + p.stderr).strip()}, p.stderr
    d = json.loads(p.stdout); return d, p.stderr

def sig(d):
    W, H = d["data"]["canvasSize"]; out = set()
    for e in d["data"]["elements"]:
        (x, y), (w, h) = e["frame"]
        if x + w > 0 and y + h > 0 and x < W and y < H and e["label"]:
            out.add((e["label"], round(x), round(y), e.get("value")))
    return out

ap = argparse.ArgumentParser(); ap.add_argument("cmd", choices=["elements", "tap"])
ap.add_argument("--udid", required=True); ap.add_argument("--label"); ap.add_argument("-o")
a = ap.parse_args(); t0 = time.time()
cv, act = canvas(a.udid)
if a.cmd == "elements":
    d, _ = dump(a.udid)
    if d.get("ok"):
        d["data"]["canvasSize"] = cv; d["data"]["debug"]["activeDisplay"] = act["name"]
        d["data"]["debug"]["seconds_total"] = round(time.time() - t0, 3)
    out = d
else:
    before, _ = dump(a.udid); before["data"]["canvasSize"] = cv
    after, log = dump(a.udid, a.label)
    if not after.get("ok"): out = after
    else:
        after["data"]["canvasSize"], _ = canvas(a.udid)
        b, c = sig(before), sig(after)
        out = {"ok": True, "pressed": log.strip(), "screen_changed": b != c,
               "appeared": sorted({x[0] for x in c - b})[:30], "disappeared": sorted({x[0] for x in b - c})[:30],
               "seconds": round(time.time() - t0, 3)}
s = json.dumps(out, ensure_ascii=False, sort_keys=True)
open(a.o, "w").write(s) if a.o else print(s)
if a.o: print(json.dumps({k: v for k, v in out.items() if k != "data"} if a.cmd == "tap" else
                         {"ok": out.get("ok"), "canvas": cv, "n": len(out.get("data", {}).get("elements", []))}, ensure_ascii=False))
