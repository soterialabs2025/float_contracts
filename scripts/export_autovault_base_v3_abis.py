"""Export Base AutoVault V3 ABIs into abis/8453/v3/autovault/."""
from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "artifacts"
OUT = ROOT / "abis" / "8453" / "v3" / "autovault"
PINNED = ROOT / ".deploys" / "pinned-contracts" / "8453"

CONTRACTS = [
    ("AutoOperatorRegistry", "0xa53f7e8278f3ADCd975B9671b91744BB4CA407d8"),
    ("AutoFactoryV3", "0xc8f9126c289df82F5e3D1679Fba0BcB7F983fC87"),
    ("AutoSwapRouterV3", "0x575f20F17b39220Bded0B3be4B6B42146645560a"),
    ("AutoKeeper", "0xF60Bb8318A95dCe44bA13B1d04Ffd9498e00f57d"),
    ("AutoStrategyV3", None),
    ("AutoVaultV3", None),
    ("AutoStrategyManagerV2", None),
    ("LiquidShares", None),
    ("ShareStaking", None),
]


def main() -> int:
    env = os.environ.copy()
    env["FOUNDRY_PROFILE"] = "base-v3"
    log = ROOT / "tmp_abi" / "build-base-v3.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w", encoding="utf-8", errors="replace") as fh:
        r = subprocess.run(["forge", "build"], cwd=str(ROOT), env=env, stdout=fh, stderr=subprocess.STDOUT)
    out = log.read_text(encoding="utf-8", errors="replace")
    if "Compiler run successful" not in out and r.returncode != 0:
        print(out[-3000:])
        return 1

    OUT.mkdir(parents=True, exist_ok=True)
    PINNED.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*.json"):
        old.unlink()
    ts = int(time.time() * 1000)
    manifest = {"chainId": 8453, "version": "v3", "product": "autovault", "profile": "base-v3", "contracts": {}}

    for name, address in CONTRACTS:
        arts = list(ARTIFACTS.glob(f"**/{name}.sol/{name}.json"))
        preferred = [p for p in arts if "auto-vaults-base-v3" in str(p).replace("\\", "/")]
        art = (preferred or arts or [None])[0]
        if art is None:
            loose = [p for p in ARTIFACTS.rglob(f"{name}.json") if "build-info" not in p.parts]
            preferred = [p for p in loose if "auto-vaults-base-v3" in str(p).replace("\\", "/")]
            art = (preferred or loose or [None])[0]
        if art is None:
            print("MISSING", name)
            continue
        data = json.loads(art.read_text(encoding="utf-8"))
        abi = data if isinstance(data, list) else data["abi"]
        payload = {
            "name": name,
            "address": address,
            "chainId": 8453,
            "version": "v3",
            "product": "autovault",
            "profile": "base-v3",
            "timestamp": ts,
            "abi": abi,
        }
        (OUT / f"{name}.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8", newline="\n")
        (OUT / f"{name}.abi.json").write_text(json.dumps(abi, indent=2) + "\n", encoding="utf-8", newline="\n")
        manifest["contracts"][name] = {
            "address": address,
            "artifact": str(art.relative_to(ROOT)).replace("\\", "/"),
            "abiEntries": len(abi),
        }
        print(f"wrote {name} ({len(abi)})")
        if address:
            (PINNED / f"{address}.json").write_text(
                json.dumps({"name": name, "address": address, "timestamp": ts, "abi": abi}, indent=2) + "\n",
                encoding="utf-8",
                newline="\n",
            )
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8", newline="\n")
    print("done", OUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
