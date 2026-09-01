"""Report which compiled contracts carry unresolved library placeholders.

Run after `forge build` with the relevant FOUNDRY_PROFILE so artifacts/ is current.
"""

import json
import os
import sys

NAMES = [
    "AutoFactoryBv3",
    "AutoSwapRouterBv3",
    "AutoKeeperBv3",
    "AutoStrategyBv3",
    "AutoVaultBv3",
    "ShareStakingBv3",
    "LiquidSharesBv3",
    "AutoFactoryBv4",
    "AutoSwapRouterBv4",
    "AutoKeeperBv4",
    "AutoStrategyBv4",
    "AutoVaultBv4",
    "ShareStakingBv4",
    "LiquidSharesBv4",
    "AutoFactoryRhV4",
    "AutoSwapRouterRhV4",
    "AutoKeeperRhV4",
    "AutoStrategyRhV4",
    "AutoVaultRhV4",
    "ShareStakingRhV4",
    "LiquidSharesRhV4",
]


def main() -> int:
    for name in NAMES:
        path = os.path.join("artifacts", name + ".sol", name + ".json")
        if not os.path.exists(path):
            continue
        with open(path) as handle:
            artifact = json.load(handle)
        link_refs = artifact["bytecode"].get("linkReferences", {})
        libs = sorted({lib for entry in link_refs.values() for lib in entry})
        count = artifact["bytecode"]["object"].count("__$")
        if libs:
            print("{:22} needs {} ({} placeholders)".format(name, ", ".join(libs), count))
        else:
            print("{:22} no linking needed".format(name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
