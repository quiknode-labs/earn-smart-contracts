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
- `rebalance(user, fromVault, toVault, shares, feeVaults, feeAmounts)` — pull a user's shares out of one vault and deposit the resulting USDC into another vault, on behalf of the user. Can also skim fee shares in the same call.
- `withdrawAndBridge(...)` — same as rebalance but instead of depositing into another vault, burns the USDC via Circle's CCTP to bridge it to another chain.

**Cannot do:**
- Move funds to an arbitrary address — `rebalance` always deposits into `toVault` **on behalf of the user** (shares go to the user's wallet). `withdrawAndBridge` accepts only two pairings on-chain: `(mintRecipient = address(this), destinationCaller = address(this))` for the MEV-protected cross-chain rebalance flow, or `(mintRecipient = user, destinationCaller = 0)` for a permissionless cross-chain exit straight to the user's wallet. Anything else reverts.
- Deposit into non-whitelisted vaults — the destination vault (`toVault`) must be on the approved list. Source-side vaults are not checked, so positions can always be exited even if the vault is later delisted.
- Rebalance from a vault to itself — explicitly blocked (`fromVault != toVault`)
- Operate without the user's prior ERC20 approval — the withdraw leg uses `safeTransferFrom` (requires the user to have approved the source vault's share token), and the deposit leg requires the user to have approved the destination vault's share token. Both legs are gated by user consent.

**Risk if compromised:** Could rebalance user funds into a low-yield vault (griefing, not stealing). Could claim excessive fee shares from users (the fee amounts are passed as parameters by the executor, not computed on-chain). Cannot steal principal because all deposit paths route shares back to the user's wallet.

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

### `selfBatchWithdraw(vaults[], shares[], feeAmounts[], burns[])`

- User closes their positions across one or more vaults
- Fee shares are withheld by the contract (performance fee), the rest is redeemed to USDC
- USDC goes directly to the user, OR if `burns[]` is provided, gets bridged back via CCTP
- `shares[i]` is the **explicit gross share amount** to redeem from each vault. Passing 0 reverts (the "0 = full balance" sentinel was removed per OZ audit finding L-06 — leaving it in would have been a max-approval footgun).
- **Requires:** user has pre-approved the contract to spend their vault shares

**Why this matters for security:** These functions give users a **trustless exit**. Even if our backend goes down, the executor key is lost, or we stop operating, any user can call `selfBatchWithdraw` directly and get their money back. No owner/executor involvement needed.

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

1. Our off-chain system computes 15% of yield earned
2. It converts that to a number of vault shares
3. The `feeVaults[]` and `feeAmounts[]` arrays are passed to `rebalance`, `selfBatchWithdraw`, or `withdrawAndBridge`
4. The contract transfers those shares from the user to itself
5. The owner periodically calls `sweep()` to collect accumulated fee shares

**Important nuance:** The fee amounts are computed off-chain and passed as parameters. The contract does not verify that the fee amount is actually 15% of yield — it trusts the caller. For `rebalance`/`withdrawAndBridge`, only the executor can call. For `selfBatchWithdraw`, the user passes fee amounts themselves (our frontend computes them).

---

## Cross-chain bridging (CCTP)

The contract integrates Circle's CCTP V2 for moving USDC between chains. The flow:

1. **Source chain:** USDC is "burned" (sent to Circle's TokenMessenger which destroys it)
2. **Circle attestation:** Circle's off-chain system observes the burn and issues a signed attestation
3. **Destination chain:** The attestation is relayed to Circle's MessageTransmitter, which mints fresh USDC

The contract uses **low-level calls** to the TokenMessenger (not typed interface calls) because some CCTP deployments are behind proxies that return data differently than expected. A typed call would revert even though the burn succeeded.

**MEV protection:** When the executor bridges, it sets `destinationCaller = address(this)` on the destination chain, meaning only our contract can relay the message — preventing bots from front-running.

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
| **`(mintRecipient, destinationCaller)` pairing constraints** | Compromised executor cannot use `withdrawAndBridge` (or any user the `selfBatch*` paths) as a general-purpose CCTP bridge to arbitrary addresses |
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
