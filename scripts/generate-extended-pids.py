#!/usr/bin/env python3
"""Builds Sources/SSMKit/Resources/ExtendedPIDs/subaru_mode22.json from the OBDb Subaru signal sets.

Usage: scripts/generate-extended-pids.py DIR
where DIR holds shallow clones of https://github.com/OBDb/Subaru-Impreza, Subaru-Forester, Subaru-Outback,
Subaru-Crosstrek and Subaru-WRX (folders named Subaru-Impreza and so on).

The OBDb data is licensed CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/). The generated
file is a derived work and keeps that license; see the "license" and "source" fields inside it.
Only commands with a single plain signal on the engine ECU (headers 7E0 and 7A2) are used.
"""
import json, os, sys, collections

base = sys.argv[1]
priority = ["Subaru-Impreza", "Subaru-WRX", "Subaru-Forester", "Subaru-Outback", "Subaru-Crosstrek"]
entries = collections.OrderedDict()
models = collections.defaultdict(list)

for repo in priority:
    path = os.path.join(base, repo, "signalsets", "v3", "default.json")
    if not os.path.exists(path):
        print("skipping", repo, "(not found)", file=sys.stderr)
        continue
    for command in json.load(open(path))["commands"]:
        did = command.get("cmd", {}).get("22")
        header = command.get("hdr")
        signals = command.get("signals", [])
        if not did or header not in ("7E0", "7A2") or len(signals) != 1:
            continue
        signal = signals[0]
        fmt = signal.get("fmt", {})
        if "bix" in fmt or fmt.get("len") not in (8, 16, 24, 32):
            continue
        key = (header, did.upper())
        models[key].append(repo.replace("Subaru-", ""))
        if key in entries:
            continue          # the higher priority model wins
        entries[key] = {
            "header": header,
            "response": command.get("rax") or hex(int(header, 16) + 8)[2:].upper(),
            "did": did.upper(),
            "name": signal["name"],
            "bits": fmt["len"],
            "signed": bool(fmt.get("sign")),
            "mul": fmt.get("mul", 1),
            "div": fmt.get("div", 1),
            "add": fmt.get("add", 0),
            "unit": fmt.get("unit", "scalar"),
            "min": fmt.get("min"),
            "max": fmt.get("max"),
        }

for key, entry in entries.items():
    entry["models"] = sorted(set(models[key]))

out = {
    "source": "OBDb Subaru signal sets (https://github.com/OBDb), engine ECU Mode 22 (UDS ReadDataByIdentifier) values",
    "license": "CC BY-SA 4.0, https://creativecommons.org/licenses/by-sa/4.0/",
    "note": "Community data. Each car answers only some of these; the meaning of a value can differ between models.",
    "entries": list(entries.values()),
}
target = os.path.join(os.path.dirname(__file__), "..", "Sources", "SSMKit", "Resources", "ExtendedPIDs", "subaru_mode22.json")
with open(target, "w") as f:
    json.dump(out, f, indent=1, ensure_ascii=False)
    f.write("\n")
print(f"wrote {len(entries)} entries to {os.path.normpath(target)}")
