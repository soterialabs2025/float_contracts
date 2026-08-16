/**
 * Find Uniswap v4 PoolKey(s) on Robinhood (4663) from PoolManager Initialize logs.
 * Upserts into docs/RH_V4_POOLKEYS.md (and docs/rh-v4-poolkeys.json).
 *
 * Usage:
 *   node scripts/find-rh-v4-poolkey.mjs <token>
 *   node scripts/find-rh-v4-poolkey.mjs <token> --pair aeWETH
 *   node scripts/find-rh-v4-poolkey.mjs <token> --any-pair
 *   node scripts/find-rh-v4-poolkey.mjs <token> --json
 *   node scripts/find-rh-v4-poolkey.mjs <token> --no-md
 *   node scripts/find-rh-v4-poolkey.mjs <token> --md-out path/to/file.md
 *
 * Env:
 *   ROBINHOOD_MAIN_RPC_URL  (preferred; falls back to public RH RPC)
 */
import { createPublicClient, http, parseAbiItem, getAddress, isAddress } from "viem";
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, "..");

const CHAIN_ID = 4663;
const POOL_MANAGER = getAddress("0x8366a39CC670B4001A1121B8F6A443A643e40951");
const AE_WETH = getAddress("0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73");
const BASE_WETH = getAddress("0x4200000000000000000000000000000000000006");
const ZERO = "0x0000000000000000000000000000000000000000";

const DEFAULT_RPC = "https://rpc.mainnet.chain.robinhood.com";
const DEFAULT_MD = resolve(ROOT, "docs", "RH_V4_POOLKEYS.md");
const DEFAULT_JSON = resolve(ROOT, "docs", "rh-v4-poolkeys.json");

const initializeEvent = parseAbiItem(
  "event Initialize(bytes32 indexed id, address indexed currency0, address indexed currency1, uint24 fee, int24 tickSpacing, address hooks, uint160 sqrtPriceX96, int24 tick)"
);

function loadEnvRpc() {
  try {
    const envPath = resolve(ROOT, "env");
    const text = readFileSync(envPath, "utf8");
    for (const raw of text.split(/\r?\n/)) {
      const line = raw.trim();
      if (!line || line.startsWith("#") || !line.includes("=")) continue;
      let [k, ...rest] = line.split("=");
      k = k.trim().replace(/^\$env:/, "");
      let v = rest.join("=").trim().replace(/^['"]|['"]$/g, "");
      if (k === "ROBINHOOD_MAIN_RPC_URL" && v) return v;
    }
  } catch {
    /* ignore */
  }
  return process.env.ROBINHOOD_MAIN_RPC_URL || DEFAULT_RPC;
}

function parseArgs(argv) {
  const args = {
    token: null,
    pair: AE_WETH,
    anyPair: false,
    fromBlock: 0n,
    chunk: 50_000n,
    json: false,
    writeMd: true,
    mdOut: DEFAULT_MD,
    jsonOut: DEFAULT_JSON,
  };
  const pos = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--any-pair") args.anyPair = true;
    else if (a === "--json") args.json = true;
    else if (a === "--no-md") args.writeMd = false;
    else if (a === "--md-out") {
      const v = argv[++i];
      if (!v) throw new Error("--md-out needs a path");
      args.mdOut = resolve(ROOT, v);
    } else if (a === "--pair") {
      const v = argv[++i];
      if (!v) throw new Error("--pair needs an address or 'aeWETH'");
      args.pair = v.toLowerCase() === "aeweth" || v.toLowerCase() === "weth" ? AE_WETH : getAddress(v);
    } else if (a === "--from-block") args.fromBlock = BigInt(argv[++i]);
    else if (a === "--chunk") args.chunk = BigInt(argv[++i]);
    else if (a.startsWith("-")) throw new Error(`Unknown flag: ${a}`);
    else pos.push(a);
  }
  if (pos.length !== 1 || !isAddress(pos[0])) {
    throw new Error(
      "Usage: node scripts/find-rh-v4-poolkey.mjs <tokenAddress> [--pair aeWETH|--any-pair] [--json] [--no-md] [--md-out path]"
    );
  }
  args.token = getAddress(pos[0]);
  if (args.anyPair) args.pair = null;
  return args;
}

async function getLogsSmart(client, { args, fromBlock, toBlock, chunk }) {
  try {
    return await client.getLogs({
      address: POOL_MANAGER,
      event: initializeEvent,
      args,
      fromBlock,
      toBlock,
    });
  } catch (e) {
    const msg = String(e?.shortMessage || e?.message || e);
    process.stderr.write(`full-range getLogs failed (${msg.slice(0, 100)}); chunking…\n`);
  }

  const out = [];
  let start = fromBlock;
  let size = chunk;
  while (start <= toBlock) {
    let end = start + size - 1n;
    if (end > toBlock) end = toBlock;
    try {
      const logs = await client.getLogs({
        address: POOL_MANAGER,
        event: initializeEvent,
        args,
        fromBlock: start,
        toBlock: end,
      });
      out.push(...logs);
      start = end + 1n;
      if ((start - fromBlock) % (size * 20n) === 0n) {
        process.stderr.write(`…scanned through block ${start}\n`);
      }
    } catch (e) {
      const msg = String(e?.shortMessage || e?.message || e);
      if (size > 500n && /range|limit|too large|query returned more|block range/i.test(msg)) {
        size = size / 2n;
        if (size < 500n) size = 500n;
        process.stderr.write(`retry chunk=${size}\n`);
        continue;
      }
      throw e;
    }
  }
  return out;
}

function matchesPair(c0, c1, token, pair) {
  const a = c0.toLowerCase();
  const b = c1.toLowerCase();
  const t = token.toLowerCase();
  if (a !== t && b !== t) return false;
  if (!pair) return true;
  const p = pair.toLowerCase();
  return (a === t && b === p) || (b === t && a === p);
}

function warningsForKey(c0, c1) {
  const w = [];
  if (c0 === ZERO || c1 === ZERO) {
    w.push("Contains native ETH address(0) — Float RH UFloat/AutoVault V4 reject this; use aeWETH pair.");
  }
  if (c0 === BASE_WETH || c1 === BASE_WETH) {
    w.push("Uses Base WETH 0x4200… — on Robinhood use aeWETH 0x0Bd7… instead.");
  }
  return w;
}

function formatForContracts(key) {
  return {
    currency0: key.currency0,
    currency1: key.currency1,
    fee: Number(key.fee),
    tickSpacing: Number(key.tickSpacing),
    hooks: key.hooks,
  };
}

function loadStore(jsonPath) {
  if (!existsSync(jsonPath)) {
    return { chainId: CHAIN_ID, poolManager: POOL_MANAGER, aeWeth: AE_WETH, updatedAt: null, pools: {} };
  }
  try {
    const data = JSON.parse(readFileSync(jsonPath, "utf8"));
    if (!data.pools || typeof data.pools !== "object") data.pools = {};
    return data;
  } catch {
    return { chainId: CHAIN_ID, poolManager: POOL_MANAGER, aeWeth: AE_WETH, updatedAt: null, pools: {} };
  }
}

function upsertPools(store, token, pair, pools, scannedAt) {
  let added = 0;
  let updated = 0;
  for (const p of pools) {
    const id = p.poolId.toLowerCase();
    const prev = store.pools[id];
    const entry = {
      poolId: p.poolId,
      token,
      pairFilter: pair,
      poolKey: p.poolKey,
      hookData: p.hookData,
      sqrtPriceX96: p.sqrtPriceX96,
      tick: p.tick,
      txHash: p.txHash,
      blockNumber: p.blockNumber,
      warnings: p.warnings,
      firstSeenAt: prev?.firstSeenAt || scannedAt,
      lastSeenAt: scannedAt,
    };
    if (!prev) added++;
    else updated++;
    store.pools[id] = entry;
  }
  store.updatedAt = scannedAt;
  store.chainId = CHAIN_ID;
  store.poolManager = POOL_MANAGER;
  store.aeWeth = AE_WETH;
  return { added, updated };
}

function renderMarkdown(store) {
  const entries = Object.values(store.pools).sort((a, b) => {
    const ba = BigInt(a.blockNumber || 0);
    const bb = BigInt(b.blockNumber || 0);
    if (ba !== bb) return ba < bb ? -1 : 1;
    return a.poolId.localeCompare(b.poolId);
  });

  const lines = [];
  lines.push("# Robinhood Uniswap V4 PoolKeys");
  lines.push("");
  lines.push(`Chain **${store.chainId}** | PoolManager \`${store.poolManager}\` | aeWETH \`${store.aeWeth}\``);
  lines.push("");
  lines.push(`Collected by \`scripts/find-rh-v4-poolkey.mjs\`. Last update: **${store.updatedAt || "-"}**.`);
  lines.push("");
  lines.push("Use with Float RH V4:");
  lines.push("- UFloat: `setV4PoolConfig(asset, poolKey, hookData)`");
  lines.push("- AutoVault: `deployVaultPackage(asset, poolKey, hookData)`");
  lines.push("- Prefer ASSET/aeWETH keys; reject native ETH `address(0)`.");
  lines.push("");
  lines.push(`## Index (${entries.length})`);
  lines.push("");
  lines.push("| Token | Fee | Tick spacing | Hooks | PoolId | Block |");
  lines.push("|-------|-----|--------------|-------|--------|-------|");
  for (const e of entries) {
    const shortHook =
      e.poolKey.hooks === ZERO ? "`0x0`" : `\`${e.poolKey.hooks.slice(0, 10)}...\``;
    lines.push(
      `| \`${e.token}\` | ${e.poolKey.fee} | ${e.poolKey.tickSpacing} | ${shortHook} | \`${e.poolId.slice(0, 10)}...\` | ${e.blockNumber} |`
    );
  }
  lines.push("");

  for (const e of entries) {
    lines.push(`## \`${e.poolId}\``);
    lines.push("");
    lines.push(`- **token (query):** \`${e.token}\``);
    if (e.pairFilter) lines.push(`- **pair filter:** \`${e.pairFilter}\``);
    lines.push(`- **tx:** \`${e.txHash}\``);
    lines.push(`- **block:** ${e.blockNumber}`);
    lines.push(`- **tick:** ${e.tick}`);
    lines.push(`- **hookData:** \`${e.hookData}\``);
    lines.push(`- **first seen:** ${e.firstSeenAt}`);
    lines.push(`- **last seen:** ${e.lastSeenAt}`);
    if (e.warnings?.length) {
      lines.push(`- **warnings:** ${e.warnings.join("; ")}`);
    }
    lines.push("");
    lines.push("```json");
    lines.push(JSON.stringify(e.poolKey, null, 2));
    lines.push("```");
    lines.push("");
  }

  return lines.join("\n");
}

function writeCollection(store, mdPath, jsonPath) {
  mkdirSync(dirname(mdPath), { recursive: true });
  mkdirSync(dirname(jsonPath), { recursive: true });
  writeFileSync(jsonPath, JSON.stringify(store, null, 2) + "\n", "utf8");
  writeFileSync(mdPath, renderMarkdown(store), "utf8");
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const rpc = loadEnvRpc();
  const client = createPublicClient({
    transport: http(rpc, { timeout: 60_000 }),
  });

  const latest = await client.getBlockNumber();
  process.stderr.write(
    `RH chain ${CHAIN_ID} · PoolManager ${POOL_MANAGER}\n` +
      `token ${opts.token}` +
      (opts.pair ? ` · pair ${opts.pair}` : " · any pair") +
      `\nrpc ${rpc.replace(/\/v2\/.*/, "/v2/***")} · blocks ${opts.fromBlock}→${latest}\n`
  );

  const [as0, as1] = await Promise.all([
    getLogsSmart(client, {
      args: { currency0: opts.token },
      fromBlock: opts.fromBlock,
      toBlock: latest,
      chunk: opts.chunk,
    }),
    getLogsSmart(client, {
      args: { currency1: opts.token },
      fromBlock: opts.fromBlock,
      toBlock: latest,
      chunk: opts.chunk,
    }),
  ]);

  const seen = new Set();
  const pools = [];
  for (const log of [...as0, ...as1]) {
    const { id, currency0, currency1, fee, tickSpacing, hooks, sqrtPriceX96, tick } = log.args;
    if (!currency0 || !currency1) continue;
    const c0 = getAddress(currency0);
    const c1 = getAddress(currency1);
    if (!matchesPair(c0, c1, opts.token, opts.pair)) continue;
    const keyId = `${id}-${c0}-${c1}-${fee}-${tickSpacing}-${hooks}`;
    if (seen.has(keyId)) continue;
    seen.add(keyId);

    const poolKey = formatForContracts({ currency0: c0, currency1: c1, fee, tickSpacing, hooks });
    pools.push({
      poolId: id,
      poolKey,
      hookData: "0x",
      sqrtPriceX96: sqrtPriceX96?.toString?.() ?? String(sqrtPriceX96),
      tick: Number(tick),
      txHash: log.transactionHash,
      blockNumber: log.blockNumber?.toString?.() ?? String(log.blockNumber),
      warnings: warningsForKey(c0, c1),
      setV4PoolConfigArgs: [opts.token, poolKey, "0x"],
      deployVaultPackageArgs: [opts.token, poolKey, "0x"],
    });
  }

  if (pools.length === 0) {
    if (opts.json) {
      console.log(JSON.stringify({ chainId: CHAIN_ID, token: opts.token, pair: opts.pair, pools: [] }, null, 2));
    } else {
      console.log("No Initialize events found for that filter.");
      console.log("Tips: try --any-pair, or check Blockscout for the first LP / Initialize tx.");
    }
    process.exitCode = 1;
    return;
  }

  if (opts.writeMd) {
    const scannedAt = new Date().toISOString();
    const store = loadStore(opts.jsonOut);
    const { added, updated } = upsertPools(store, opts.token, opts.pair, pools, scannedAt);
    writeCollection(store, opts.mdOut, opts.jsonOut);
    process.stderr.write(
      `Wrote ${opts.mdOut.replace(ROOT + "\\", "").replace(ROOT + "/", "")} ` +
        `(+${added} new, ~${updated} refreshed; total ${Object.keys(store.pools).length})\n`
    );
  }

  if (opts.json) {
    console.log(JSON.stringify({ chainId: CHAIN_ID, token: opts.token, pair: opts.pair, pools }, null, 2));
    return;
  }

  console.log(`Found ${pools.length} pool(s):\n`);
  for (const [i, p] of pools.entries()) {
    console.log(`--- #${i + 1} ---`);
    console.log(`poolId:      ${p.poolId}`);
    console.log(`tx:          ${p.txHash}`);
    console.log(`block:       ${p.blockNumber}`);
    console.log(`currency0:   ${p.poolKey.currency0}`);
    console.log(`currency1:   ${p.poolKey.currency1}`);
    console.log(`fee:         ${p.poolKey.fee}`);
    console.log(`tickSpacing: ${p.poolKey.tickSpacing}`);
    console.log(`hooks:       ${p.poolKey.hooks}`);
    console.log(`hookData:    ${p.hookData}`);
    if (p.warnings.length) {
      for (const w of p.warnings) console.log(`WARN: ${w}`);
    }
    console.log("\nPoolKey JSON:");
    console.log(JSON.stringify(p.poolKey, null, 2));
    console.log("");
  }
}

main().catch((e) => {
  console.error(e?.shortMessage || e?.message || e);
  process.exit(1);
});
