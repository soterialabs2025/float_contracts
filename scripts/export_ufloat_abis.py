"""Export deployed UFloat ABIs into abis/{chainId}/{v3|v4}/ and pin by address."""
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

# profile -> (chain, version, [(contractName, address|None)])
PACKAGES: list[tuple[str, str, str, list[tuple[str, str | None]]]] = [
    (
        "ustrategy-v3",
        "8453",
        "v3",
        [
            ("UFloatSwapRouterV3", "0x052Fc86811Ec67E5af3DcA37d398aC72832E5A13"),
            ("UFloatKeeperV3", "0x3eB9aa6eB9d70485918eD87cE0ed1263d0bD6f24"),
            ("UFloatStrategyFactoryV3", "0x40a338E05cccD484bbA1a8da6a98fff0E302f12f"),
            ("UFloatStrategyV3", None),  # clone impl only
            ("UStrategyManager", None),
            ("LiquidityLibraryV2", None),
        ],
    ),
    (
        "ustrategy",
        "8453",
        "v4",
        [
            ("UFloatSwapRouter", "0x45cb7972Fb88127435d4791eAb034f07ED53064a"),
            ("UFloatKeeper", "0x211035197D91C7a8b4D791449051D5163e5d5855"),
            ("UFloatStrategyFactoryV4", "0xC6e260F7DCff98426c8652eED85315DB3965409A"),
            ("UFloatStrategyV4", None),
            ("UStrategyManager", None),
            ("LiquidityLibraryV4", None),
        ],
    ),
    (
        "ustrategy-rh-v3",
        "4663",
        "v3",
        [
            ("UFloatSwapRouterV3", "0x932f208D180dB8e375E17f88e86A9C1a81d7ACa8"),
            ("UFloatKeeperV3", "0xe2E744063446E372B9E28e4BB38aaBFcc6D43eE8"),
            ("UFloatStrategyFactoryV3", "0xA8966d59f38e7bE263C533Ccda87F36eaf5FFefE"),
            ("UFloatStrategyV3", None),
            ("UStrategyManager", None),
            ("LiquidityLibraryV2", "0x381BeC992900215b9752Da4CD5985B04fb6c5D6b"),
        ],
    ),
    (
        "ustrategy-rh-v4",
        "4663",
        "v4",
        [
            ("UFloatSwapRouter", "0x562cfd3C373A649932597AD5D7a7c1CEa8402A76"),
            ("UFloatKeeper", "0x2cF7c9aB33a8248B07435d58cc7754eB1EaB8d12"),
            ("UFloatStrategyFactoryV4", "0xBDE2231aC15DdbACa7A24837875e6F7DF0a855D9"),
            ("UFloatStrategyV4", None),
            ("UStrategyManager", None),
            ("LiquidityLibraryV4", None),
        ],
    ),
]


def ensure_base_v4_profile() -> None:
    toml_path = ROOT / "foundry.toml"
    toml = toml_path.read_text(encoding="utf-8")
    if "[profile.ustrategy]" in toml:
        return
    block = """
# Base Uniswap V4 UFloat.
[profile.ustrategy]
src = "contracts/ustrategy"
out = "artifacts"
extra_output_files = ["abi"]
test = "test"
libs = ["lib", "node_modules"]
solc_version = "0.8.25"
evm_version = "cancun"
optimizer = true
optimizer_runs = 1
via_ir = true
bytecode_hash = "none"
cbor_metadata = false
skip = ["FloatStrategyKeeperOffensive", "TrailingFloor", "ShareStaking.t"]
remappings = [
    "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/",
    "forge-std/=lib/forge-std/src/",
    "@uniswap/v4-core/=lib/v4-core/",
    "@uniswap/v4-periphery/=lib/v4-periphery/",
    "@uniswap/universal-router/=lib/universal-router/",
    "@uniswap/v3-periphery/=lib/universal-router/lib/v3-periphery/",
    "permit2/=lib/v4-periphery/lib/permit2/",
    "solmate/=lib/v4-core/lib/solmate/",
]

"""
    marker = "# Base Uniswap V3 UFloat"
    if marker in toml:
        toml = toml.replace(marker, block + marker, 1)
    else:
        toml += "\n" + block
    toml_path.write_text(toml, encoding="utf-8", newline="\n")
    print("Added [profile.ustrategy]")


def strip_unused_auto_ifaces(pkg: str) -> None:
    iface = ROOT / "contracts" / pkg / "interfaces"
    if not iface.is_dir():
        return
    for name in (
        "IAutoStrategy.sol",
        "IAutoVault.sol",
        "IAutoKeeper.sol",
        "IAutoSwapRouter.sol",
        "IAutoLiquidToken.sol",
        "IAutoOperatorRegistry.sol",
    ):
        p = iface / name
        if p.exists():
            p.unlink()
            print(f"removed {p.relative_to(ROOT)}")


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
    ok = "Compiler run successful" in out or r.returncode == 0
    if not ok:
        print(out[-5000:])
        raise SystemExit(f"build failed: {profile}")
    print(f"ok (log {log.relative_to(ROOT)})")


def find_artifact(contract: str) -> Path | None:
    # Prefer Contract.sol/Contract.json then Contract.abi.json
    exact = list(ARTIFACTS.glob(f"**/{contract}.sol/{contract}.json"))
    if exact:
        return exact[0]
    abi_only = list(ARTIFACTS.glob(f"**/{contract}.sol/{contract}.abi.json"))
    if abi_only:
        return abi_only[0]
    loose = [p for p in ARTIFACTS.rglob(f"{contract}.json") if "build-info" not in p.parts]
    return loose[0] if loose else None


def extract_abi(artifact: Path) -> list:
    data = json.loads(artifact.read_text(encoding="utf-8"))
    if isinstance(data, list):
        return data
    if "abi" not in data:
        raise ValueError(f"no abi in {artifact}")
    return data["abi"]


def export_one(profile: str, chain: str, version: str, contracts: list[tuple[str, str | None]]) -> None:
    forge_build(profile)
    out_dir = ABIS / chain / version
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob("*.json"):
        old.unlink()

    pin_dir = PINNED / chain
    pin_dir.mkdir(parents=True, exist_ok=True)
    ts = int(time.time() * 1000)
    manifest: dict = {"chainId": int(chain), "version": version, "profile": profile, "contracts": {}}

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
            "profile": profile,
            "timestamp": ts,
            "abi": abi,
        }
        dest = out_dir / f"{name}.json"
        dest.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8", newline="\n")
        # also pure-abi sibling for tools that want the array only
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
    ensure_base_v4_profile()
    strip_unused_auto_ifaces("ustrategy")
    strip_unused_auto_ifaces("ustrategy-rh-v4")

    for profile, chain, version, contracts in PACKAGES:
        export_one(profile, chain, version, contracts)

    print("\nExported:")
    for p in sorted(ABIS.glob("*/*/*.json")):
        if p.name == "manifest.json" or p.name.endswith(".abi.json") or not p.name.endswith(".json"):
            if p.name == "manifest.json":
                print(" ", p.relative_to(ROOT))
            continue
        if p.suffix == ".json" and not p.name.endswith(".abi.json"):
            print(" ", p.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
