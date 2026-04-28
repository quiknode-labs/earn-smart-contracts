# Deployment Guide

Step-by-step instructions to deploy Quicknode Earn from scratch.

---

## Prerequisites

- **Node.js 18+** and **npm**
- **Foundry** — install via `curl -L https://foundry.paradigm.xyz | bash && foundryup`
- **A Quicknode (or other) Base RPC URL** — `https://mainnet.base.org` works as a fallback
- **A Supabase project** — free tier is sufficient
- **A rebalancer wallet** — a new EOA with ETH on Base for gas (~0.01 ETH covers many rebalances)
- **Basescan API key** — for contract verification (free at basescan.org/apis)

---

## 1. Smart Contract

All commands run from the `smart-contract/` directory unless stated otherwise.

### Step 1 — Prepare Deploy.s.sol

Open `script/Deploy.s.sol` and make two edits before every new deployment:

**1a. Bump the salt version.**
The salt encodes the deployer address (first 20 bytes) and a version counter (last 12 bytes). Each deployment must use a unique version — once a CREATE3 proxy is deployed its nonce is consumed and the same salt can never produce a new address.

```solidity
// Change uint96(8) to uint96(9) (or the next unused version)
bytes32 salt = bytes32(abi.encodePacked(deployer, bytes12(uint96(9))));
```

Update the log message too so the output is self-documenting:
```solidity
console.log("Salt (v9): version 9");
```

**1b. Point `OLD_CONTRACT` at the current live contract.**
The deploy script reads the vault whitelist from the old contract and passes it directly into the new contract's constructor, so vaults are live from block 0 with no separate add-vaults step.

```solidity
// Set to the address of the contract being replaced
address constant OLD_CONTRACT = 0xE0dC43CE7a0812Ac333F7f9b768FEB84b85A532d;
```

If there is no previous contract to seed from, set `OLD_CONTRACT` to any address that returns an empty array for `getApprovedVaults()`, or add vaults manually via `scripts/add-vaults.ts` after deploy.

### Step 2 — Build

```bash
forge build --no-cache
```

`--no-cache` is required — without it, Forge may use a stale artifact and deploy code that doesn't match the current source. Confirm the build succeeds with no errors before continuing.

The `foundry.toml` settings that matter for reproducible verification:
```toml
solc          = "0.8.28"
optimizer     = true
optimizer_runs = 200
via_ir        = true
bytecode_hash = "none"   # strips IPFS metadata hash from CBOR; required for Sourcify verification
```

### Step 3 — Deploy via CreateX CREATE3

The contract is deployed through the [CreateX](https://github.com/pcaversaccio/createx) factory (`0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed`), which is deployed at the same address on every EVM chain. This produces a deterministic address controlled by the deployer and the salt version.

```bash
# Load env vars
source ../.env

# Base
forge script script/Deploy.s.sol \
  --rpc-url "$BASE_RPC_URL" \
  --broadcast \
  --sig "run(uint32)" 8453 \
  --private-key "$EXECUTOR_PRIVATE_KEY"

# Monad
forge script script/Deploy.s.sol \
  --rpc-url "$MONAD_RPC_URL" \
  --broadcast \
  --sig "run(uint32)" 143 \
  --private-key "$EXECUTOR_PRIVATE_KEY"
```

**Why `forge script`, not `deploy-v2.ts`?**
`deploy-v2.ts` uses viem's `writeContract`, which calls `eth_estimateGas` before sending. The gas estimate fails for large initCode routed through CreateX's CREATE3 proxy — viem never submits the transaction. Forge's `--broadcast` mode submits directly via `eth_sendRawTransaction`, bypassing the estimate.

**Reading the deployed address.**
`computeCreate3Address()` returns the wrong address — it applies a different internal salt transform than `deployCreate3`. Always read the actual address from the script's console output:

```
== Logs ==
  Chain ID:   8453
  Deployer:   0xd5d6a442890DbC4280EEb7EE92e70f3AD10De1b9
  Salt (v9):  version 9
  Predicted:  0x<wrong — ignore this>
  Seeding vaults: 43
  Deployed:   0x<CORRECT ADDRESS — copy this>
  Owner:      0xd5d6a442890DbC4280EEb7EE92e70f3AD10De1b9
  Vaults:     43
```

Copy the `Deployed:` address. Do not use `Predicted:`.

**What the constructor does.**
The initCode passed to `deployCreate3` includes the contract's creation bytecode followed by ABI-encoded constructor arguments:

```
(address usdc, address messageTransmitter, address owner, address[] initialVaults)
```

`initialVaults` is read live from `OLD_CONTRACT.getApprovedVaults()` at deploy time — the vault whitelist is populated atomically in the same transaction.

### Step 4 — Verify on Basescan

Run the verify script, which reads constructor args from on-chain state and calls `forge verify-contract`:

```bash
cd ..   # back to repo root
npx tsx scripts/verify-contract.ts --address <deployed_address>          # Base
npx tsx scripts/verify-contract.ts --address <deployed_address> --chain 143  # Monad
```

**If the script fails with "bytecode does NOT match"**, Basescan's standard JSON verifier cannot reconcile the immutable variable substitutions in the deployed bytecode. Use Sourcify instead — it handles immutables correctly and syncs to Basescan:

```bash
cd smart-contract
forge verify-contract <deployed_address> \
  contracts/QuicknodeEarn.sol:QuicknodeEarn \
  --chain base \
  --verifier sourcify \
  --watch
```

Sourcify verification has been confirmed to work for this contract. The verified source will appear on Basescan automatically after Sourcify confirms it.

### Step 5 — Update address references

Update every place the contract address is hardcoded or env-configured:

| File | Variable | Action |
|------|----------|--------|
| `src/executor/constants.ts` | `QUICKNODE_EARN_DETERMINISTIC` | Set to new address; update comment with version and date |
| `.env` | `NEXT_PUBLIC_QUICKNODE_EARN_ADDRESS` | Set to new address |
| `frontend/.env.local` | `NEXT_PUBLIC_QUICKNODE_EARN_ADDRESS` | Set to new address |
| Vercel dashboard | `NEXT_PUBLIC_QUICKNODE_EARN_ADDRESS` | Set to new address and redeploy |

### Step 6 — Add any missing vaults (if needed)

Vaults are seeded from the old contract in the constructor, so this step is usually a no-op. Run it to pick up any vaults that were added to the old contract after the last seeding:

```bash
npx tsx scripts/add-vaults.ts           # Base
npx tsx scripts/add-vaults.ts --chain 143  # Monad
```

This script fetches all Morpho USDC vaults with ≥$5K TVL and calls `batchAddVaults`. It is idempotent — already-whitelisted vaults are skipped.

**Ongoing:** Run `add-vaults.ts` whenever new vaults reach TVL threshold. The rebalancer reverts (does not silently skip) on un-whitelisted vaults, so this is a manual operator task.

---

## 1.5 Upgrading an existing UUPS proxy

The production contracts at `0xcc204B4cF3e796dAF4eDCFDeCfACfB1fc61F70d2` are UUPS proxies (same address on every chain). To roll out a new implementation, do **not** use `run(chainId)` — that's for fresh deploys of the legacy non-upgradeable variant. Use `executeUpgrade(chainId)`, which deploys a new impl and calls `upgradeToAndCall` on the existing proxy in a single broadcast. Storage (owner, executor, relayer, approvedVaults, vaultList) is preserved automatically.

**Prerequisites:**

- `PRIVATE_KEY` env var must equal `EXECUTOR_PRIVATE_KEY` — `executeUpgrade` reverts if `deployer != proxy.owner()`.
- Each chain's executor wallet needs ~3.5M gas worth of native token (Ethereum ~0.02 ETH; cheaper elsewhere). Check with `cast balance $EXECUTOR_ADDRESS --rpc-url $X_RPC_URL --ether`.
- `lib/openzeppelin-contracts/` must be at **v5.0.0** (matches `foundry.lock`). See the OZ pin warning below.

**Per-chain rollout** (recommended pattern — used for the 2026-04-27 contract upgrade):

```bash
source .env
export PRIVATE_KEY=$EXECUTOR_PRIVATE_KEY

# 1. Pre-flight baseline on every chain (run once)
PROXY=0xcc204B4cF3e796dAF4eDCFDeCfACfB1fc61F70d2
IMPL_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
for RPC in $OPTIMISM_RPC_URL $BASE_RPC_URL $ARBITRUM_RPC_URL $POLYGON_RPC_URL $ETHEREUM_RPC_URL $UNICHAIN_RPC_URL $MONAD_RPC_URL; do
  cast call    $PROXY 'owner()(address)'    --rpc-url $RPC
  cast call    $PROXY 'executor()(address)' --rpc-url $RPC
  cast call    $PROXY 'relayer()(address)'  --rpc-url $RPC
  cast storage $PROXY $IMPL_SLOT            --rpc-url $RPC
done

# 2. Canary on Optimism
forge script script/Deploy.s.sol --rpc-url "$OPTIMISM_RPC_URL" --broadcast --sig "executeUpgrade(uint32)" 10

# 3. Verify post-upgrade reads (same calls as step 1 but only Optimism). Watch the next executor
#    tick (~5 min) for new errors via service_logs in Supabase.

# 4. Fan out to remaining 6 chains
forge script script/Deploy.s.sol --rpc-url "$BASE_RPC_URL"     --broadcast --sig "executeUpgrade(uint32)" 8453
forge script script/Deploy.s.sol --rpc-url "$ARBITRUM_RPC_URL" --broadcast --sig "executeUpgrade(uint32)" 42161
forge script script/Deploy.s.sol --rpc-url "$POLYGON_RPC_URL"  --broadcast --sig "executeUpgrade(uint32)" 137
forge script script/Deploy.s.sol --rpc-url "$ETHEREUM_RPC_URL" --broadcast --sig "executeUpgrade(uint32)" 1
forge script script/Deploy.s.sol --rpc-url "$UNICHAIN_RPC_URL" --broadcast --sig "executeUpgrade(uint32)" 130
forge script script/Deploy.s.sol --rpc-url "$MONAD_RPC_URL"    --broadcast --sig "executeUpgrade(uint32)" 143

# 5. Verify each new impl on its block explorer (forge verify-contract) — see verification commands
#    in the standalone repo's docs/deployment.md, "Verify implementation contracts" section.

# 6. Update docs/multichain-deployments.md with the new impl addresses.
```

**Monad caveat:** the combined-broadcast `executeUpgrade` may revert on Monad — the impl deploys but the `upgradeToAndCall` reverts. Workaround: capture the impl address from the failed log and run upgrade directly.

```bash
cast send $PROXY 'upgradeToAndCall(address,bytes)' <newImpl> 0x \
  --rpc-url $MONAD_RPC_URL --private-key $PRIVATE_KEY
```

**Rollback:** if a post-upgrade verification fails (e.g. corrupt reads), point the proxy back at the previous impl from the broadcast history:

```bash
cast send $PROXY 'upgradeToAndCall(address,bytes)' <previousImpl> 0x \
  --rpc-url $X_RPC_URL --private-key $PRIVATE_KEY
```

Storage is preserved through both the bad upgrade and the rollback (the corrupt reads are the new impl's misinterpretation of unchanged slots).

### ⚠️ OpenZeppelin version pin — DO NOT BUMP `lib/openzeppelin-contracts/`

`foundry.lock` pins OZ at **v5.0.0**. The originally deployed implementations were compiled against this version, where `ReentrancyGuard._status` lives in regular storage at slot 2. OZ moved that variable to ERC-7201 namespace storage in v5.5.0. Bumping the lib past 5.4.x would compile a new impl whose layout shifts every state variable up one slot — `approvedVaults`, `vaultList`, `executor`, `relayer` all become unreadable on the live proxy.

Symptoms of a layout drift if it slips into prod: post-upgrade `executor()` returns `0x0000…0004`, `vaultList` reads as empty, `relayer()` returns the executor address. (Observed and rolled back on Optimism on 2026-04-27.)

Verify before any deploy:

```bash
cat smart-contract/lib/openzeppelin-contracts/package.json | grep version    # must say "5.0.0"
```

If `forge install` or a fresh clone bumped the lib, restore via:

```bash
cd smart-contract
rm -rf lib/openzeppelin-contracts
forge install OpenZeppelin/openzeppelin-contracts@v5.0.0
```

---

## 2. Supabase

### Create tables

Run the schema from `docs/supabase-schema.sql` in the Supabase SQL editor.

### Enable Web3 auth

1. Dashboard → **Authentication** → **Providers**
2. Enable **Web3 Wallet** → **Ethereum**
3. Add your site URL to **Redirect URLs**: `http://localhost:3000/` (dev) and your production URL

### Get credentials

From Dashboard → **Project Settings** → **API**:

- `Project URL` → `SUPABASE_URL` / `NEXT_PUBLIC_SUPABASE_URL`
- Publishable key (`sb_publishable_...`) → `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`
- Secret key (`sb_secret_...`) → `SUPABASE_SECRET_KEY` (never expose client-side)

---

## 3. Rebalancer

### Configure `.env`

```bash
# Required
BASE_RPC_URL=https://virulent-quick-sound.base-mainnet.quiknode.pro/...
EXECUTOR_PRIVATE_KEY=0x<bot_wallet_private_key>
EXECUTION_MODE=live

# Contract
QUICKNODE_EARN_ADDRESS=0x<deployed_address>

# Supabase
SUPABASE_URL=https://<project>.supabase.co
SUPABASE_SECRET_KEY=sb_secret_...

# Rebalancer tuning (optional — these are the defaults)
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
[MultiUser] Tick at ... — 1 active strategy(s)
[VaultDiscovery] No positions found          ← expected on fresh wallet
[PositionManager] Initialized 5 positions with $X each
[MultiUser] → Initial deposit for 0x...
Step 1: Checking USDC balance...
✓ USDC Balance: $X
[ContractExecutor] Depositing X USDC for 0x... → 0x<vault>
[ContractExecutor] Deposit tx: 0x...
✓ Transaction: https://basescan.org/tx/0x...
[InitialDeposit] ✓ All 5 deposits successful
```

If you see `[ContractExecutor] vault(s) not whitelisted` — run `scripts/add-vaults.ts` to add the missing vault.

### Simulation mode

To test without spending gas:

```bash
EXECUTION_MODE=simulation npm start
```

Full rebalancing logic runs; no transactions are submitted.

### CLI flags

| Flag          | Overrides            | Example                       |
| ------------- | -------------------- | ----------------------------- |
| `--key <hex>` | `EXECUTOR_PRIVATE_KEY` | `npm start -- --key 0xabc...` |
| `--pings <n>` | `CONFIRMATION_PINGS` | `npm start -- --pings 3`      |

---

## 4. Frontend

### Configure `frontend/.env.local`

```bash
# Supabase
NEXT_PUBLIC_SUPABASE_URL=https://<project>.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
SUPABASE_SECRET_KEY=sb_secret_...

# Contract
NEXT_PUBLIC_QUICKNODE_EARN_ADDRESS=0x<deployed_address>

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

- [ ] `Deploy.s.sol` updated: salt version bumped, `OLD_CONTRACT` set to previous address
- [ ] `forge build --no-cache` succeeds with no errors
- [ ] Contract deployed — `Deployed:` address copied from forge script output
- [ ] Contract verified on Basescan (via Sourcify if standard JSON fails)
- [ ] `QUICKNODE_EARN_DETERMINISTIC` updated in `src/executor/constants.ts`
- [ ] `NEXT_PUBLIC_QUICKNODE_EARN_ADDRESS` updated in `.env`, `frontend/.env.local`, and Vercel
- [ ] `scripts/add-vaults.ts` run to pick up any vaults added since last seeding
- [ ] Supabase schema applied, Web3 auth enabled
- [ ] Rebalancer `.env` configured with new contract address and Supabase credentials
- [ ] Rebalancer running in simulation mode — confirm it finds strategies and ranks vaults
- [ ] Rebalancer switched to live mode — confirm deposit txs appear on Basescan
- [ ] Frontend deployed — confirm sign-in flow works end-to-end
- [ ] Test user creates strategy → approves contract → rebalancer picks up on next 60s tick → positions appear on dashboard

---

## Operator Scripts

| Script / Command                                                                  | Purpose                              | When to run                              |
| --------------------------------------------------------------------------------- | ------------------------------------ | ---------------------------------------- |
| `forge script script/Deploy.s.sol --broadcast --sig "run(uint32)" N`             | Deploy legacy non-upgradeable contract via CreateX CREATE3 | New chain bring-up only |
| `forge script script/Deploy.s.sol --broadcast --sig "executeUpgrade(uint32)" N` | Deploy new UUPS impl + upgradeToAndCall on existing proxy | Contract upgrade — see § 1.5 |
| `npx tsx scripts/verify-contract.ts --address <addr> [--chain N]`                | Verify on Basescan (standard JSON)   | After every deployment                   |
| `forge verify-contract <addr> ... --verifier sourcify --watch`                    | Verify via Sourcify (fallback)       | If standard JSON verify fails            |
| `npx tsx scripts/add-vaults.ts [--chain N]`                                       | Add new vaults to whitelist          | After deploy; when new vaults exceed TVL |
| `npx tsx scripts/close-all-strategies.ts [--execute]`                             | Withdraw all strategies (dry run)    | Before deploying a new contract version  |
