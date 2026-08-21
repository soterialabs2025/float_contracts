"""Export AutoVault ABIs into base-abis/{bv3,bv4} and rh-abis/{rhv3,rhv4,sv3}."""
from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "artifacts"

# (profile, out_dir, chain_id, product_key, package_substr, contracts)
PACKAGES: list[tuple[str, Path, int, str, str, list[tuple[str, str | None]]]] = [
    (
        "base-v3",
        ROOT / "base-abis" / "bv3",
        8453,
        "bv3",
        "auto-vaults-base-v3",
        [
            ("AutoOperatorRegistryBv3", "0xa53f7e8278f3ADCd975B9671b91744BB4CA407d8"),
            ("AutoFactoryBv3", "0x1cC9F1C0FcB8B5203a8d88176d7d498d49d9F060"),
            ("AutoSwapRouterBv3", "0x07758574b154dF860748748365C35B15d869Cb2d"),
            ("AutoKeeperBv3", "0xdd66727dB1D19345d3f5468e4A7a9073F28b591B"),
            ("AutoStrategyBv3", None),
            ("AutoVaultBv3", None),
            ("AutoStrategyManagerBv3", None),
            ("LiquidSharesBv3", None),
            ("ShareStakingBv3", None),
        ],
    ),
    (
        "base-v4",
        ROOT / "base-abis" / "bv4",
        8453,
        "bv4",
        "auto-vault-base-v4",
        [
            ("AutoOperatorRegistryBv4", "0xa53f7e8278f3ADCd975B9671b91744BB4CA407d8"),
            ("AutoFactoryBv4", "0x66B94BE9a2bBCF7896f2406f51545795C15b9181"),
            ("AutoSwapRouterBv4", "0xC64843B634839efc3C1AD3D32FCCb02F4eFC9f5e"),
            ("AutoKeeperBv4", "0x68f9fD0c4Ad3B8079d27396510d9f183125ba5f3"),
            ("AutoStrategyBv4", None),
            ("AutoVaultBv4", None),
            ("AutoStrategyManagerBv4", None),
            ("LiquidSharesBv4", None),
            ("ShareStakingBv4", None),
        ],
    ),
    (
        "rh-v3",
        ROOT / "rh-abis" / "rhv3",
        4663,
        "rhv3",
        "auto-vaults-rh-v3",
        [
            ("AutoOperatorRegistryRhV3", "0x7df1120a04D82eA92EA2d5AA005e3316B37b936E"),
            ("AutoFactoryRhV3", "0xe84eddEA07f31535201aD826235fA49Cd7b44e07"),
            ("AutoSwapRouterRhV3", "0x8A8c18445792e04e8512D5c6CD680331F9575a3F"),
            ("AutoKeeperRhV3", "0xD35CE6610AcB37D545bb5ec4192fC50505Dd26Ad"),
            ("SoteriaFeeManagerRhV3", "0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE"),
            ("AutoStrategyRhV3", None),
            ("AutoVaultRhV3", None),
            ("AutoStrategyManagerRhV3", None),
            ("LiquidSharesRhV3", None),
            ("ShareStakingRhV3", None),
        ],
    ),
    (
        "rh-v4",
        ROOT / "rh-abis" / "rhv4",
        4663,
        "rhv4",
        "auto-vault-rh-v4",
        [
            ("AutoOperatorRegistryRhV4", "0x7df1120a04D82eA92EA2d5AA005e3316B37b936E"),
            ("AutoFactoryRhV4", "0xEDd2772fC4A3DFe73ae4dc068458f4fe36c13F93"),
            ("AutoSwapRouterRhV4", "0x493CDA10F61fb2ad2AC7149EfBBA2114Dd460D05"),
            ("AutoKeeperRhV4", "0x79F9ea39E7e5304791DF8cfEe835F6592c35e022"),
            ("AutoStrategyRhV4", "0x5aDeb07fF21c80D45847f793d84C04fd309E6Cf3"),
            ("AutoVaultRhV4", "0xE510075D1F7F3053Fa9C6D84404Af3D1ecAAD6E7"),
            ("AutoStrategyManagerRhV4", None),
            ("LiquidSharesRhV4", "0x2c0241EDe5Ac7A94Ef393D1c33635f099203912F"),
            ("ShareStakingRhV4", "0x3C62dA3297A5beeD52A65EcB9B92d986Ea0c5ADd"),
        ],
    ),
    (
        "rh-sushi",
        ROOT / "rh-abis" / "sv3",
        4663,
        "sv3",
        "auto-vaults-rh-sushi-v3",
        [
            ("AutoOperatorRegistrySv3", "0x7df1120a04D82eA92EA2d5AA005e3316B37b936E"),
            ("AutoFactorySv3", "0xA8832320F183bac9C019048Fb7578009571E29ad"),
            ("AutoSwapRouterSv3", "0x568dCA271e5F7edb9769f5eA6076e2DA8D4014e8"),
            ("AutoKeeperSv3", "0x3Cb0A8c25356BF5764C4510A79458e73a6639372"),
            ("AutoStrategySv3", None),
            ("AutoVaultSv3", None),
            ("AutoStrategyManagerSv3", None),
            ("LiquidSharesSv3", None),
            ("ShareStakingSv3", None),
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
            ["forge", "build", "--skip", "test", "--skip", "script"],
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


def find_artifact(contract: str, package_substr: str) -> Path | None:
    exact = list(ARTIFACTS.glob(f"**/{contract}.sol/{contract}.json"))
    preferred = [p for p in exact if package_substr in str(p).replace("\\", "/")]
    if preferred or exact:
        return (preferred or exact)[0]
    loose = [p for p in ARTIFACTS.rglob(f"{contract}.json") if "build-info" not in p.parts]
    preferred = [p for p in loose if package_substr in str(p).replace("\\", "/")]
    return (preferred or loose or [None])[0]


def extract_abi(artifact: Path) -> list:
    data = json.loads(artifact.read_text(encoding="utf-8"))
    if isinstance(data, list):
        return data
    if "abi" not in data:
        raise ValueError(f"no abi in {artifact}")
    return data["abi"]


def export_one(
    profile: str,
    out_dir: Path,
    chain_id: int,
    product: str,
    package_substr: str,
    contracts: list[tuple[str, str | None]],
) -> None:
    forge_build(profile)
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob("*.json"):
        old.unlink()

    ts = int(time.time() * 1000)
    manifest: dict = {
        "chainId": chain_id,
        "product": product,
        "profile": profile,
        "contracts": {},
    }

    for name, address in contracts:
        art = find_artifact(name, package_substr)
        if art is None:
            print("MISSING", name)
            continue
        abi = extract_abi(art)
        payload = {
            "name": name,
            "address": address,
            "chainId": chain_id,
            "product": product,
            "profile": profile,
            "timestamp": ts,
            "abi": abi,
        }
        (out_dir / f"{name}.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8", newline="\n")
        (out_dir / f"{name}.abi.json").write_text(json.dumps(abi, indent=2) + "\n", encoding="utf-8", newline="\n")
        manifest["contracts"][name] = {
            "address": address,
            "artifact": str(art.relative_to(ROOT)).replace("\\", "/"),
            "abiEntries": len(abi),
        }
        print(f"wrote {name} ({len(abi)})")

    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8", newline="\n")
    print("done", out_dir.relative_to(ROOT))


def main() -> int:
    for profile, out_dir, chain_id, product, package_substr, contracts in PACKAGES:
        export_one(profile, out_dir, chain_id, product, package_substr, contracts)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
