# Deployment Guide

Step-by-step instructions to deploy Quicknode Earn from scratch.

---

## Prerequisites

- **Node.js 18+** and **npm**
- **Foundry** -- install via `curl -L https://foundry.paradigm.xyz | bash && foundryup`
- **A Quicknode (or other) Base RPC URL** -- `https://mainnet.base.org` works as a fallback
- **A Supabase project** -- free tier is sufficient
- **A rebalancer wallet** -- a new EOA with ETH on Base for gas (~0.01 ETH covers many rebalances)
- **Basescan API key** -- for contract verification (free at basescan.org/apis)

---

## 1. Smart Contract (UUPS Proxy)

The QuicknodeEarn is deployed behind a **UUPS proxy**. The proxy has a permanent deterministic address via CreateX CREATE3. Upgrades deploy a new implementation contract and call `upgradeToAndCall` on the proxy -- no address changes needed.

**Architecture:**
- **Proxy** (ERC1967Proxy): deterministic address via CreateX CREATE3, never changes
- **Implementation** (QuicknodeEarn): deployed via regular CREATE, can be upgraded
- **Immutables** (`usdc`, `aavePool`, `aUsdc`, `messageTransmitter`): baked into each implementation's bytecode
- **Storage** (owner, vault whitelist, fee shares): lives in the proxy, persists across upgrades

### Required env vars

All deploy/upgrade/verify commands require these in `.env` (or exported in shell):

| Variable | Purpose |
|----------|---------|
| `PRIVATE_KEY` | Deployer/owner wallet private key (must have ETH for gas on target chain) |
| `BASE_RPC_URL` | Base RPC endpoint |
| `MONAD_RPC_URL` | Monad RPC endpoint |
| `ETHERSCAN_API_KEY` | For contract verification (free at basescan.org/apis, works for both chains via Etherscan v2) |

Forge reads `PRIVATE_KEY` from the environment automatically. Source the `.env` file before running:

```bash
source .env
```

### Build

```bash
cd smart-contracts
forge build --no-cache   # --no-cache ensures the artifact reflects latest source changes
```

### First Deployment (proxy + implementation)

Deploys the implementation contract and the deterministic ERC1967 proxy. The proxy calls `initialize(owner, vaults)` in its constructor. If an old contract exists at the `OLD_CONTRACT` address in `Deploy.s.sol`, its vault whitelist is automatically seeded into the new proxy via `initialize()`.

```bash
source .env && cd smart-contracts

# Base
forge script script/Deploy.s.sol \
  --rpc-url "$BASE_RPC_URL" \
  --broadcast \
  --sig "run(uint32)" 8453

# Monad
forge script script/Deploy.s.sol \
  --rpc-url "$MONAD_RPC_URL" \
  --broadcast \
  --sig "run(uint32)" 143
```

**After first deploy only:**

1. Copy the `Proxy:` address from the script output
2. Update `QUICKNODE_EARN_ADDRESS` and `NEXT_PUBLIC_QUICKNODE_EARN_ADDRESS` in `.env`
3. Update `NEXT_PUBLIC_QUICKNODE_EARN_ADDRESS` in Vercel env vars
4. Verify the implementation contract (see below)
5. Run `scripts/add-vaults.ts` if there are new vaults beyond what was seeded from the old contract

### Upgrades (new implementation behind existing proxy)

Deploys a new implementation and calls `upgradeToAndCall` on the existing proxy. Storage (owner, vault whitelist, fee shares) is preserved -- no re-initialization needed.

```bash
source .env && cd smart-contracts

# Base
forge script script/Deploy.s.sol \
  --rpc-url "$BASE_RPC_URL" \
  --broadcast \
  --sig "upgrade(uint32)" 8453

# Monad
forge script script/Deploy.s.sol \
  --rpc-url "$MONAD_RPC_URL" \
  --broadcast \
  --sig "upgrade(uint32)" 143
```

**No address changes needed on upgrade.** The proxy address stays the same. All env vars, Vercel config, Supabase, and frontend references remain unchanged.

**If the upgrade adds new storage variables** that need initialization, use the `reinitializer(N)` pattern in the new implementation:

```solidity
function initializeV2() external reinitializer(2) {
    // set new storage variables
}
```

Then pass the encoded call as the second arg to `upgradeToAndCall` in `Deploy.s.sol`.

### Verify implementation contracts

After each deployment or upgrade, verify the **implementation** contract on the block explorer. The implementation address is logged as `Implementation:` (first deploy) or `New impl:` (upgrade) in the script output.

**Base** -- uses `--chain-id 8453` which Forge resolves to Basescan automatically:

```bash
source .env && cd smart-contracts
forge verify-contract <implementation_address> contracts/QuicknodeEarn.sol:QuicknodeEarn \
  --chain-id 8453 \
  --constructor-args $(cast abi-encode "constructor(address,address,address,address)" \
    0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
    0xA238Dd80C259a72e81d7e4664a9801593F98d1c5 \
    0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB \
    0x81D40F21F12A8F0E3252Bccb954D722d4c464B64) \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --watch
```

**Monad** -- chain 143 is not in Forge's built-in registry, so `--chain-id 143` won't work. Use `--verifier etherscan` with an explicit `--verifier-url` pointing to Etherscan's v2 API. Omit `--chain-id` entirely (Forge infers "mainnet" but the URL routes to Monad):

```bash
source .env && cd smart-contracts
forge verify-contract <implementation_address> contracts/QuicknodeEarn.sol:QuicknodeEarn \
  --constructor-args $(cast abi-encode "constructor(address,address,address,address)" \
    0x754704Bc059F8C67012fEd69BC8A327a5aafb603 \
    0x0000000000000000000000000000000000000000 \
    0x0000000000000000000000000000000000000000 \
    0x0000000000000000000000000000000000000000) \
  --verifier etherscan \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=143" \
  --verifier-api-key "$ETHERSCAN_API_KEY" \
  --watch
```

**Notes:**
- The constructor args match the immutables for each chain (USDC address, Aave Pool, aUSDC, MessageTransmitter). Monad has `address(0)` for Aave and CCTP since they're not deployed there.
- You only verify the **implementation**, not the proxy. The proxy is a standard OZ ERC1967Proxy and block explorers auto-detect it.
- The `--watch` flag polls until verification completes (usually 15-30s).

### Add vaults

Reads `QUICKNODE_EARN_ADDRESS` and `PRIVATE_KEY` from `.env`. Run from the repo root:

```bash
source .env
npx tsx scripts/add-vaults.ts              # Base (8453)
npx tsx scripts/add-vaults.ts --chain 143  # Monad
```

Fetches all Morpho USDC vaults with >=5K TVL from the Morpho API, plus the Aave V3 Pool (Base only), checks which are already whitelisted on-chain, and calls `batchAddVaults` for the missing ones in a single tx. Safe to run repeatedly -- skips already-whitelisted vaults.

**Note:** On first deploy, vaults are automatically seeded from the old contract via `initialize()`. This script is only needed for vaults added after deployment or that weren't in the old contract.

**Ongoing:** Run `add-vaults.ts` whenever new vaults reach the TVL threshold. The rebalancer reverts (not silently skips) on un-whitelisted vaults, so this is an operator responsibility.

### Key design notes

- **Why Forge script, not deploy-v2.ts?** viem's `eth_estimateGas` fails for large initCode through CreateX's CREATE3 proxy. Forge's `--broadcast` bypasses this.
- **Salt version is fixed at `uint96(11)`** for the proxy. Never change it -- the proxy address is permanent.
- **`computeCreate3Address` returns a different address than actual.** Always read from the `Proxy:` log line.
- **Constructor sets immutables only.** Owner and vault whitelist are set via `initialize()` through the proxy.

---

## 2. Supabase

### Create tables

Run the schema from `docs/supabase-schema.sql` in the Supabase SQL editor.

### Enable Web3 auth

1. Dashboard -> **Authentication** -> **Providers**
2. Enable **Web3 Wallet** -> **Ethereum**
3. Add your site URL to **Redirect URLs**: `http://localhost:3000/` (dev) and your production URL

### Get credentials

From Dashboard -> **Project Settings** -> **API**:

- `Project URL` -> `SUPABASE_URL` / `NEXT_PUBLIC_SUPABASE_URL`
- `anon public` key -> `NEXT_PUBLIC_SUPABASE_ANON_KEY`
- `service_role` key (secret) -> `SUPABASE_SERVICE_KEY` (never expose client-side)

---

## 3. Rebalancer

### Configure `.env`

```bash
# Required
BASE_RPC_URL=https://virulent-quick-sound.base-mainnet.quiknode.pro/...
PRIVATE_KEY=0x<bot_wallet_private_key>
EXECUTION_MODE=live

# Contract (proxy address -- permanent, same on all chains)
QUICKNODE_EARN_ADDRESS=0xcc204B4cF3e796dAF4eDCFDeCfACfB1fc61F70d2

# Supabase
SUPABASE_URL=https://<project>.supabase.co
SUPABASE_SERVICE_KEY=eyJhbGc...

# Rebalancer tuning (optional -- these are the defaults)
REBALANCE_MIN_APY_IMPROVEMENT=0.05
MIN_VAULT_TVL=10000000
CONFIRMATION_PINGS=5
```

### Run

```bash
npm start
```

**What to watch for on first run:**

```
[MultiUser] Tick at ... -- 1 active strategy(s)
[VaultDiscovery] No positions found          <- expected on fresh wallet
[PositionManager] Initialized 5 positions with $X each
[MultiUser] -> Initial deposit for 0x...
Step 1: Checking USDC balance...
USDC Balance: $X
[ContractExecutor] Depositing X USDC for 0x... -> 0x<vault>
[ContractExecutor] Deposit tx: 0x...
Transaction: https://basescan.org/tx/0x...
[InitialDeposit] All 5 deposits successful
```

If you see `[ContractExecutor] vault(s) not whitelisted` -- run `scripts/add-vaults.ts` to add the missing vault.

### Simulation mode

To test without spending gas:

```bash
EXECUTION_MODE=simulation npm start
```

Full rebalancing logic runs; no transactions are submitted.

### CLI flags

| Flag          | Overrides            | Example                       |
| ------------- | -------------------- | ----------------------------- |
| `--key <hex>` | `PRIVATE_KEY`        | `npm start -- --key 0xabc...` |
| `--pings <n>` | `CONFIRMATION_PINGS` | `npm start -- --pings 3`      |

---

## 4. Frontend

### Configure `frontend/.env.local`

```bash
# Supabase
NEXT_PUBLIC_SUPABASE_URL=https://<project>.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=eyJhbGc...
SUPABASE_SERVICE_KEY=eyJhbGc...

# Contract (proxy address -- permanent)
NEXT_PUBLIC_QUICKNODE_EARN_ADDRESS=0xcc204B4cF3e796dAF4eDCFDeCfACfB1fc61F70d2

# RPC (public endpoint is fine for reads)
BASE_RPC_URL=https://mainnet.base.org
NEXT_PUBLIC_BASE_RPC_URL=https://mainnet.base.org

# WalletConnect (free at cloud.walletconnect.com)
NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID=<project_id>
```

### Run locally

```bash
npm run dev:frontend
# or: cd frontend && npm run dev
```

Open http://localhost:3000.

### Deploy to Vercel

```bash
cd frontend
npx vercel
```

Set all `frontend/.env.local` variables in Vercel's environment settings. Deploy the `frontend/` subdirectory as the root.

---

## 5. Post-Deploy Checklist

### First deploy

- [ ] `forge build --no-cache` succeeds
- [ ] Implementation + proxy deployed on Base (`forge script ... --sig "run(uint32)" 8453`)
- [ ] Implementation + proxy deployed on Monad (`forge script ... --sig "run(uint32)" 143`)
- [ ] Proxy address is identical on both chains
- [ ] Implementation verified on Basescan (`forge verify-contract ...`)
- [ ] Implementation verified on Monadscan (`forge verify-contract ... --verifier-url ...`)
- [ ] Vault whitelist confirmed on-chain (`cast call <proxy> "getApprovedVaults()"`)
- [ ] Any new vaults added (`scripts/add-vaults.ts`) if needed
- [ ] `.env` updated with proxy address (`QUICKNODE_EARN_ADDRESS`, `NEXT_PUBLIC_QUICKNODE_EARN_ADDRESS`)
- [ ] Implementation addresses added as comments in `.env` for reference
- [ ] Vercel env vars updated with proxy address
- [ ] Supabase schema applied, Web3 auth enabled
- [ ] Rebalancer running in simulation mode -- confirm it finds strategies and ranks vaults
- [ ] Rebalancer switched to live mode -- confirm deposit txs appear on Basescan
- [ ] Frontend deployed -- confirm sign-in flow works end-to-end

### Upgrades

- [ ] `forge build --no-cache` succeeds
- [ ] New implementation deployed + proxy upgraded on Base (`forge script ... --sig "upgrade(uint32)" 8453`)
- [ ] New implementation deployed + proxy upgraded on Monad (`forge script ... --sig "upgrade(uint32)" 143`)
- [ ] New implementation verified on both chains
- [ ] Implementation addresses updated as comments in `.env`
- [ ] Vault whitelist still intact (`cast call <proxy> "getApprovedVaults()"`)
- [ ] Owner unchanged (`cast call <proxy> "owner()"`)
- [ ] No env var or Vercel changes needed

---

## Operator Scripts

All commands assume `source .env` has been run and you are in the repo root (or `smart-contracts/` for forge commands).

| Script / Command | Purpose | When to run |
|------------------|---------|-------------|
| `forge script script/Deploy.s.sol --rpc-url $BASE_RPC_URL --broadcast --sig "run(uint32)" 8453` | First deploy (proxy + impl) on Base | Initial setup only |
| `forge script script/Deploy.s.sol --rpc-url $MONAD_RPC_URL --broadcast --sig "run(uint32)" 143` | First deploy on Monad | Initial setup only |
| `forge script script/Deploy.s.sol --rpc-url $BASE_RPC_URL --broadcast --sig "upgrade(uint32)" 8453` | Upgrade implementation on Base | When contract code changes |
| `forge script script/Deploy.s.sol --rpc-url $MONAD_RPC_URL --broadcast --sig "upgrade(uint32)" 143` | Upgrade implementation on Monad | When contract code changes |
| `forge verify-contract <impl_addr> ...` (see Verify section) | Verify on block explorer | After every deploy/upgrade |
| `npx tsx scripts/add-vaults.ts` | Add new vaults on Base | After deploy; when new vaults exceed TVL |
| `npx tsx scripts/add-vaults.ts --chain 143` | Add new vaults on Monad | After deploy; when new vaults exceed TVL |
| `npx tsx scripts/close-all-strategies.ts [--execute]` | Withdraw all strategies (dry run) | Before major upgrades (optional) |
