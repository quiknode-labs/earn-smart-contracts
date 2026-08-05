# QuicknodeEarn Contract — Security Overview

> Covers `QuicknodeEarnProxy.sol` (the deployed UUPS implementation behind the proxy at `0x48b415841165304f7EfaA7D5dD5FC65cc7B4bd8e` on every supported chain). `QuicknodeEarn.sol` is a non-upgradeable reference variant kept for audit parity — same interface, no UUPS plumbing.

## What does this contract do?

The contract is a **routing layer** for USDC. It doesn't hold user funds long-term — it acts as a middleman that moves a user's USDC into and out of yield-bearing ERC4626 vaults (Morpho). Think of it like a concierge: the user says "put my money here," and the contract does the paperwork.

The user's money is always sitting in external vaults (Morpho ERC4626) in the form of vault shares, **in the user's own wallet**. The contract itself holds zero user principal at rest.

---

## The three roles

There are three distinct roles, each with hard boundaries on what they can do:

### 1. Owner (multisig)

**What they control:** The "settings" of the contract — which vaults are allowed, who the executor/relayer are, and sweeping accumulated fees.

**Can do:**
- Add/remove vaults from the whitelist (`addVault`, `batchAddVaults`, `removeVault`)
- Assign or revoke the executor and relayer roles (`setExecutor`, `setRelayer`)
- Sweep any token sitting in the contract to themselves (`sweep`) — this is intended for accumulated fee shares

**Risk if compromised:** A compromised owner is the highest-severity scenario. Two drain paths exist:
1. **Two-step drain via `setExecutor`:** The owner installs an attacker-controlled address as the executor (no timelock). The attacker-executor then calls `rebalance` or `withdrawAndBridge` with inflated `feeAmounts[]` (which have no on-chain upper bound), transferring a user's entire vault-share balance to the contract as "fees." The owner then calls `sweep` to extract those shares.
2. **One-step drain via proxy upgrade (QuicknodeEarnProxy only):** A single `upgradeToAndCall` transaction replaces the implementation with one that performs unrestricted `transferFrom` calls against every address with a live approval.

**Mitigation:** Deploy the owner behind a timelocked multisig. A sufficient delay gives users time to monitor for suspicious role changes or upgrades and revoke their approvals before the action executes.

### 2. Executor (EOA, set by owner)

**What they control:** Moving user positions between vaults (rebalancing) and initiating cross-chain bridges.

**Can do:**
- `rebalance(user, fromVault, toVault, shares, feeVaults, feeAmounts, deallocs, maxPenaltyShares)` — pull a user's shares out of one vault and deposit the resulting USDC into another vault, on behalf of the user. Can also skim fee shares in the same call. `deallocs` optionally force-deallocates liquidity from a Morpho Vault V2's adapters first, so an illiquid vault can still be exited.
- `withdrawAndBridge(...)` — same as rebalance but instead of depositing into another vault, burns the USDC via Circle's CCTP to bridge it to another chain. Takes the same `deallocs` / `maxPenaltyShares` pair.

**Cannot do:**
- Move funds to an arbitrary address — `rebalance` always deposits into `toVault` **on behalf of the user** (shares go to the user's wallet). `withdrawAndBridge` accepts only two pairings on-chain: `(mintRecipient = address(this), destinationCaller = address(this))` for the MEV-protected cross-chain rebalance flow, or `(mintRecipient = user, destinationCaller = 0)` for a permissionless cross-chain exit straight to the user's wallet. Anything else reverts.
- Deposit into non-whitelisted vaults — the destination vault (`toVault`) must be on the approved list. Source-side vaults are not checked, so positions can always be exited even if the vault is later delisted.
- Rebalance from a vault to itself — explicitly blocked (`fromVault != toVault`)
- Operate without the user's prior ERC20 approval — the withdraw leg uses `safeTransferFrom` (requires the user to have approved the source vault's share token), and the deposit leg requires the user to have approved the destination vault's share token. Both legs are gated by user consent.

**Risk if compromised:** Could rebalance user funds into a low-yield vault (griefing, not stealing). Could claim excessive fee shares from users (the fee amounts are passed as parameters by the executor, not computed on-chain). Cannot redirect principal to itself, because all deposit paths route shares back to the user's wallet.

One caveat specific to force-deallocation: the penalty Morpho charges is deducted from the position being moved, so a compromised executor could deliberately over-deallocate to burn part of a user's position. The contract bounds this with `MAX_FORCE_DEALLOC_PENALTY_BPS` (3% of the shares moved), which is above Morpho's own 2% protocol ceiling so it never blocks an honest move. Without that bound the only on-chain limit would be the `maxPenaltyShares` argument, which the executor supplies itself in the same call.

### 3. Relayer (EOA, set by owner)

**What they control:** Receiving bridged USDC from another chain and depositing it into vaults.

**Can do:**
- `relayAndDeposit(message, attestation, user, vaults, amounts)` — relay a CCTP message (which causes Circle to mint USDC into the contract), then immediately deposit that USDC into specified vaults on behalf of the user.

**Cannot do:**
- Touch existing user positions — it can only deposit freshly-minted bridge USDC
- Deposit into non-whitelisted vaults
- Keep the minted USDC — it must be deposited into vaults for a specific user

**Risk if compromised:** Could deposit bridged USDC into an undesirable (but still whitelisted) vault. Cannot steal the minted USDC because it must go into whitelisted vaults on behalf of the named user.

---

## What can regular users do? (no role required)

Users have two self-service functions that work without any privileged role:

### `selfBatchDeposit(vaults[], amounts[], burns[])`

- User deposits their USDC into one or more whitelisted vaults in a single transaction
- Optionally burns some USDC via CCTP to bridge it to another chain
- The contract pulls total USDC from the user in one transfer, then distributes
- Vault shares are minted directly to the user's wallet
- **Requires:** user has pre-approved the contract to spend their USDC

### `selfBatchWithdraw(vaults[], shares[], feeAmounts[], burns[], deallocs[][], maxPenaltyShares[])`

- User closes their positions across one or more vaults
- Fee shares are withheld by the contract (performance fee), the rest is redeemed to USDC
- USDC goes directly to the user, OR if `burns[]` is provided, gets bridged back via CCTP
- `shares[i]` is the **explicit gross share amount** to redeem from each vault. Passing 0 reverts (the "0 = full balance" sentinel was removed per OZ audit finding L-06 — leaving it in would have been a max-approval footgun).
- `deallocs[i]` optionally force-deallocates liquidity from a Morpho Vault V2 before redeeming, so the user can exit an illiquid vault without the executor. This is what keeps the exit guarantee below unconditional.
- **Requires:** user has pre-approved the contract to spend their vault shares

### `bridge(amount, fee, service, destDomain, mintRecipient, maxFee, minFinalityThreshold)`

- Standalone wallet-to-wallet USDC bridge over CCTP, unrelated to vaults or strategies
- `service` declares who completes the destination mint: `BRIDGE_SELF_RELAY` (0) means the caller claims it, `BRIDGE_SPONSORED_RELAY` (1) means we relay on their behalf. It is recorded in the `BridgeExecuted` event so an indexer never has to infer the arrangement
- The contract retains `fee` USDC (swept later by the owner) and burns the remainder
- `fee` is computed off-chain and passed in, exactly like the performance fee on the other paths. The contract only enforces `fee < amount`
- `mintRecipient` is an **address**, not a bytes32. CCTP truncates a bytes32 recipient to its low 20 bytes without validating the padding, so accepting bytes32 would let a padded value slip past the check that forbids minting into this contract
- There is no `destinationCaller` parameter: it is always zero, so anyone can relay and the mint always lands in the recipient's wallet. A caller-chosen destination caller would let a user permanently strand their own funds
- `bridgePermit2(...)` is the same function with the USDC pulled by an off-chain Permit2 signature instead of an approval
- **Note:** the same cross-chain move can be made fee-free through `selfBatchDeposit` with an empty vault list. The fee is therefore effectively opt-in

**Why this matters for security:** These functions give users a **trustless exit**. Even if our backend goes down, the executor key is lost, or we stop operating, any user can call `selfBatchWithdraw` directly and get their money back. No owner/executor involvement needed.

**The guarantee does not actually rest on this contract at all.** Vault shares live in the user's own wallet, so the ultimate exit is to call `redeem` directly on the Morpho vault and never touch this contract. For an illiquid Morpho V2 vault the user calls the vault's permissionless `forceDeallocate` first, then redeems. `selfBatchWithdraw` is a convenience that batches those steps and handles the fee and the bridge-back; it is not the thing that makes the exit trustless. Share custody is.

---

## The vault whitelist — the main trust boundary

The single most important security mechanism is the **vault whitelist**. Every function that deposits into a vault checks `approvedVaults[vault]` first. If the vault isn't on the list, the transaction reverts.

- Only the owner can add/remove vaults
- The whitelist prevents the contract from ever sending user funds to an arbitrary address
- This is the primary defense against a compromised executor — even with full executor access, funds can only flow to pre-approved vaults

**What goes on the whitelist:** Legitimate ERC4626 vault addresses (Morpho vaults). If a malicious address were added, it could potentially steal funds routed to it. Vetting the whitelist is critical.

---

## How fees work

Fees are not taken in USDC — they're taken as **vault shares**.

1. Our off-chain system computes the fee (gas-cost-plus: the move's gas cost in USDC times a per-chain multiplier)
2. It converts that to a number of vault shares
3. The `feeVaults[]` and `feeAmounts[]` arrays are passed to `rebalance`, `selfBatchWithdraw`, or `withdrawAndBridge`
4. The contract transfers those shares from the user to itself
5. The owner periodically calls `sweep()` to collect accumulated fee shares

**Important nuance:** The fee amounts are computed off-chain and passed as parameters. The contract does not verify the amount — it trusts the caller. The standalone `bridge()` fee works the same way. For `rebalance`/`withdrawAndBridge`, only the executor can call. For `selfBatchWithdraw`, the user passes fee amounts themselves (our frontend computes them).

---

## Cross-chain bridging (CCTP)

The contract integrates Circle's CCTP V2 for moving USDC between chains. The flow:

1. **Source chain:** USDC is "burned" (sent to Circle's TokenMessenger which destroys it)
2. **Circle attestation:** Circle's off-chain system observes the burn and issues a signed attestation
3. **Destination chain:** The attestation is relayed to Circle's MessageTransmitter, which mints fresh USDC

The contract uses **low-level calls** to the TokenMessenger (not typed interface calls) because some CCTP deployments are behind proxies that return data differently than expected. A typed call would revert even though the burn succeeded.

**MEV protection:** When the executor bridges, it sets `destinationCaller = address(this)` on the destination chain, meaning only our contract can relay the message — preventing bots from front-running. The standalone `bridge()` deliberately does the opposite: it always uses a zero destination caller so anyone can relay, because the mint goes to the recipient's wallet regardless and a wrong destination caller would strand the funds forever.

## Force-deallocation (Morpho Vault V2)

A Morpho Vault V2 usually holds almost no idle USDC: deposits are auto-allocated into lending markets. A plain redeem can therefore fail even though the underlying liquidity exists. Morpho exposes a permissionless `forceDeallocate` that pulls liquidity from a market back into the vault's idle balance and charges a penalty, capped by Morpho at 2%.

How this contract uses it:

- The shares are pulled from the user **first**, then the penalty is charged with `onBehalf = address(this)`. The penalty therefore burns from the shares in motion and never touches the user's wallet balance or their allowance.
- The redeem amount is `shares - penaltyShares`, so the user bears the penalty as a smaller payout, and vault shares held by the contract as fees are not consumed.
- Two caps apply. `maxPenaltyShares` is supplied by the caller and protects the caller against a curator repricing the penalty between simulation and inclusion. `MAX_FORCE_DEALLOC_PENALTY_BPS` is a constant and protects the position holder against the caller.
- Nothing happens when the `deallocs` array is empty, which is the common path.

---

## Protective mechanisms summary

| Mechanism | What it prevents |
|---|---|
| **Vault whitelist** | Funds flowing to unapproved addresses |
| **Role separation (owner/executor/relayer)** | Single compromised key can't do everything |
| **`Ownable2StepUpgradeable`** | Accidental ownership transfer (requires accept step) |
| **`ReentrancyGuardTransient`** (EIP-1153) | Re-entrancy attacks on all state-changing functions, with no persistent storage slot to drift across upgrades |
| **ERC-7201 namespaced storage** | Slot collisions across UUPS upgrades — all mutable state lives at a fixed keccak-derived slot |
| **CCTP hookData binding** | Compromised relayer cannot redirect bridged shares — `relayAndDeposit` verifies the `user` parameter matches the beneficiary committed in the CCTP message at burn time |
| **`emergencyClaimBridge` escape hatch** | Stuck cross-chain deposit if the relayer is down — the burn-time beneficiary can claim minted USDC straight to their wallet |
| **`(mintRecipient, destinationCaller)` pairing constraints** | On `withdrawAndBridge` and the `selfBatch*` paths, restricts CCTP destinations to two exact pairings. Note this does **not** apply to `bridge()` / `bridgePermit2()`, which are deliberately general-purpose wallet-to-wallet bridges for the caller's own funds |
| **`MAX_FORCE_DEALLOC_PENALTY_BPS`** | A compromised executor burning a user's position through oversized force-deallocations |
| **Measured balance deltas on every USDC path** | A misreporting vault causing the contract to spend USDC it did not receive, including fees resting in the contract |
| **`SafeERC20`** | Silent failures on non-standard ERC20 tokens |
| **`fromVault != toVault` check** | Pointless rebalances / potential exploits |
| **Zero-address guards** | Operations with invalid addresses |
| **Balance-delta pattern (relay)** | Not trusting return values from external calls |
| **User-callable exit** | Users can withdraw without any backend involvement |

---

## What the contract does NOT protect against

1. **Compromised owner key** — the owner can reassign the executor without delay and (in the proxy variant) upgrade the implementation. Either path can drain any user with active approvals. See the Owner section above for details. A timelocked multisig is the primary mitigation.
2. **Malicious vault on the whitelist** — if the owner adds a vault that behaves unexpectedly (e.g., steals deposits), the contract has no defense. Vault vetting is an off-chain responsibility.
3. **Executor claiming excessive fees** — fee amounts are passed as parameters, not computed on-chain. A compromised executor could pass inflated fee amounts.
4. **USDC itself** — the contract assumes USDC is a standard ERC20 with no fee-on-transfer or rebasing behavior.
5. **A hostile source vault under-reporting the force-deallocate penalty** — the source vault is deliberately not whitelisted so positions stay exitable after de-listing. A vault that burns more shares than it reports could consume fee shares of that same vault held by the contract. Bounded to that vault's fee inventory.
6. **USDC resting in the contract** — `bridge()` fees accumulate until swept. Every USDC path measures balance deltas so this pool cannot be spent by mistake, but frequent sweeps keep the exposure small.
