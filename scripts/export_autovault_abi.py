#!/usr/bin/env python3
"""Export AutoVault ABIs into abis/<chain>-<network>/... folders.

Examples:
  python scripts/export_autovault_abi.py contracts/auto-vaults-base-v3/AutoVaultBv3.sol
  python scripts/export_autovault_abi.py AutoVaultBv3
  python scripts/export_autovault_abi.py --package auto-vaults-base-v3
  python scripts/export_autovault_abi.py --list
  python scripts/export_autovault_abi.py AutoVaultBv3 --no-build
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "artifacts"

# package_dir (under contracts/) -> forge profile, abis out dir (under abis/), chainId
PACKAGES: dict[str, dict] = {
    "auto-vaults-base-v3": {
        "profile": "base-v3",
        "out": "8453-base/v3/auto-vault-v3",
        "chainId": 8453,
        "product": "auto-vault-v3",
    },
    "auto-vault-base-v4": {
        "profile": "base-v4",
        "out": "8453-base/v4/auto-vault-v4",
        "chainId": 8453,
        "product": "auto-vault-v4",
    },
    "auto-vaults-rh-v3": {
        "profile": "rh-v3",
        "out": "4663-rh/v3/auto-vault-v3",
        "chainId": 4663,
        "product": "auto-vault-v3",
    },
    "auto-vault-rh-v4": {
        "profile": "rh-v4",
        "out": "4663-rh/v4/auto-vault-v4",
        "chainId": 4663,
        "product": "auto-vault-v4",
    },
    "auto-vaults-rh-sushi-v3": {
        "profile": "rh-sushi",
        "out": "4663-sushi/auto-vault-sushi",
        "chainId": 4663,
        "product": "auto-vault-sushi",
    },
}


def normalize_sep(p: str) -> str:
    return p.replace("\\", "/")


def resolve_target(raw: str) -> tuple[str, str]:
    """Return (package_key, contract_name) from a path or bare contract name."""
    s = normalize_sep(raw).strip().rstrip("/")
    if s.endswith(".sol"):
        s = s[: -len(".sol")]
    # Strip leading junk: contracts/, ./, absolute roots
    parts = Path(s).parts
    # Find package folder name in path
    for i, part in enumerate(parts):
        if part in PACKAGES:
            package = part
            # Contract is last path segment (file stem already stripped)
            name = parts[-1]
            if name == package:
                raise SystemExit(f"Pass a contract file/name, not only the package: {raw}")
            return package, name
    # Bare contract name — search packages
    name = Path(s).name
    hits: list[tuple[str, Path]] = []
    for package in PACKAGES:
        cand = ROOT / "contracts" / package / f"{name}.sol"
        if cand.is_file():
            hits.append((package, cand))
        else:
            # nested e.g. libraries/
            for found in (ROOT / "contracts" / package).rglob(f"{name}.sol"):
                hits.append((package, found))
    if not hits:
        raise SystemExit(
            f"Unknown contract {raw!r}. Use --list or a path like "
            f"contracts/auto-vaults-base-v3/AutoVaultBv3.sol"
        )
    if len(hits) > 1:
        pkgs = ", ".join(p for p, _ in hits)
        raise SystemExit(f"Ambiguous {name!r} in packages: {pkgs}. Pass the full path.")
    return hits[0][0], name


def list_packages() -> None:
    print("Packages -> abis/ folder (forge profile)\n")
    for package, meta in PACKAGES.items():
        print(f"  contracts/{package}/")
        print(f"    -> abis/{meta['out']}/  [{meta['profile']}]")
        src = ROOT / "contracts" / package
        sols = sorted(p.stem for p in src.glob("*.sol"))
        if sols:
            print(f"    contracts: {', '.join(sols)}")
        print()


def forge_build(profile: str, skip_build: bool) -> None:
    if skip_build:
        print(f"skip build ({profile})")
        return
    env = os.environ.copy()
    env["FOUNDRY_PROFILE"] = profile
    log = ROOT / "tmp_abi" / f"build-{profile}.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    print(f"Building profile {profile}…")
    with log.open("w", encoding="utf-8", errors="replace") as fh:
        r = subprocess.run(
            ["forge", "build", "--skip", "test"],
            cwd=str(ROOT),
            env=env,
            stdout=fh,
            stderr=subprocess.STDOUT,
        )
    out = log.read_text(encoding="utf-8", errors="replace")
    if "Compiler run successful" not in out and r.returncode != 0:
        print(out[-4000:])
        raise SystemExit(1)
    print("compile ok")


def find_artifact(package: str, name: str) -> Path | None:
    needle = normalize_sep(f"contracts/{package}")
    arts = list(ARTIFACTS.glob(f"**/{name}.sol/{name}.json"))
    preferred = [p for p in arts if needle in normalize_sep(str(p))]
    if preferred or arts:
        return (preferred or arts)[0]
    loose = [p for p in ARTIFACTS.rglob(f"{name}.json") if "build-info" not in p.parts]
    preferred = [p for p in loose if needle in normalize_sep(str(p))]
    return (preferred or loose or [None])[0]


def write_abi(package: str, name: str, meta: dict) -> Path:
    art = find_artifact(package, name)
    if art is None:
        raise SystemExit(f"MISSING artifact for {name} (package {package}). Build failed or wrong name?")
    data = json.loads(art.read_text(encoding="utf-8"))
    abi = data if isinstance(data, list) else data["abi"]
    out_dir = ROOT / "abis" / meta["out"]
    # If a file was accidentally created at the out path, remove it so we can mkdir.
    if out_dir.is_file():
        out_dir.unlink()
    out_dir.mkdir(parents=True, exist_ok=True)

    wrapped = out_dir / f"{name}.json"
    abi_only = out_dir / f"{name}.abi.json"
    # Always replace same-name outputs (no duplicates / stale copies).
    for p in (wrapped, abi_only):
        if p.is_file():
            p.unlink()

    ts = int(time.time() * 1000)
    payload = {
        "name": name,
        "address": None,
        "chainId": meta["chainId"],
        "product": meta["product"],
        "profile": meta["profile"],
        "package": f"contracts/{package}",
        "timestamp": ts,
        "abi": abi,
    }
    wrapped.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8", newline="\n")
    abi_only.write_text(json.dumps(abi, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(f"replaced abis/{meta['out']}/{name}.abi.json ({len(abi)} entries)")
    return out_dir


def package_contract_names(package: str) -> list[str]:
    src = ROOT / "contracts" / package
    return sorted(p.stem for p in src.glob("*.sol"))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Export one AutoVault contract ABI (or a whole package) into abis/."
    )
    parser.add_argument(
        "target",
        nargs="?",
        help="Contract path or name, e.g. contracts/auto-vaults-base-v3/AutoVaultBv3.sol",
    )
    parser.add_argument(
        "--package",
        help="Export all top-level .sol contracts in this package folder name",
    )
    parser.add_argument("--list", action="store_true", help="List packages and ABI folders")
    parser.add_argument("--no-build", action="store_true", help="Skip forge build; use existing artifacts")
    args = parser.parse_args(argv)

    if args.list:
        list_packages()
        return 0

    if args.package:
        package = args.package.strip().replace("\\", "/").rstrip("/")
        if package.startswith("contracts/"):
            package = package[len("contracts/") :]
        if package not in PACKAGES:
            raise SystemExit(f"Unknown package {package!r}. Use --list.")
        meta = PACKAGES[package]
        forge_build(meta["profile"], args.no_build)
        names = package_contract_names(package)
        if not names:
            raise SystemExit(f"No .sol files in contracts/{package}/")
        out_dir = None
        for name in names:
            out_dir = write_abi(package, name, meta)
        print("done", out_dir.relative_to(ROOT) if out_dir else "")
        return 0

    if not args.target:
        parser.print_help()
        return 1

    package, name = resolve_target(args.target)
    meta = PACKAGES[package]
    forge_build(meta["profile"], args.no_build)
    out_dir = write_abi(package, name, meta)
    print("done", out_dir.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
