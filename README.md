# earn-smart-contracts

Non-custodial yield-optimiser contract that moves user funds between whitelisted ERC4626 vaults (Morpho) to maximise supply APY.

---

## Overview

- **Non-custodial:** Users grant ERC20 approvals to the contract but never transfer principal in. All vault shares are held by the user's wallet.
- **Three-role access control:** Privileged functions are split across three roles:
  - **Owner** (multisig): vault whitelist management, fee sweeps, role assignment
  - **Executor**: rebalancing and cross-chain withdraw+bridge operations (`onlyExecutor`)
  - **Relayer**: CCTP relay+deposit operations (`onlyRelayer`)

  The executor and relayer can only route funds to the user or to approved vaults. However, the owner can reassign these roles without delay via `setExecutor`/`setRelayer`, and (in the proxy variant) can upgrade the implementation via `upgradeToAndCall`. A compromised owner key can therefore drain any user with active approvals. A timelocked multisig is strongly recommended as the owner.
- **User-callable functions:** Users can close strategies via `selfBatchWithdraw` without any privileged-role involvement — a fully trustless exit path. `selfBatchDeposit` is also user-callable; single-chain deposits complete without privileged roles, but cross-chain deposits using the MEV-protected `(this, this)` pairing depend on the relayer to call `relayAndDeposit` on the destination chain. If the relayer is offline, the user can call `emergencyClaimBridge` on the destination chain to consume the CCTP message themselves and have the minted USDC delivered straight to their wallet, bypassing the vault deposit. Users can alternatively burn with the `(msg.sender, 0)` pairing, in which case anyone (including the user) can call `receiveMessage` on the destination chain directly without contract assistance.
- **Fee model:** Performance fees are collected as vault shares (not USDC). The executor computes 15% of yield, converts to shares, and passes them as `feeVaults[]`/`feeAmounts[]`. The contract transfers those shares from the user to itself. The owner sweeps accumulated fee tokens via `sweep(token, amount)`.

---

## Non-Custodial Model

**Users retain custody at all times.** The flow is:

1. User approves `QuicknodeEarn` to spend their USDC (and vault shares for withdrawals).
2. Users create positions via `selfBatchDeposit()` — USDC is pulled from the user and deposited into chosen vaults. Vault shares are minted directly to the user.
3. For rebalancing, the executor calls `rebalance()` — shares are pulled from the user, redeemed for USDC, and re-deposited into the new vault on behalf of the user.
4. Users can exit independently via `selfBatchWithdraw()` — no owner approval needed.
5. At no point does the contract accumulate user positions — all shares land in the user's wallet.

Three modifiers gate privileged functions: `onlyOwner` (vault whitelist, sweeps, role assignment), `onlyExecutor` (rebalance, withdrawAndBridge), and `onlyRelayer` (relayAndDeposit). The executor and relayer can only route funds to the user or to approved vaults. The owner, however, can reassign these roles without delay and (in the proxy variant) upgrade the implementation — meaning a compromised owner can transitively drain any user with active approvals. Deploying the owner behind a timelocked multisig mitigates this by giving users time to revoke approvals.

---

## Supported Protocols

### ERC4626 Vaults (Morpho)

Each Morpho market is an independent ERC4626 vault with its own address. The contract interacts via the standard `deposit(amount, receiver)` / `redeem(shares, receiver, owner)` interface.

Whitelisted vaults are stored in `vaultList`. Only addresses in this list may receive deposits. The owner maintains the whitelist via `addVault` / `batchAddVaults` / `removeVault`.

---

## Cross-Chain (CCTP V2)

Circle's Cross-Chain Transfer Protocol (CCTP V2) is integrated for moving USDC between chains.

### Executor/Relayer-callable

- **`withdrawAndBridge()`** (executor) — Atomically withdraws from a vault, collects performance fees as vault shares, and burns USDC via `ITokenMessengerV2.depositForBurn`. USDC exists in the contract for only a single transaction.
- **`relayAndDeposit(message, attestation, user, vaults[], amounts[])`** (relayer) — Relays a CCTP attestation (minting USDC to this contract) and immediately deposits into the specified vaults. The balance-delta pattern measures the minted amount rather than trusting the relay return value.

### User-callable (self-service burns)

- **`selfBatchDeposit(vaults[], amounts[], burns[])`** — Deposits USDC into local vaults AND optionally burns USDC via CCTP for cross-chain deposits, all in one transaction. Each `BridgeBurn` entry specifies a destination domain, recipient, and amount. The relayer picks up burns and calls `relayAndDeposit` on the destination chain.
- **`selfBatchWithdraw(vaults[], shares[], feeAmounts[], burns[])`** — Closes vault positions AND optionally burns redeemed USDC via CCTP to bridge back to the user's source chain. When `burns` is non-empty, redeemed USDC is accumulated in the contract and burned. Pass `type(uint256).max` as `burns[i].amount` to burn all redeemed USDC after fees (recommended for close flows). Any remainder after burns is transferred to `msg.sender`. For withdrawal burns, `destinationCaller` is typically `bytes32(0)` (permissionless relay), allowing Circle's auto-relay service to handle the relay within ~1 minute at no gas cost.

### Finality thresholds

The `minFinalityThreshold` parameter in `BridgeBurn` controls how quickly Circle issues the attestation:
- **`0`** — Fast finality: attestation issued after minimal block confirmations (~8-20 seconds depending on chain).
- **`2000`** — Standard finality: attestation issued after full chain finality (~13-15 minutes on Ethereum, varies by chain).

### Executor cross-chain flows

`withdrawAndBridge` accepts two `(mintRecipient, destinationCaller)` pairings, each corresponding to a distinct flow:

**1. Cross-chain rebalance — `(this, this)`:** moves a user's position to a vault on another chain.

1. **Chain A:** Executor calls `withdrawAndBridge(...)` with both `mintRecipient` and `destinationCaller` set to `bytes32(uint256(uint160(address(this))))` — the contract's own address on the destination chain. The user's vault shares are redeemed to USDC and burned via CCTP.
2. **Chain B:** The relayer calls `relayAndDeposit(message, attestation, user, vaults[], amounts[])`. The contract relays the CCTP message (minting USDC to itself), then deposits into the target vaults on behalf of the user. Only this contract can relay because it is the `destinationCaller` — MEV protection.

**2. Cross-chain exit — `(user, 0)`:** delivers the user's USDC straight to their wallet on the destination chain, no contract interaction required on the destination side.

1. **Chain A:** Executor calls `withdrawAndBridge(...)` with `mintRecipient = bytes32(uint256(uint160(user)))` and `destinationCaller = bytes32(0)`. Vault shares are redeemed and burned via CCTP.
2. **Chain B:** Anyone (the user, Circle's auto-relay, or any third party) can call `IMessageTransmitter.receiveMessage` directly to mint USDC to the user's wallet. No vault deposit happens.

Both pairings rely on **CREATE3 address parity**: the contract is deployed at the same deterministic address (`0xcc204B4cF3e796dAF4eDCFDeCfACfB1fc61F70d2`) on every chain via CreateX CREATE3. Setting `mintRecipient = destinationCaller = address(this)` works because `address(this)` is identical on both chains. If this parity broke, the destination contract could not relay the message or receive the minted USDC.

### Design notes

**MEV protection:** Setting `destinationCaller = address(this)` (as bytes32) at burn time on the source chain ensures only this contract can relay on the destination, preventing MEV bots from front-running the mint. For withdrawal burns (bridge-back on close), `destinationCaller = bytes32(0)` is used instead, allowing permissionless relay — this enables Circle's auto-relay service to handle the relay automatically.

**Low-level call:** All CCTP burn calls use a low-level `call` to the TokenMessenger instead of a typed interface call because some CCTP deployments are behind upgradeable proxies whose return-value encoding differs from the ABI; a direct interface call would revert on return-data decoding even when the underlying call succeeds.

---

## Function Reference

### Owner-only (`onlyOwner`)

| Function | Description |
| --- | --- |
| `addVault(vault)` | Add vault to whitelist |
| `batchAddVaults(vaults[])` | Add multiple vaults to whitelist |
| `removeVault(vault)` | Remove vault from whitelist |
| `sweep(token, amount)` | Sweep accumulated fee shares or any ERC20 to owner |
| `setExecutor(executor)` | Assign or change the executor address |
| `setRelayer(relayer)` | Assign or change the relayer address |

### Executor-only (`onlyExecutor`)

| Function | Description |
| --- | --- |
| `rebalance(user, fromVault, toVault, shares, feeVaults[], feeAmounts[])` | Move position between vaults with optional performance fee collection |
| `withdrawAndBridge(user, vault, shares, feeVaults[], feeAmounts[], destDomain, mintRecipient, destinationCaller, maxFee, minFinalityThreshold)` | Atomic withdraw + fee collection + CCTP burn |

### Relayer-only (`onlyRelayer`)

| Function | Description |
| --- | --- |
| `relayAndDeposit(message, attestation, user, vaults[], amounts[])` | Atomic CCTP relay + multi-vault deposit |

### User-callable (no restriction)

| Function | Description |
| --- | --- |
| `selfBatchDeposit(vaults[], amounts[], burns[])` | Deposit USDC into local vaults + optionally burn via CCTP for cross-chain deposits |
| `selfBatchWithdraw(vaults[], shares[], feeAmounts[], burns[])` | Close vault positions with per-vault fee deduction + optionally burn via CCTP to bridge back to source chain |

### View

| Function | Description |
| --- | --- |
| `usdc()` | USDC token address (immutable) |
| `messageTransmitter()` | CCTP V2 MessageTransmitter address (immutable) |
| `tokenMessenger()` | CCTP V2 TokenMessenger address (immutable, `address(0)` if disabled) |
| `executor()` | Current executor address |
| `relayer()` | Current relayer address |
| `approvedVaults(vault)` | Whether a vault is whitelisted |
| `vaultList(index)` | Vault address by index |
| `getApprovedVaults()` | Return full list of whitelisted vaults |
| `isVaultApproved(vault)` | Check if a vault is whitelisted |

---

## Fee Model

The contract uses a **vault-share performance fee** model, not a USDC basis-points model:

1. The off-chain executor computes 15% of yield earned across all strategy vaults.
2. For each vault with accrued yield, the executor converts the fee to vault shares.
3. The executor passes `feeVaults[]` and `feeAmounts[]` arrays to `rebalance`, `selfBatchWithdraw`, or `withdrawAndBridge`.
4. The contract transfers those shares from the user to itself via `safeTransferFrom`.
5. The owner sweeps accumulated fee tokens via `sweep(token, amount)`.

Fee arrays may be empty (no-fee operation) or contain vaults unrelated to the current `fromVault`/`toVault` pair — the executor collects from ALL vaults with accrued yield in a single call to amortise gas. Each fee vault must be whitelisted.

---

## Custom Errors

| Error | Trigger |
| --- | --- |
| `UnauthorizedExecutor()` | Non-executor address calls an executor-only function |
| `UnauthorizedRelayer()` | Non-relayer address calls a relayer-only function |
| `VaultNotApproved(address vault)` | Operation targets a vault not in the whitelist |
| `ZeroAmount()` | Zero-amount argument where a positive value is required |
| `ZeroAddress()` | Zero address where a non-zero address is required |
| `InvalidInput()` | Invalid array length, empty array, or `feeAmount >= shares` |
| `ArrayLengthMismatch()` | `feeVaults` and `feeAmounts` arrays have different lengths |
| `CctpBurnFailed()` | Low-level call to CCTP TokenMessenger's `depositForBurn` failed |
| `MessageRelayFailed()` | CCTP `receiveMessage` relay call returned false |

---

## Events

| Event | Emitted by |
| --- | --- |
| `ExecutorUpdated(oldExecutor, newExecutor)` | `setExecutor` |
| `RelayerUpdated(oldRelayer, newRelayer)` | `setRelayer` |
| `VaultAdded(vault)` | `addVault`, `batchAddVaults`, constructor |
| `VaultRemoved(vault)` | `removeVault` |
| `Deposited(user, vault, usdcAmount, sharesReceived)` | `selfBatchDeposit` |
| `Rebalanced(user, fromVault, toVault, shares, usdcAmount)` | `rebalance` |
| `StrategyCreated(user, totalUsdc)` | `selfBatchDeposit` |
| `StrategyExited(user, vault, shares, usdcReceived)` | `selfBatchWithdraw` |
| `PerformanceFeeCollected(user, vaults[], amounts[])` | `rebalance`, `selfBatchWithdraw`, `withdrawAndBridge` (via `_collectFees`) |
| `FeeSwept(token, recipient, amount)` | `sweep` |
| `BridgeInitiated(user, vault, shares, usdcBurned, destDomain)` | `withdrawAndBridge` |
| `BridgeBurnInitiated(user, amount, destDomain, mintRecipient)` | `selfBatchDeposit`, `selfBatchWithdraw` (CCTP burns) |
| `DepositedFromBridge(user, vault, usdcAmount, sharesReceived)` | `relayAndDeposit` |

---

## Security Model

| Mechanism | Purpose |
| --- | --- |
| `Ownable2Step` + role separation | Two-step ownership transfer; executor and relayer roles assigned by owner via `setExecutor`/`setRelayer` |
| `ReentrancyGuard` | All state-changing functions are protected against re-entrant calls |
| `SafeERC20` | Handles non-standard ERC20 tokens (no-return, reverting on failure) |
| Vault whitelist | Only pre-approved vault addresses can receive deposits; fee vaults must also be whitelisted |
| Zero-address guards | Constructor and functions revert on `address(0)` for critical parameters |
| User-callable exit (`selfBatchWithdraw`) | Trustless exit path for users independent of the rebalancer service |
| Low-level CCTP call | Avoids proxy return-value ABI mismatch reverts on CCTP TokenMessenger |
| Fee vault whitelist check | `_collectFees` validates each fee vault is whitelisted before transferring shares |

---

## Constructor

The contract is deployed directly (not behind a proxy). All immutables and initial state are set in the constructor.

```solidity
constructor(
    address _usdc,
    address _messageTransmitter,
    address _tokenMessenger,
    address _owner,
    address[] memory _initialVaults
) Ownable(_owner)
```

| Parameter | Required | Description |
| --- | --- | --- |
| `_usdc` | Yes | USDC token address. Reverts on `address(0)`. |
| `_messageTransmitter` | No | CCTP V2 MessageTransmitter. `address(0)` disables relay. |
| `_tokenMessenger` | No | CCTP V2 TokenMessenger. `address(0)` disables CCTP burns. |
| `_owner` | Yes | Initial owner (multisig). Reverts on `address(0)`. |
| `_initialVaults` | No | Optional vault whitelist seeded at deploy time. Duplicates and zero addresses are silently skipped. |

---

## Deployment

See [`docs/deployment.md`](docs/deployment.md) for the full step-by-step guide and [`docs/contract-verification.md`](docs/contract-verification.md) for source verification via the Etherscan V2 API.

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
  --sig "runWithVaults(uint32,address[])" 8453 "[0x...]" \
  --private-key "$PRIVATE_KEY"
```

**Key caveats:**

- **Use `forge script`, not viem's `writeContract`** — viem's `eth_estimateGas` fails for large CreateX initCode. Forge bypasses gas estimation.
- **Use the `Deployed:` log line, not `Predicted:`** — `computeCreate3Address` returns the wrong address. The `Deployed:` log from the Forge script is authoritative.
- **Bump the salt version** — `uint96(N)` in `Deploy.s.sol` for each new deployment. Never reuse a version; once the CreateX proxy is deployed it persists.
- **Verification:** Use the Etherscan V2 API for all chains (see [`docs/contract-verification.md`](docs/contract-verification.md)).

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

The Hardhat test suite (`test/QuicknodeEarn.test.ts`) uses a local Hardhat network with mock contracts (`MockERC20`, `MockERC4626`) and covers:

- **Deployment** — constructor args, immutable state, revert on zero USDC/owner, initial vault seeding, duplicate/zero-address skipping
- **Vault Management** — addVault, batchAddVaults, removeVault, idempotent add, events, non-owner revert
- **Role Management** — setExecutor, setRelayer, non-owner revert, defaults to zero address
- **Rebalance** — vault-to-vault rebalance (no fee), fee share collection during rebalance, revert on non-approved vaults / non-executor
- **selfBatchDeposit** — multi-vault deposit in one tx, revert on non-whitelisted / mismatched arrays / empty arrays / zero amount
- **selfBatchWithdraw** — multi-vault withdrawal (no fees), withdrawal with fee deduction, revert on `shares[i] == 0` / non-whitelisted / mismatched arrays / `fee >= shares` / empty arrays
- **Sweep** — owner sweeps fee shares, revert on zero amount / non-owner
- **View Functions** — `getApprovedVaults`, `isVaultApproved`, `vaultList` enumeration
- **Ownership** — two-step ownership transfer via `transferOwnership` + `acceptOwnership`

---

## Deployed Addresses

**Deterministic address (same on all chains):** `0xcc204B4cF3e796dAF4eDCFDeCfACfB1fc61F70d2`

| Chain | Address | Vaults |
| --- | --- | ---: |
| Ethereum (1) | [`0xcc204B…d2`](https://etherscan.io/address/0xcc204B4cF3e796dAF4eDCFDeCfACfB1fc61F70d2) | 54 |
| Optimism (10) | [`0xcc204B…d2`](https://optimistic.etherscan.io/address/0xcc204B4cF3e796dAF4eDCFDeCfACfB1fc61F70d2) | 4 |
| Unichain (130) | [`0xcc204B…d2`](https://uniscan.xyz/address/0xcc204B4cF3e796dAF4eDCFDeCfACfB1fc61F70d2) | 1 |
| Polygon (137) | [`0xcc204B…d2`](https://polygonscan.com/address/0xcc204B4cF3e796dAF4eDCFDeCfACfB1fc61F70d2) | 3 |
| Monad (143) | [`0xcc204B…d2`](https://monadscan.com/address/0xcc204B4cF3e796dAF4eDCFDeCfACfB1fc61F70d2) | 3 |
| Base (8453) | [`0xcc204B…d2`](https://basescan.org/address/0xcc204B4cF3e796dAF4eDCFDeCfACfB1fc61F70d2) | 43 |
| Arbitrum (42161) | [`0xcc204B…d2`](https://arbiscan.io/address/0xcc204B4cF3e796dAF4eDCFDeCfACfB1fc61F70d2) | 12 |

The address is deterministic via CreateX CREATE3 (salt version 11).

---

## Audit Notes

### Scope

The primary audit targets are `contracts/QuicknodeEarn.sol` (~846 lines) and `contracts/QuicknodeEarnProxy.sol` (~870 lines, UUPS proxy variant with identical business logic). Mock contracts (`contracts/mocks/`) and the deploy script (`script/Deploy.s.sol`) are out of scope for the security audit but included for test completeness.

### Trust Model Assumptions

1. **Owner is a trusted multisig; executor and relayer are trusted EOAs.** The owner manages the vault whitelist, sweeps fees, and assigns roles. The executor can rebalance and bridge on behalf of users who have granted approval. The relayer can relay CCTP attestations and deposit into vaults. A compromised executor cannot steal funds (all paths route back to the user or approved vaults), but can grief users by rebalancing into low-yield vaults or collecting excessive fee shares. A compromised relayer can only deposit bridged USDC into whitelisted vaults. **A compromised owner is the highest-severity scenario:** the owner can install an attacker-controlled executor via `setExecutor` (no timelock), then abuse `_collectFees` with unbounded `feeAmounts[]` to transfer a user's entire vault-share balance to the contract, and finally `sweep` those shares. In the proxy variant, a single `upgradeToAndCall` can replace the implementation entirely. A timelocked multisig as owner is strongly recommended to give users time to revoke approvals.
2. **Whitelisted vaults are legitimate ERC4626 contracts.** A malicious vault in the whitelist could cause `deposit` or `rebalance` to misbehave. The vault whitelist is the primary trust boundary.
3. **Circle's CCTP contracts are trusted.** The `relayAndDeposit` and `withdrawAndBridge` functions interact with Circle-deployed contracts without additional validation.
4. **USDC is a standard ERC20.** The contract uses `SafeERC20` but assumes USDC does not have fee-on-transfer or rebasing behaviour.

### Known Constraints

1. `selfBatchWithdraw` requires explicit gross share amounts; `shares[i] == 0` reverts with `ZeroAmount()` (the prior full-balance sentinel was removed in the L-06 audit fix to close the max-approval footgun).
2. `withdrawAndBridge` uses a low-level call to the CCTP TokenMessenger to avoid proxy return-value decoding issues. The `CctpBurnFailed` error is thrown if the call reverts.
3. `_collectFees` supports ERC4626 vault shares only.

---

## Repository Structure

```
contracts/
  QuicknodeEarn.sol             Main contract (~846 lines, non-proxy)
  QuicknodeEarnProxy.sol        UUPS proxy variant (~870 lines, identical business logic)
  interfaces/
    ICreateX.sol                CreateX factory interface for deterministic deployment
  mocks/
    ERC1967ProxyImport.sol      Re-export of OpenZeppelin ERC1967Proxy for Hardhat compilation
    MockERC20.sol               Mock ERC20 (6 decimals) for testing
    MockERC4626.sol             Mock ERC4626 vault for testing
script/
  Deploy.s.sol                  Forge deployment script (CreateX CREATE3)
test/
  QuicknodeEarn.test.ts         Hardhat + viem integration tests
docs/
  deployment.md                 Full deployment guide
  contract-verification.md      Source verification via Etherscan V2 API
  laymans.md                    Plain-English security overview
foundry.toml                    Forge config (solc 0.8.28, optimizer 200 runs, via-ir)
hardhat.config.cts              Hardhat config (.cts for ESM compatibility)
```
