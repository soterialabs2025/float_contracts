"""Export Base AutoVault BV4 ABIs into abis/8453-base/v4/auto-vault-v4/."""
from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "artifacts"
OUT = ROOT / "abis" / "8453-base" / "v4" / "auto-vault-v4"
PINNED = ROOT / ".deploys" / "pinned-contracts" / "8453"

CONTRACTS = [
    ("AutoOperatorRegistryBv4", "0xa53f7e8278f3ADCd975B9671b91744BB4CA407d8"),
    ("AutoFactoryBv4", None),
    ("AutoSwapRouterBv4", None),
    ("AutoKeeperBv4", None),
    ("AutoStrategyBv4", None),
    ("AutoVaultBv4", None),
    ("AutoStrategyManagerBv4", None),
    ("LiquidSharesBv4", None),
    ("ShareStakingBv4", None),
]


def find_artifact(name: str) -> Path | None:
    arts = list(ARTIFACTS.glob(f"**/{name}.sol/{name}.json"))
    preferred = [p for p in arts if "auto-vault-base-v4" in str(p).replace("\\", "/")]
    if preferred or arts:
        return (preferred or arts)[0]
    loose = [p for p in ARTIFACTS.rglob(f"{name}.json") if "build-info" not in p.parts]
    preferred = [p for p in loose if "auto-vault-base-v4" in str(p).replace("\\", "/")]
    return (preferred or loose or [None])[0]


def main() -> int:
    env = os.environ.copy()
    env["FOUNDRY_PROFILE"] = "base-v4"
    log = ROOT / "tmp_abi" / "build-base-v4.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    print("Building profile base-v4…")
    with log.open("w", encoding="utf-8", errors="replace") as fh:
        r = subprocess.run(["forge", "build"], cwd=str(ROOT), env=env, stdout=fh, stderr=subprocess.STDOUT)
    out = log.read_text(encoding="utf-8", errors="replace")
    if "Compiler run successful" not in out and r.returncode != 0:
        print(out[-4000:])
        return 1
    print("compile ok")

    OUT.mkdir(parents=True, exist_ok=True)
    PINNED.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*.json"):
        old.unlink()

    ts = int(time.time() * 1000)
    manifest = {
        "chainId": 8453,
        "version": "v4",
        "product": "auto-vault-v4",
        "profile": "base-v4",
        "package": "contracts/auto-vault-base-v4",
        "contracts": {},
    }

    for name, address in CONTRACTS:
        art = find_artifact(name)
        if art is None:
            print("MISSING", name)
            continue
        data = json.loads(art.read_text(encoding="utf-8"))
        abi = data if isinstance(data, list) else data["abi"]
        payload = {
            "name": name,
            "address": address,
            "chainId": 8453,
            "version": "v4",
            "product": "auto-vault-v4",
            "profile": "base-v4",
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

    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8", newline="\n")
    print("done", OUT.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
