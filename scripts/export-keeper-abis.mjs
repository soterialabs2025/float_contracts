import fs from "fs";
import path from "path";
import solc from "solc";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, "..");

const remappings = [
  ["@openzeppelin/contracts/", path.join(root, "lib/openzeppelin-contracts/contracts/")],
  ["interfaces/", path.join(root, "interfaces/")],
  ["contracts/", path.join(root, "contracts/")],
];

function resolveImport(importPath) {
  for (const [prefix, base] of remappings) {
    if (importPath.startsWith(prefix)) {
      return path.join(base, importPath.slice(prefix.length));
    }
  }
  // relative imports resolved against current file by findImport callback context
  return null;
}

function loadSource(filePath) {
  return fs.readFileSync(filePath, "utf8");
}

function findImports(importPath) {
  const mapped = resolveImport(importPath);
  if (mapped && fs.existsSync(mapped)) {
    return { contents: loadSource(mapped) };
  }
  const candidates = [
    path.join(root, importPath),
    path.join(root, "contracts", importPath),
    path.join(root, "contracts/v4", importPath),
    path.join(root, "interfaces", importPath),
    // FloatKeeper: ../interfaces/...
    path.join(root, "interfaces", path.basename(importPath)),
    // FloatKeeperV4 / UFloatKeeper: ./interfaces/...
    path.join(root, "contracts/v4/interfaces", path.basename(importPath)),
    path.join(root, "contracts/v4", importPath.replace(/^\.\//, "")),
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return { contents: loadSource(c) };
  }
  return { error: `File not found: ${importPath}` };
}

function compile(entryRel) {
  const entryAbs = path.join(root, entryRel);
  const sources = { [entryRel.replace(/\\/g, "/")]: { content: loadSource(entryAbs) } };
  const input = {
    language: "Solidity",
    sources,
    settings: {
      optimizer: { enabled: true, runs: 200 },
      outputSelection: { "*": { "*": ["abi"] } },
    },
  };
  const output = JSON.parse(solc.compile(JSON.stringify(input), { import: findImports }));
  if (output.errors?.some((e) => e.severity === "error")) {
    console.error(output.errors.map((e) => e.formattedMessage || e.message).join("\n"));
    process.exit(1);
  }
  const fileKey = entryRel.replace(/\\/g, "/");
  const contracts = output.contracts[fileKey];
  if (!contracts) {
    console.error(`No contracts in output for ${fileKey}`, Object.keys(output.contracts || {}));
    process.exit(1);
  }
  return contracts;
}

const abisDir = path.join(root, "abis");
fs.mkdirSync(abisDir, { recursive: true });

const targets = [
  { entry: "contracts/FloatKeeper.sol", name: "FloatKeeper" },
  { entry: "contracts/v4/FloatKeeperV4.sol", name: "FloatKeeperV4" },
  { entry: "contracts/v4/UFloatKeeper.sol", name: "UFloatKeeper" },
];

for (const t of targets) {
  const contracts = compile(t.entry);
  const artifact = contracts[t.name];
  if (!artifact) {
    console.error(`Missing ${t.name} in`, Object.keys(contracts));
    process.exit(1);
  }
  const outPath = path.join(abisDir, `${t.name}.abi.json`);
  fs.writeFileSync(outPath, JSON.stringify(artifact.abi, null, 2) + "\n");
  console.log(`Wrote ${outPath} (${artifact.abi.length} entries)`);
}
