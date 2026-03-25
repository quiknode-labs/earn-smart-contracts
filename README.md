# earn-smart-contracts

Smart contracts for the [QuikNode Earn](https://github.com/quiknode-labs/earn) yield-optimisation platform. This repo contains the auditable on-chain layer only — the off-chain rebalancer, frontend, and Supabase infrastructure live in the main `earn` repo.

---

## Overview

`YieldRebalancer` is a non-custodial contract that moves user funds between whitelisted yield-bearing vaults to keep capital in the highest-APY position at all times.

- Users grant an ERC20 approval to the contract. Their principal never leaves their wallet.
- A trusted rebalancer EOA (the contract owner) calls privileged functions to execute deposits, rebalances, and cross-chain bridges on the user's behalf.
- Users can always exit independently via `exitPosition()` — no owner approval needed.
- Fees are capped at 5% per operation and accumulate as USDC in the contract until swept by the owner.

---

## Non-Custodial Model

**Users retain custody at all times.** The flow is:

1. User approves `YieldRebalancer` to spend their USDC (and vault shares/aTokens for withdrawals).
2. The owner (rebalancer service) calls `deposit()` or `batchDeposit()` — USDC is pulled from the user and deposited into the chosen vault. Vault shares/aTokens are minted directly to the user.
3. For rebalancing, the owner calls `rebalance()` — shares are pulled from the user, redeemed for USDC, and re-deposited into the new vault on behalf of the user.
4. At no point does the contract accumulate user positions — all shares/aTokens land in the user's wallet.

The `onlyOwner` modifier on privileged functions prevents unauthorised third parties from triggering rebalances. The owner cannot withdraw funds to an arbitrary address — all deposit/rebalance/withdraw functions route funds back to the user or to an approved vault.

---

## Supported Protocols

### Morpho (ERC4626 Vaults)

Each Morpho market is an independent ERC4626 vault with its own address. The contract interacts via the standard `deposit(amount, receiver)` / `redeem(shares, receiver, owner)` interface.

Whitelisted vaults are stored in `vaultList`. Only addresses in this list may receive deposits. The owner maintains the whitelist via `addVault` / `batchAddVaults` / `removeVault`.

### Aave V3 Pool (aTokens)

The Aave V3 Pool is a single contract per chain. Instead of ERC4626, it uses `supply(asset, amount, onBehalfOf, referralCode)` and `withdraw(asset, amount, to)`. The Pool returns rebasing aTokens (1:1 with USDC, accruing interest continuously).

The contract detects the Aave path by comparing the vault address to the immutable `aavePool` address.

---

## Cross-Chain (CCTP)

Circle's Cross-Chain Transfer Protocol (CCTP V2) is integrated for moving USDC between chains:

- **`withdrawAndBridge()`** — atomically withdraws from a vault and burns USDC via `ITokenMessengerV2.depositForBurn`. USDC exists in the contract for only a single transaction.
- **`relayAndDeposit()`** — relays a CCTP attestation (minting USDC to this contract) and immediately deposits into a vault. The balance-delta pattern measures the minted amount rather than trusting the relay return value.
- **`withdrawForBridge()`** — a two-step variant that withdraws and transfers net USDC to the caller, allowing the burn to happen off-chain.

Setting `destinationCaller = address(this)` (as bytes32) at burn time on the source chain ensures only this contract can relay on the destination, preventing MEV bots from front-running the mint.

---

## Function Reference

### Owner-only

| Function                                              | Description                                        |
| ----------------------------------------------------- | -------------------------------------------------- |
| `deposit(user, vault, usdcAmount)`                    | Pull USDC from user, deposit into vault            |
| `batchDeposit(user, vaults[], amounts[])`             | Multi-vault deposit in one tx (single USDC pull)   |
| `rebalance(user, fromVault, toVault, shares, feeBps)` | Move position between vaults with optional fee     |
| `batchWithdraw(user, vaults[], shares[])`             | Close multiple positions, USDC returned to user    |
| `withdrawForBridge(user, vault, shares, feeBps)`      | Withdraw + transfer USDC to caller for bridging    |
| `withdrawAndBridge(user, vault, shares, feeBps, ...)` | Atomic withdraw + CCTP burn                        |
| `relayAndDeposit(message, attestation, user, vault)`  | Atomic CCTP relay + vault deposit                  |
| `depositFromBridge(user, vault, usdcAmount)`          | Deposit USDC already in contract (post-relay)      |
| `addVault(vault)`                                     | Add vault to whitelist                             |
| `batchAddVaults(vaults[])`                            | Add multiple vaults to whitelist                   |
| `removeVault(vault)`                                  | Remove vault from whitelist                        |
| `sweep(token, to)`                                    | Sweep accumulated fees (or any ERC20) to recipient |
| `setMaxFeeBps(bps)`                                   | Update fee ceiling (max 500)                       |
| `setFeeRecipient(addr)`                               | Update default fee recipient                       |

### User-callable

| Function              | Description                                            |
| --------------------- | ------------------------------------------------------ |
| `exitPosition(vault)` | Exit a single vault position without owner involvement |

### View

| Function                 | Description                            |
| ------------------------ | -------------------------------------- |
| `getApprovedVaults()`    | Return full list of whitelisted vaults |
| `isVaultApproved(vault)` | Check if a vault is whitelisted        |

---

## Fee Model

- Each privileged operation accepts a `feeBps` parameter (basis points, e.g. `5` = 0.05%).
- The fee is deducted from the gross USDC received on withdrawal before re-depositing.
- Fee USDC accumulates in the contract — it is never moved during the operation.
- The owner calls `sweep(usdc, recipient)` to collect accumulated fees.
- Hard ceiling: `maxFeeBps` (set at deploy, adjustable by owner). Absolute maximum: **500 bps (5%)**.
- If `feeBps` exceeds `maxFeeBps`, the transaction reverts with `FeeTooHigh`.

---

## Security Model

| Mechanism                | Purpose                                                                   |
| ------------------------ | ------------------------------------------------------------------------- |
| `Ownable2Step`           | Two-step ownership transfer prevents accidental transfer to wrong address |
| `ReentrancyGuard`        | All state-changing functions are protected against re-entrant calls       |
| `SafeERC20`              | Handles non-standard ERC20 tokens (no-return, reverting on failure)       |
| Vault whitelist          | Only pre-approved vault addresses can receive deposits                    |
| Zero-address guards      | Constructors and setters revert on `address(0)` for critical parameters   |
| Fee ceiling (500 bps)    | Hard-coded max prevents owner from setting an exploitative fee rate       |
| `exitPosition` (no auth) | Trustless exit path for users independent of the rebalancer service       |
| Low-level CCTP call      | Avoids proxy return-value ABI mismatch reverts on CCTP TokenMessenger     |

---

## Deployment

See [`docs/deployment.md`](docs/deployment.md) for the full step-by-step guide.

Quick summary:

```bash
# Install Foundry dependencies
forge install OpenZeppelin/openzeppelin-contracts
forge install foundry-rs/forge-std

# Build
forge build

# Deploy via CreateX CREATE3 (deterministic address)
forge script script/Deploy.s.sol \
  --rpc-url "$BASE_RPC_URL" \
  --broadcast \
  --sig "run(uint32)" 8453 \
  --private-key "$PRIVATE_KEY"
```

**Important:** Use `forge script`, not viem's `writeContract` — viem's `eth_estimateGas` fails for large CreateX initCode. The `Deployed:` log line from the script is the authoritative contract address (`computeCreate3Address` returns the wrong value).

After deploy, add vaults and verify via the scripts in the main `earn` repo:

```bash
npx tsx scripts/add-vaults.ts
npx tsx scripts/verify-contract.ts --address <deployed_address>
```

---

## Testing

### Forge (unit tests)

```bash
# Install dependencies
forge install OpenZeppelin/openzeppelin-contracts
forge install foundry-rs/forge-std

# Run Forge tests
forge test
```

### Hardhat (integration tests with viem)

```bash
npm install
npm test
```

The Hardhat test suite (`test/YieldRebalancer.test.ts`) uses a local Hardhat network with mock contracts (`MockERC20`, `MockERC4626`) and covers:

- Deployment validation (constructor args, revert cases)
- Vault whitelist management
- Single and batch deposits
- Rebalancing with fee calculation
- Fee sweep
- Fee admin (setMaxFeeBps, setFeeRecipient)
- User-initiated exit
- View functions
- Two-step ownership transfer

---

## Deployed Addresses

| Chain       | Address                                                                                                                 |
| ----------- | ----------------------------------------------------------------------------------------------------------------------- |
| Base (8453) | [`0xb54206d393F4DE47450339dCA11db5b586D1621D`](https://basescan.org/address/0xb54206d393F4DE47450339dCA11db5b586D1621D) |
| Monad (143) | `0xb54206d393F4DE47450339dCA11db5b586D1621D`                                                                            |

Both chains use the same deterministic address via CreateX CREATE3 (salt version 5).

---

## Audit Notes

### Scope

The primary audit target is `contracts/YieldRebalancer.sol`. The mock contracts (`contracts/mocks/`) and deploy script (`script/Deploy.s.sol`) are out of scope for the security audit but included for test completeness.

### Trust Model Assumptions

1. **Owner is a trusted, operationally secure EOA or multisig.** The owner can call any privileged function on behalf of any user who has granted approval. A compromised owner cannot steal funds (all paths route back to the user or approved vaults), but can grief users by rebalancing into low-yield vaults or draining fee USDC.
2. **Whitelisted vaults are legitimate ERC4626 contracts or the genuine Aave V3 Pool.** A malicious vault in the whitelist could cause `deposit` or `rebalance` to misbehave. The vault whitelist is the primary trust boundary.
3. **Circle's CCTP contracts are trusted.** The `relayAndDeposit` and `withdrawAndBridge` functions interact with Circle-deployed contracts without additional validation.
4. **USDC is a standard ERC20.** The contract uses `SafeERC20` but assumes USDC does not have fee-on-transfer or rebasing behaviour beyond what Aave's aUSDC provides.

### Known Constraints

- `batchWithdraw` with `shares[i] == 0` reads the user's full on-chain balance. If the user has multiple strategies in the same vault, this will over-withdraw. The off-chain rebalancer always passes explicit share amounts to avoid this.
- The `depositFromBridge` function uses a `require` rather than a custom error for the balance check — this is intentional for clarity and does not affect security.
- `withdrawAndBridge` uses a low-level call to the CCTP TokenMessenger to avoid proxy return-value decoding issues. The `CctpBurnFailed` error is thrown if the call reverts.
