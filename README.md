# earn-smart-contracts

Non-custodial yield-optimiser contract that moves user funds between whitelisted Morpho (ERC4626) vaults and the Aave V3 Pool to maximise supply APY.

---

## Overview

- **Non-custodial:** Users grant ERC20 approvals to the contract but never transfer principal in. All vault shares and aTokens are held by the user's wallet.
- **Owner privileges:** A trusted rebalancer EOA (the contract owner) calls privileged functions to deposit, rebalance, and bridge on the user's behalf. The owner cannot withdraw funds to an arbitrary address — all paths route back to the user or an approved vault.
- **User-callable functions:** Users can create strategies via `selfBatchDeposit` and close them via `selfBatchWithdraw` without owner involvement, providing a trustless exit path independent of the rebalancer service.
- **Fee model:** Performance fees are collected as vault shares (not USDC). The executor computes 15% of yield, converts to shares, and passes them as `feeVaults[]`/`feeAmounts[]`. The contract transfers those shares from the user to itself, tracked in `heldFeeShares`. The owner sweeps via `sweep(token, amount)`.

---

## Non-Custodial Model

**Users retain custody at all times.** The flow is:

1. User approves `YieldRebalancer` to spend their USDC (and vault shares/aTokens for withdrawals).
2. The owner (rebalancer service) calls `deposit()` — USDC is pulled from the user and deposited into the chosen vault. Vault shares/aTokens are minted directly to the user.
3. For rebalancing, the owner calls `rebalance()` — shares are pulled from the user, redeemed for USDC, and re-deposited into the new vault on behalf of the user.
4. Users can exit independently via `selfBatchWithdraw()` — no owner approval needed.
5. At no point does the contract accumulate user positions — all shares/aTokens land in the user's wallet.

The `onlyOwner` modifier on privileged functions prevents unauthorised third parties from triggering rebalances. The owner cannot withdraw funds to an arbitrary address — all deposit/rebalance/withdraw functions route funds back to the user or to an approved vault.

---

## Supported Protocols

### Morpho (ERC4626 Vaults)

Each Morpho market is an independent ERC4626 vault with its own address. The contract interacts via the standard `deposit(amount, receiver)` / `redeem(shares, receiver, owner)` interface.

Whitelisted vaults are stored in `vaultList`. Only addresses in this list may receive deposits. The owner maintains the whitelist via `addVault` / `batchAddVaults` / `removeVault`.

### Aave V3 Pool (aTokens)

The Aave V3 Pool is a single contract per chain. Instead of ERC4626, it uses `supply(asset, amount, onBehalfOf, referralCode)` and `withdraw(asset, amount, to)`. The Pool returns rebasing aTokens (1:1 with USDC, accruing interest continuously).

The contract detects the Aave path by comparing the vault address to the immutable `aavePool` address. When `vault == aavePool`, deposit/withdraw routes through `IPool` instead of `IERC4626`. On chains where Aave V3 is not deployed, `aavePool` is set to `address(0)`.

---

## Cross-Chain (CCTP V2)

Circle's Cross-Chain Transfer Protocol (CCTP V2) is integrated for moving USDC between chains:

- **`withdrawAndBridge()`** — Atomically withdraws from a vault, collects performance fees as vault shares, and burns USDC via `ITokenMessengerV2.depositForBurn`. USDC exists in the contract for only a single transaction.
- **`relayAndDeposit()`** — Relays a CCTP attestation (minting USDC to this contract) and immediately deposits into a vault. The balance-delta pattern measures the minted amount rather than trusting the relay return value.

**MEV protection:** Setting `destinationCaller = address(this)` (as bytes32) at burn time on the source chain ensures only this contract can relay on the destination, preventing MEV bots from front-running the mint.

**Low-level call:** `withdrawAndBridge` uses a low-level `call` to the CCTP TokenMessenger instead of a typed interface call because some CCTP deployments are behind upgradeable proxies whose return-value encoding differs from the ABI; a direct interface call would revert on return-data decoding even when the underlying call succeeds.

---

## Function Reference

### Owner-only

| Function | Description |
| --- | --- |
| `deposit(user, vault, usdcAmount)` | Pull USDC from user, deposit into vault |
| `rebalance(user, fromVault, toVault, shares, feeVaults[], feeAmounts[])` | Move position between vaults with optional performance fee collection |
| `withdrawAndBridge(user, vault, shares, feeVaults[], feeAmounts[], tokenMessenger, destDomain, mintRecipient, destinationCaller, maxFee, minFinalityThreshold)` | Atomic withdraw + fee collection + CCTP burn |
| `relayAndDeposit(message, attestation, user, vault)` | Atomic CCTP relay + vault deposit |
| `addVault(vault)` | Add vault to whitelist |
| `batchAddVaults(vaults[])` | Add multiple vaults to whitelist |
| `removeVault(vault)` | Remove vault from whitelist |
| `sweep(token, amount)` | Sweep accumulated fee shares (or any ERC20) to owner |

### User-callable

| Function | Description |
| --- | --- |
| `selfBatchDeposit(vaults[], amounts[])` | Deposit USDC into multiple vaults in one transaction (pulls total USDC in a single transfer) |
| `selfBatchWithdraw(vaults[], shares[], feeAmounts[])` | Close vault positions with optional per-vault fee deduction, USDC returned to caller |

### View

| Function | Description |
| --- | --- |
| `usdc()` | USDC token address (immutable) |
| `aavePool()` | Aave V3 Pool address (immutable, `address(0)` if not on chain) |
| `aUsdc()` | Aave aUSDC token address (immutable, `address(0)` if not on chain) |
| `messageTransmitter()` | CCTP V2 MessageTransmitter address (immutable) |
| `approvedVaults(vault)` | Whether a vault is whitelisted |
| `vaultList(index)` | Vault address by index |
| `heldFeeShares(token)` | Accumulated fee shares for a given token |
| `getApprovedVaults()` | Return full list of whitelisted vaults |
| `isVaultApproved(vault)` | Check if a vault is whitelisted |

---

## Fee Model

The contract uses a **vault-share performance fee** model, not a USDC basis-points model:

1. The off-chain executor computes 15% of yield earned across all strategy vaults.
2. For each vault with accrued yield, the executor converts the fee to vault shares.
3. The executor passes `feeVaults[]` and `feeAmounts[]` arrays to `rebalance`, `selfBatchWithdraw`, or `withdrawAndBridge`.
4. The contract transfers those shares from the user to itself via `safeTransferFrom`.
5. Shares accumulate in `heldFeeShares[vault]` (for Morpho) or `heldFeeShares[aUsdc]` (for Aave).
6. The owner sweeps accumulated shares via `sweep(token, amount)`, which transfers shares to the owner and decrements `heldFeeShares`.

Fee arrays may be empty (no-fee operation) or contain vaults unrelated to the current `fromVault`/`toVault` pair — the executor collects from ALL vaults with accrued yield in a single call to amortise gas. Each fee vault must be whitelisted.

---

## Custom Errors

| Error | Trigger |
| --- | --- |
| `VaultNotApproved(address vault)` | Operation targets a vault not in the whitelist |
| `ZeroAmount()` | Zero-amount argument where a positive value is required |
| `ZeroAddress()` | Zero address where a non-zero address is required |
| `InvalidInput()` | Invalid array length, empty array, `fromVault == toVault`, or `feeAmount >= shares` |
| `ArrayLengthMismatch()` | `feeVaults` and `feeAmounts` arrays have different lengths |
| `CctpBurnFailed()` | Low-level call to CCTP TokenMessenger's `depositForBurn` failed |
| `MessageRelayFailed()` | CCTP `receiveMessage` relay call returned false |

---

## Events

| Event | Emitted by |
| --- | --- |
| `VaultAdded(vault)` | `addVault`, `batchAddVaults`, constructor |
| `VaultRemoved(vault)` | `removeVault` |
| `Deposited(user, vault, usdcAmount, sharesReceived)` | `deposit`, `selfBatchDeposit` |
| `Rebalanced(user, fromVault, toVault, shares, usdcAmount)` | `rebalance` |
| `StrategyCreated(user, totalUsdc)` | `selfBatchDeposit` |
| `StrategyExited(user, vault, shares, usdcReceived)` | `selfBatchWithdraw` |
| `PerformanceFeeCollected(user, vaults[], amounts[])` | `rebalance`, `selfBatchWithdraw`, `withdrawAndBridge` (via `_collectFees`) |
| `FeeSwept(token, recipient, amount)` | `sweep` |
| `BridgeInitiated(user, vault, shares, usdcBurned, destDomain)` | `withdrawAndBridge` |
| `DepositedFromBridge(user, vault, usdcAmount, sharesReceived)` | `relayAndDeposit` |

---

## Security Model

| Mechanism | Purpose |
| --- | --- |
| `Ownable2Step` | Two-step ownership transfer prevents accidental transfer to wrong address |
| `ReentrancyGuard` | All state-changing functions are protected against re-entrant calls |
| `SafeERC20` | Handles non-standard ERC20 tokens (no-return, reverting on failure) |
| Vault whitelist | Only pre-approved vault addresses can receive deposits; fee vaults must also be whitelisted |
| Zero-address guards | Constructor and functions revert on `address(0)` for critical parameters |
| `fromVault != toVault` guard | `rebalance` reverts if source and destination are the same vault |
| User-callable exit (`selfBatchWithdraw`) | Trustless exit path for users independent of the rebalancer service |
| Low-level CCTP call | Avoids proxy return-value ABI mismatch reverts on CCTP TokenMessenger |
| Fee vault whitelist check | `_collectFees` validates each fee vault is whitelisted before transferring shares |

---

## Constructor

```solidity
constructor(
    address _usdc,
    address _aavePool,
    address _aUsdc,
    address _messageTransmitter,
    address _owner,
    address[] memory _initialVaults
)
```

| Parameter | Required | Description |
| --- | --- | --- |
| `_usdc` | Yes | USDC token address. Reverts on `address(0)`. |
| `_aavePool` | No | Aave V3 Pool address. `address(0)` on chains without Aave. |
| `_aUsdc` | No | Aave aUSDC token address. `address(0)` on chains without Aave. |
| `_messageTransmitter` | No | CCTP V2 MessageTransmitter. `address(0)` disables relay. |
| `_owner` | Yes | Initial owner (rebalancer EOA). Reverts on `address(0)`. |
| `_initialVaults` | No | Optional vault whitelist seeded at deploy time. Duplicates and zero addresses are silently skipped. |

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

**Key caveats:**

- **Use `forge script`, not viem's `writeContract`** — viem's `eth_estimateGas` fails for large CreateX initCode. Forge bypasses gas estimation.
- **Use the `Deployed:` log line, not `Predicted:`** — `computeCreate3Address` returns the wrong address. The `Deployed:` log from the Forge script is authoritative.
- **Bump the salt version** — `uint96(N)` in `Deploy.s.sol` for each new deployment. Never reuse a version; once the CreateX proxy is deployed it persists.
- **Verification:** Base uses Sourcify. Monad uses Etherscan V2 API (`--verifier-url "https://api.etherscan.io/v2/api?chainid=143"`).

After deploy, add vaults via the scripts in the main `earn` repo:

```bash
npx tsx scripts/add-vaults.ts
```

---

## Testing

### Forge (unit tests)

```bash
forge install OpenZeppelin/openzeppelin-contracts
forge install foundry-rs/forge-std
forge test
```

### Hardhat (integration tests with viem)

```bash
npm install
npm test
```

The Hardhat test suite (`test/YieldRebalancer.test.ts`) uses a local Hardhat network with mock contracts (`MockERC20`, `MockERC4626`) and covers:

- **Deployment** — constructor args, immutable state, revert on zero USDC/owner, initial vault seeding, duplicate/zero-address skipping
- **Vault Management** — addVault, batchAddVaults, removeVault, idempotent add, events, non-owner revert
- **Deposit** — single-vault deposit, shares in user wallet, revert on non-whitelisted vault / zero amount / zero user / non-owner
- **Rebalance** — vault-to-vault rebalance (no fee), fee share collection during rebalance, revert on `fromVault == toVault` / non-approved vaults / zero shares / zero user / mismatched fee arrays / non-owner
- **selfBatchDeposit** — multi-vault deposit in one tx, revert on non-whitelisted / mismatched arrays / empty arrays / zero amount
- **selfBatchWithdraw** — multi-vault withdrawal (no fees), withdrawal with fee deduction, `shares[i] == 0` full-balance mode, revert on non-whitelisted / mismatched arrays / `fee >= shares` / empty arrays
- **Sweep** — owner sweeps fee shares, partial sweep bookkeeping, revert on zero amount / non-owner
- **View Functions** — `getApprovedVaults`, `isVaultApproved`, `vaultList` enumeration
- **Ownership** — two-step ownership transfer via `transferOwnership` + `acceptOwnership`

---

## Deployed Addresses

| Chain | Address | Version | Deployed |
| --- | --- | --- | --- |
| Base (8453) | [`0x3124F026970C322DdCb017EAa667b7d50A42c5Cc`](https://basescan.org/address/0x3124F026970C322DdCb017EAa667b7d50A42c5Cc) | v10 | 2026-03-26 |
| Monad (143) | `0x3124F026970C322DdCb017EAa667b7d50A42c5Cc` | v10 | 2026-03-26 |

Both chains use the same deterministic address via CreateX CREATE3 (salt version 10).

---

## Audit Notes

### Scope

The primary audit target is `contracts/YieldRebalancer.sol` (~780 lines). The mock contracts (`contracts/mocks/`) and deploy script (`script/Deploy.s.sol`) are out of scope for the security audit but included for test completeness.

### Trust Model Assumptions

1. **Owner is a trusted, operationally secure EOA or multisig.** The owner can call any privileged function on behalf of any user who has granted approval. A compromised owner cannot steal funds (all paths route back to the user or approved vaults), but can grief users by rebalancing into low-yield vaults or collecting excessive fee shares.
2. **Whitelisted vaults are legitimate ERC4626 contracts or the genuine Aave V3 Pool.** A malicious vault in the whitelist could cause `deposit` or `rebalance` to misbehave. The vault whitelist is the primary trust boundary.
3. **Circle's CCTP contracts are trusted.** The `relayAndDeposit` and `withdrawAndBridge` functions interact with Circle-deployed contracts without additional validation.
4. **USDC is a standard ERC20.** The contract uses `SafeERC20` but assumes USDC does not have fee-on-transfer or rebasing behaviour beyond what Aave's aUSDC provides.

### Known Constraints

1. `selfBatchWithdraw` with `shares[i] == 0` reads the user's full on-chain balance. If the user has multiple strategies in the same vault, this will over-withdraw. The off-chain rebalancer always passes explicit share amounts to avoid this.
2. `withdrawAndBridge` uses a low-level call to the CCTP TokenMessenger to avoid proxy return-value decoding issues. The `CctpBurnFailed` error is thrown if the call reverts.
3. Aave fee shares are keyed by `aUsdc` (not `aavePool`) in `heldFeeShares`, since the actual token transferred is aUSDC.
4. `_collectFees` only supports ERC4626 (Morpho) vault shares. Aave fee collection is handled inline within `selfBatchWithdraw`.

---

## Repository Structure

```
contracts/
  YieldRebalancer.sol           Main contract (~780 lines)
  interfaces/
    ICreateX.sol                CreateX factory interface for deterministic deployment
  mocks/
    MockERC20.sol               Mock ERC20 for testing
    MockERC4626.sol             Mock ERC4626 vault for testing
script/
  Deploy.s.sol                  Forge deployment script (CreateX CREATE3)
test/
  YieldRebalancer.test.ts       Hardhat + viem integration tests (~1000 lines)
foundry.toml                    Forge config (solc 0.8.28, optimizer, via-ir)
hardhat.config.cts              Hardhat config (.cts for ESM compatibility)
```
