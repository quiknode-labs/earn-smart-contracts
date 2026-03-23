# Deployment Guide

Step-by-step instructions to deploy Yield Rebalancer from scratch.

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

### Build

```bash
forge build --no-cache   # --no-cache ensures the artifact reflects latest source changes
```

Verify: `out/YieldRebalancer.sol/YieldRebalancer.json` exists and the `batchWithdraw` ABI entry has 3 inputs (`user`, `vaults`, `shares`).

### Deploy (CreateX CREATE3 — deterministic address)

The contract is deployed via [CreateX](https://github.com/pcaversaccio/createx) so the same address is produced on every chain. The salt encodes the deployer address (first 20 bytes) and a version counter (last 12 bytes).

```bash
# Set PRIVATE_KEY, BASE_RPC_URL, MONAD_RPC_URL in .env

# Base
forge script script/Deploy.s.sol \
  --rpc-url "$BASE_RPC_URL" \
  --broadcast \
  --sig "run(uint32)" 8453 \
  --private-key "$PRIVATE_KEY"

# Monad
forge script script/Deploy.s.sol \
  --rpc-url "$MONAD_RPC_URL" \
  --broadcast \
  --sig "run(uint32)" 143 \
  --private-key "$PRIVATE_KEY"
```

**Why Forge script, not deploy-v2.ts?**
`deploy-v2.ts` uses viem's `writeContract`, which calls `eth_estimateGas` before submitting. The gas estimate fails for large initCode through CreateX's CREATE3 proxy, so viem never submits the tx. Forge's `script --broadcast` bypasses this by using the RPC's `eth_sendRawTransaction` directly.

**Critical: `computeCreate3Address` returns the wrong address.**
The actual deployed address is determined by the CREATE3 proxy's nonce, not by CreateX's `computeCreate3Address` view function (which applies a different salt transform). Always read the actual address from:
- The `ContractCreation(address indexed newContract)` log in the deployment tx, OR
- `cast compute-address --nonce 1 <proxy_address>` where `proxy_address` is the intermediate CREATE2 address

The script logs `Deployed: <addr>` — that is the correct address.

**After deploy:**
1. Update `YIELD_REBALANCER_DETERMINISTIC` in `src/executor/constants.ts`
2. Update `NEXT_PUBLIC_YIELD_REBALANCER_ADDRESS` in Vercel env vars
3. Verify and add vaults for each chain (next section)

**Bumping the salt version** (required when re-deploying to new address):
Edit `script/Deploy.s.sol` — change `uint96(3)` to `uint96(4)` (or next unused version):
```solidity
bytes32 salt = bytes32(abi.encodePacked(deployer, bytes12(uint96(4))));
```
**Never reuse a version** — the proxy at the old CREATE2 address persists on-chain with nonce > 0, making the same-version salt unusable.

### Verify and add vaults

After each successful deployment, verify the contract and populate the vault whitelist immediately. Run both steps per chain before moving on.

```bash
# Base — verify, then add vaults
npx tsx scripts/verify-contract.ts --address <deployed_address>
npx tsx scripts/add-vaults.ts

# Monad — verify, then add vaults
npx tsx scripts/verify-contract.ts --address <deployed_address> --chain 143
npx tsx scripts/add-vaults.ts --chain 143
```

**Verify:** reads constructor args directly from on-chain state (owner, usdc, vaults, etc.), ABI-encodes them, and calls `forge verify-contract`. Requires `BASESCAN_API_KEY` in `.env` (works for both chains via Etherscan v2 API).

**Add vaults:** fetches all Morpho USDC vaults with ≥$5K TVL from the API, plus the Aave V3 Pool (Base only), and calls `batchAddVaults` in one tx. Safe to run repeatedly — skips already-whitelisted vaults.

**Ongoing:** Run `add-vaults.ts` whenever new vaults reach TVL threshold. The rebalancer throws (not silently skips) on un-whitelisted vaults, so this is a human-only operator task.

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
- `anon public` key → `NEXT_PUBLIC_SUPABASE_ANON_KEY`
- `service_role` key (secret) → `SUPABASE_SERVICE_KEY` (never expose client-side)

---

## 3. Rebalancer

### Configure `.env`

```bash
# Required
BASE_RPC_URL=https://virulent-quick-sound.base-mainnet.quiknode.pro/...
PRIVATE_KEY=0x<bot_wallet_private_key>
EXECUTION_MODE=live

# Contract
YIELD_REBALANCER_ADDRESS=0x<deployed_address>

# Supabase
SUPABASE_URL=https://<project>.supabase.co
SUPABASE_SERVICE_KEY=eyJhbGc...

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

# Contract
NEXT_PUBLIC_YIELD_REBALANCER_ADDRESS=0x<deployed_address>

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

- [ ] Contract deployed and verified on Basescan
- [ ] Vault whitelist populated (`scripts/add-vaults.ts`)
- [ ] Supabase schema applied, Web3 auth enabled
- [ ] Rebalancer `.env` configured with contract address and Supabase credentials
- [ ] Rebalancer running in simulation mode — confirm it finds strategies and ranks vaults
- [ ] Rebalancer switched to live mode — confirm deposit txs appear on Basescan
- [ ] Frontend deployed — confirm sign-in flow works end-to-end
- [ ] Test user creates strategy → approves contract → rebalancer picks up on next 60s tick → positions appear on dashboard

---

## Operator Scripts

| Script / Command                                                     | Purpose                       | When to run                              |
| -------------------------------------------------------------------- | ----------------------------- | ---------------------------------------- |
| `forge script script/Deploy.s.sol --broadcast --sig "run(uint32)" N` | Deploy contract via CreateX   | Initial setup or contract upgrade        |
| `npx tsx scripts/verify-contract.ts --address <addr> [--chain N]`    | Verify on Basescan/Monadscan  | After every deployment                   |
| `npx tsx scripts/add-vaults.ts [--chain N]`                          | Add new vaults to whitelist   | After deploy; when new vaults exceed TVL |
| `npx tsx scripts/close-all-strategies.ts [--execute]`                | Withdraw all strategies (dry) | Before deploying a new contract version  |
