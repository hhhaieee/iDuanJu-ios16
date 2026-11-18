#!/usr/bin/env python3
"""Pack PluginsSrc/<name>/{manifest.json, main.js} into STV/Resources/Plugins/<name>.zip.

Plugin zip = a plain zip archive containing manifest.json and the entry script
(e.g. main.js) at the archive root. Uses ZIP_STORED (no compression) so the app's
minimal in-app unzip can read it without depending on deflate compatibility.

manifest.integrity.files[entry] = "sha256-<base64>" (the hash the app pins at install).
Usage: scripts/pack-plugins.py [out_dir]
"""
import base64, hashlib, json, os, sys, zipfile

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
    out = os.path.join(out_dir, name + ".zip")
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_STORED) as z:
        z.writestr("manifest.json", json.dumps(manifest, ensure_ascii=False))
        z.writestr(entry, code)
    print(f"{name}: {manifest['id']} {manifest['version']} {h} -> {os.path.basename(out)}")
