#!/usr/bin/env python3
"""
Parses CombatMaster-Full-Offsets C++ headers and updates config.json
with current offset values. Called by the GitHub Actions workflow.

Usage: python3 sync_offsets.py <offsets_repo_dir> <config_json_path>
"""
import sys
import os
import re
import json
import glob

# C++ constant → config.json key mapping.
# If the upstream repo uses a different name, add it here.
KEY_MAP = {
    # Player
    "Health":            "Health",
    "Armor":             "Armor",
    "Position":          "Position",
    "TeamId":            "TeamId",
    "IsVisible":         "IsVisible",
    "IsLocalPlayer":     "IsLocal",
    # Collections
    "ListCount":         "ListCount",
    "ListItems":         "ListItems",
    "ArrayData":         "ArrayData",
    # Camera
    "ViewMatrix":        "ViewMatrix",
    "ProjectionMatrix":  "ProjMatrix",
    "ProjMatrix":        "ProjMatrix",
}

# Matches lines like:
#   constexpr uintptr_t Health = 0x12C;
#   static constexpr uintptr_t Health = 0x12C;
LINE_RE = re.compile(
    r"constexpr\s+uintptr_t\s+(\w+)\s*=\s*(0x[0-9A-Fa-f]+|\d+)\s*;"
)


def parse_header(path):
    """Return dict {constant_name: hex_string} for all uintptr_t constants in file."""
    out = {}
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                m = LINE_RE.search(line)
                if m:
                    name, val = m.group(1), m.group(2)
                    # Normalize to 0x-prefixed hex
                    if val.lower().startswith("0x"):
                        hexval = val.lower()
                    else:
                        hexval = hex(int(val))
                    out[name] = hexval
    except Exception as e:
        print(f"  parse error {path}: {e}")
    return out


def main():
    if len(sys.argv) != 3:
        print("usage: sync_offsets.py <offsets_repo_dir> <config_json_path>")
        sys.exit(1)

    repo_dir = sys.argv[1]
    cfg_path = sys.argv[2]

    # 1. Load existing config.json (or start from empty template)
    if os.path.exists(cfg_path):
        with open(cfg_path, "r", encoding="utf-8") as f:
            try:
                cfg = json.load(f)
            except Exception:
                cfg = {}
    else:
        cfg = {}

    cfg.setdefault("version", "1.0.0")
    cfg.setdefault("min_dylib_version", "1.0.0")
    cfg.setdefault("message", "")
    cfg.setdefault("offsets", {})
    cfg.setdefault("features", {
        "aimbot": True, "esp": True, "visuals": True,
        "weapon": True, "misc": True, "players": True,
        "config": True, "settings": True,
    })
    cfg.setdefault("assets", {
        "ball":   "https://i.imgur.com/MQG4stU.png",
        "header": "https://i.imgur.com/Cnzjdjh.png",
        "sidebar":"https://i.imgur.com/vLJmsVo.png",
    })

    # 2. Find all header / source files in the offsets repo
    files = []
    for ext in ("h", "hpp", "hh"):
        files += glob.glob(os.path.join(repo_dir, "**", f"*.{ext}"), recursive=True)

    if not files:
        print("no header files found — leaving config.json unchanged")
        with open(cfg_path, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2)
        return

    # 3. Parse each file, merge results
    found = {}
    for path in files:
        for k, v in parse_header(path).items():
            found[k] = v

    print(f"parsed {len(found)} constants from {len(files)} files")

    # 4. Map to config keys
    updated = 0
    for src_name, dst_key in KEY_MAP.items():
        if src_name in found:
            cfg["offsets"][dst_key] = found[src_name]
            updated += 1

    print(f"updated {updated} offset values in config")

    # 5. Write back
    with open(cfg_path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)

    print("config.json written")


if __name__ == "__main__":
    main()
