"""Export RH AutoVault ABIs into abis/4663/{v3,v4}/autovault/."""
from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "artifacts"
ABIS = ROOT / "abis"
PINNED = ROOT / ".deploys" / "pinned-contracts"

PACKAGES: list[tuple[str, str, str, list[tuple[str, str | None]]]] = [
    (
        "rh-v3",
        "4663",
        "v3",
        [
            ("AutoOperatorRegistry", "0x7df1120a04D82eA92EA2d5AA005e3316B37b936E"),
            ("AutoFactoryV3Rh", "0xeCad673d6B338D9b530401105332FFD55D35696F"),
            ("AutoSwapRouterV3Rh", "0xB76cdfF814220334Bb46C247F5D7f5d6bE7c8d3B"),
            ("AutoKeeper", "0x6ef6afF9Dc71202252B9A0c95E1193aD7D1e5795"),
            ("SoteriaFeeManagerRh", "0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE"),
            ("AutoStrategyV3Rh", None),
            ("AutoVaultV3Rh", None),
            ("AutoStrategyManagerV2", None),
            ("LiquidShares", None),
            ("ShareStaking", None),
        ],
    ),
    (
        "rh-v4",
        "4663",
        "v4",
        [
            ("AutoOperatorRegistry", "0x7df1120a04D82eA92EA2d5AA005e3316B37b936E"),
            ("AutoFactoryV2", "0x43799407FB4B32625DEE5c6b5F9f7Ea5A62fc685"),
            ("AutoSwapRouter", "0x5bD973F52Fb5c6a1f5C1D214FE9d1Cd58B8C2FbF"),
            ("AutoKeeper", "0xC05361895FaB7826137A0b8B3C6726A431f5aAe8"),
            ("AutoStrategyV2", None),
            ("AutoVaultV2", None),
            ("AutoStrategyManagerV2", None),
            ("LiquidShares", None),
            ("ShareStaking", None),
            ("AutoLiquidToken", None),
            ("LiquidityLibraryV4", None),
        ],
    ),
]


def forge_build(profile: str) -> None:
    env = os.environ.copy()
    env["FOUNDRY_PROFILE"] = profile
    log = ROOT / "tmp_abi" / f"build-{profile}.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    print(f"\n=== build {profile} ===")
    with log.open("w", encoding="utf-8", errors="replace") as fh:
        r = subprocess.run(
            ["forge", "build"],
            cwd=str(ROOT),
            env=env,
            stdout=fh,
            stderr=subprocess.STDOUT,
        )
    out = log.read_text(encoding="utf-8", errors="replace")
    if "Compiler run successful" not in out and r.returncode != 0:
        print(out[-5000:])
        raise SystemExit(f"build failed: {profile}")
    print(f"ok (log {log.relative_to(ROOT)})")


def find_artifact(contract: str) -> Path | None:
    exact = list(ARTIFACTS.glob(f"**/{contract}.sol/{contract}.json"))
    if exact:
        # Prefer package-local when multiple copies exist
        preferred = [p for p in exact if "auto-vault" in str(p).replace("\\", "/")]
        return (preferred or exact)[0]
    abi_only = list(ARTIFACTS.glob(f"**/{contract}.sol/{contract}.abi.json"))
    if abi_only:
        preferred = [p for p in abi_only if "auto-vault" in str(p).replace("\\", "/")]
        return (preferred or abi_only)[0]
    loose = [p for p in ARTIFACTS.rglob(f"{contract}.json") if "build-info" not in p.parts]
    if not loose:
        return None
    preferred = [p for p in loose if "auto-vault" in str(p).replace("\\", "/")]
    return (preferred or loose)[0]


def extract_abi(artifact: Path) -> list:
    data = json.loads(artifact.read_text(encoding="utf-8"))
    if isinstance(data, list):
        return data
    if "abi" not in data:
        raise ValueError(f"no abi in {artifact}")
    return data["abi"]


def export_one(profile: str, chain: str, version: str, contracts: list[tuple[str, str | None]]) -> None:
    forge_build(profile)
    out_dir = ABIS / chain / version / "autovault"
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob("*.json"):
        old.unlink()

    pin_dir = PINNED / chain
    pin_dir.mkdir(parents=True, exist_ok=True)
    ts = int(time.time() * 1000)
    manifest: dict = {
        "chainId": int(chain),
        "version": version,
        "product": "autovault",
        "profile": profile,
        "contracts": {},
    }

    for name, address in contracts:
        art = find_artifact(name)
        if art is None:
            print(f"  MISSING {name}")
            continue
        abi = extract_abi(art)
        payload = {
            "name": name,
            "address": address,
            "chainId": int(chain),
            "version": version,
            "product": "autovault",
            "profile": profile,
            "timestamp": ts,
            "abi": abi,
        }
        dest = out_dir / f"{name}.json"
        dest.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8", newline="\n")
        (out_dir / f"{name}.abi.json").write_text(json.dumps(abi, indent=2) + "\n", encoding="utf-8", newline="\n")
        manifest["contracts"][name] = {
            "address": address,
            "artifact": str(art.relative_to(ROOT)).replace("\\", "/"),
            "abiEntries": len(abi),
        }
        print(f"  {dest.relative_to(ROOT)} ({len(abi)})")
        if address:
            pin = pin_dir / f"{address}.json"
            pin.write_text(
                json.dumps({"name": name, "address": address, "timestamp": ts, "abi": abi}, indent=2) + "\n",
                encoding="utf-8",
                newline="\n",
            )
            print(f"  pinned {pin.relative_to(ROOT)}")

    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8", newline="\n")


def main() -> int:
    for profile, chain, version, contracts in PACKAGES:
        export_one(profile, chain, version, contracts)
    print("\nExported:")
    for p in sorted((ABIS / "4663").glob("*/autovault/*.json")):
        if p.name.endswith(".abi.json"):
            continue
        print(" ", p.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
