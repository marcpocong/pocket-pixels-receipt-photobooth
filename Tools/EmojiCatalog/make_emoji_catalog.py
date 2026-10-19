#!/usr/bin/env python3
"""Converts Unicode emoji-test.txt into the compact catalog bundled with the booth app.

Only fully-qualified entries are kept. Skin-tone variants are folded under their base emoji
(like the system keyboard's long-press picker). The "Component" group (bare skin-tone and hair
swatches) is dropped: those are not stickers on their own.
"""
import json
import re
import sys

source, destination = sys.argv[1], sys.argv[2]

SKIN = ["light skin tone", "medium-light skin tone", "medium skin tone", "medium-dark skin tone", "dark skin tone"]
GROUP_KEYS = {
    "Smileys & Emotion": "smileys",
    "People & Body": "people",
    "Animals & Nature": "animals",
    "Food & Drink": "food",
    "Travel & Places": "travel",
    "Activities": "activities",
    "Objects": "objects",
    "Symbols": "symbols",
    "Flags": "flags",
}

version = None
group = subgroup = None
groups = {}
order = []
line_re = re.compile(r"^([0-9A-F ]+?)\s*;\s*(fully-qualified|minimally-qualified|unqualified|component)\s*#\s*(\S+)\s+E(\d+\.\d+)\s+(.+)$")

with open(source, encoding="utf-8") as handle:
    for raw in handle:
        line = raw.rstrip("\n")
        if line.startswith("# Version:"):
            version = line.split(":", 1)[1].strip()
        elif line.startswith("# group:"):
            group = line.split(":", 1)[1].strip()
            subgroup = None
        elif line.startswith("# subgroup:"):
            subgroup = line.split(":", 1)[1].strip()
        elif line and not line.startswith("#"):
            match = line_re.match(line)
            if not match:
                raise SystemExit("Unparsed line: " + line)
            codepoints, status, glyph, emoji_version, name = match.groups()
            if status != "fully-qualified" or group not in GROUP_KEYS:
                continue
            expected = "".join(chr(int(cp, 16)) for cp in codepoints.split())
            if expected != glyph:
                raise SystemExit("Glyph mismatch: " + line)
            base_name, _, qualifier = name.partition(": ")
            qualifiers = [part.strip() for part in qualifier.split(",")] if qualifier else []
            is_skin_variant = bool(qualifiers) and all(part in SKIN for part in qualifiers)
            key = GROUP_KEYS[group]
            if key not in groups:
                groups[key] = {"key": key, "name": group, "emoji": []}
                order.append(key)
            entries = groups[key]["emoji"]
            if is_skin_variant:
                # Attach to the most recent base entry with the same base name.
                for entry in reversed(entries):
                    if entry["n"] == base_name:
                        entry.setdefault("v", []).append(glyph)
                        break
                else:
                    raise SystemExit("Orphan skin variant: " + line)
                continue
            entries.append({
                "g": glyph,
                "n": name,
                "s": subgroup,
                "e": emoji_version,
            })

catalog = {
    "source": "Unicode emoji-test.txt " + str(version) + " (https://unicode.org/Public/emoji/" + str(version) + "/emoji-test.txt)",
    "license": "Unicode License V3 - Copyright (c) 1991-2026 Unicode, Inc. See docs/third-party/UNICODE-LICENSE.txt",
    "unicodeVersion": version,
    "groups": [groups[key] for key in order],
}
with open(destination, "w", encoding="utf-8") as out:
    json.dump(catalog, out, ensure_ascii=False, separators=(",", ":"))

base = sum(len(groups[key]["emoji"]) for key in order)
variants = sum(len(entry.get("v", [])) for key in order for entry in groups[key]["emoji"])
print("version", version, "groups", len(order), "base", base, "skin variants", variants)
