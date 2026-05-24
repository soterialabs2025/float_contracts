#!/usr/bin/env python3
"""Flatten Forge ABIs to artifacts/<Contract>.abi.json (Remix / ethers friendly).

Run after `forge build` (v4 profile uses out = artifacts):
  python scripts/export-abi.py
  python scripts/export-abi.py LiquidStratMinV4
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / "artifacts"


def export_one(full_json: Path) -> Path | None:
    if full_json.suffix != ".json" or full_json.name.endswith(".abi.json"):
        return None
    if ".dbg.json" in full_json.name:
        return None
    data = json.loads(full_json.read_text(encoding="utf-8"))
    abi = data.get("abi")
    if not isinstance(abi, list):
        return None
    name = full_json.stem
    out = ART / f"{name}.abi.json"
    out.write_text(json.dumps(abi, indent=2) + "\n", encoding="utf-8")
    return out


def main() -> None:
    only = sys.argv[1:] if len(sys.argv) > 1 else None
    written: list[Path] = []
    for sol_dir in sorted(ART.glob("*.sol")):
        for full in sorted(sol_dir.glob("*.json")):
            if only and full.stem not in only:
                continue
            p = export_one(full)
            if p:
                written.append(p)
    if not written:
        raise SystemExit(f"No contract JSON under {ART} — run: forge build --profile v4")
    for p in written:
        print(p.relative_to(ROOT))


if __name__ == "__main__":
    main()
