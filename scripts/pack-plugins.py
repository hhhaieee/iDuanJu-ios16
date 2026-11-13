#!/usr/bin/env python3
"""Pack PluginsSrc/<name>/{manifest.json, main.js} into STV/Resources/Plugins/<name>.idjplugin.

.idjplugin = JSON bundle { "manifest": {...}, "files": { "<entry>": "<source>" } } with
manifest.integrity.files[entry] = "sha256-<base64>" (same hash the app pins at install time).
Usage: scripts/pack-plugins.py [out_dir]
"""
import base64, hashlib, json, os, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src_dir = os.path.join(root, "PluginsSrc")
out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "STV", "Resources", "Plugins")
os.makedirs(out_dir, exist_ok=True)
for name in sorted(os.listdir(src_dir)):
    d = os.path.join(src_dir, name)
    mf = os.path.join(d, "manifest.json")
    if not os.path.isfile(mf):
        continue
    manifest = json.load(open(mf, encoding="utf-8"))
    entry = manifest["entry"]
    code = open(os.path.join(d, entry), "rb").read()
    h = "sha256-" + base64.b64encode(hashlib.sha256(code).digest()).decode()
    manifest.setdefault("integrity", {})["files"] = {entry: h}
    bundle = {"manifest": manifest, "files": {entry: code.decode("utf-8")}}
    out = os.path.join(out_dir, name + ".idjplugin")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(bundle, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print(f"{name}: {manifest['id']} {manifest['version']} {h}")
