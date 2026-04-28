# OpenZeppelin Audit — Questions & Revisions

Responses to the OpenZeppelin smart contract review of `QuicknodeEarnProxy.sol`.

---

## #1: Self-rebalance not blocked

**Finding:** `rebalance()` does not check `fromVault == toVault`. A compromised executor can repeatedly self-rebalance a user while collecting fees each time, draining their position without moving any capital.

**Our Response:** Acknowledged. We'll add a `if (fromVault == toVault) revert` check to `rebalance()`. Though to your point, the same logic could just alternate between two approved vaults even with that check.

**OZ Follow-up:** That's okay — it's more about being aligned with the documentation and preventing a no-op for the user while at the same time possibly consuming a fee.

**Implementation:**

```solidity
error SameVault();

// Add to rebalance(), after vault approval checks
if (fromVault == toVault) revert SameVault();
```

---

## #2: `withdrawAndBridge` mintRecipient unconstrained

**Finding:** A compromised executor can steal user principal via `withdrawAndBridge`. The `mintRecipient` parameter is fully executor-controlled with no on-chain constraint, allowing the executor to burn a user's redeemed USDC to an attacker-controlled address on any chain.

**Our Response:** Since our contracts are deployed deterministically, we can enforce `mintRecipient == bytes32(uint256(uint160(address(this))))`. This guarantees bridged USDC can at worst only land in the QuicknodeEarn contract on the destination chain.

**OZ Follow-up:** Sending the USDC to the Earn contract on the other chain is wrong — it would need to be swept by the owner. Suggested instead: `if (mintRecipient != bytes32(uint256(uint160(user)))) revert InvalidInput();`

**Status:** Needs revision. OZ's point is valid — constraining to `user` instead of `address(this)` is cleaner and avoids the sweep problem. Need to evaluate impact on the relay+deposit flow since the relayer currently expects USDC to land in the contract.

**Implementation (revised per OZ feedback):**

```solidity
error InvalidMintRecipient();

// Add to withdrawAndBridge(), before the CCTP burn
if (mintRecipient != bytes32(uint256(uint160(user)))) revert InvalidMintRecipient();
```

---

## #3: `relayAndDeposit` user param unconstrained

**Finding:** The relayer controls which address receives vault shares in `relayAndDeposit`. The `user` parameter is never validated against the CCTP message — a compromised relayer can redirect a user's bridged deposit to any address.

**Our Response:** Acknowledged. The CCTP message doesn't encode the intended beneficiary, so there's no on-chain source of truth to validate against. We'll update our documentation here.

**OZ Follow-up:** The intended recipient of the shares could be encoded in `hookData` using `depositForBurnWithHook`. Then decode the CCTP message on the destination chain to extract the `hookData` and verify the target matches the user making the deposit.

**Resolution:** We'll adopt the `hookData` approach. On the source chain, all CCTP burns will use `depositForBurnWithHook` with `hookData = abi.encode(user)`. On the destination chain, `relayAndDeposit` will parse the `hookData` from the signed CCTP message and verify that the `user` parameter matches the encoded address. The user identity is cryptographically committed in the CCTP message at burn time — immutable and tamper-proof. The relayer can still choose vaults and amounts, but cannot redirect shares to a different user.

Note: `hookData` is opaque metadata carried in the CCTP message. The protocol does not execute it — our contract parses it from the raw message bytes. The hookData lives at byte offset 376 in the full message (148-byte message header + 228-byte burn message prefix).

**Implementation:**

Source chain — switch from `depositForBurn` to `depositForBurnWithHook`:

```solidity
// In _cctpBurn, add owner parameter and use depositForBurnWithHook
function _cctpBurn(
    uint256 amount,
    uint32  destDomain,
    bytes32 mintRecipient,
    bytes32 destinationCaller,
    uint256 maxFee,
    uint32  minFinalityThreshold,
    address owner                    // NEW: encode in hookData
) internal {
    if (tokenMessenger == address(0)) revert ZeroAddress();
    if (amount == 0) revert ZeroAmount();
    if (mintRecipient == bytes32(0)) revert ZeroAddress();
    usdc.forceApprove(tokenMessenger, amount);
    (bool success, bytes memory ret) = tokenMessenger.call(
        abi.encodeWithSelector(
            ITokenMessengerV2.depositForBurnWithHook.selector,
            amount, destDomain, mintRecipient, address(usdc),
            destinationCaller, maxFee, minFinalityThreshold,
            abi.encode(owner)       // hookData = intended vault share recipient
        )
    );
    if (!success || ret.length < 32) revert CctpBurnFailed();
}
```

Destination chain — verify user in `relayAndDeposit`:

```solidity
error InvalidUser();

function relayAndDeposit(
    bytes calldata message,
    bytes calldata attestation,
    address user,
    address[] calldata vaults,
    uint256[] calldata amounts
) external onlyRelayer nonReentrant {
    // Parse hookData from CCTP message: header (148 bytes) + burn body (228 bytes) = 376
    address encodedUser = abi.decode(message[376:], (address));
    if (encodedUser != user) revert InvalidUser();

    // ... rest of existing logic unchanged
}
```

---

## #4: Owner can steal all user funds

**Finding:** The owner controls executor assignment with no timelock — two transactions suffice to drain any user with active approvals. For the proxy variant, a single malicious upgrade drains everything.

**Our Response:** We accept this as a centralization tradeoff, and can implement a timelock contract as an owner behind an (at least) 3 of 5 multisig.

---

## #5: Deployment docs vs deploy script mismatch

**Finding:** `docs/deployment.md` describes a UUPS proxy deployment workflow that doesn't match the actual `Deploy.s.sol`. The doc covers `upgradeToAndCall`, proxy/implementation separation, and an `initialize()` flow — none of which exist in `Deploy.s.sol`, which deploys the non-proxy `QuicknodeEarn.sol` directly via CreateX.

**Our Response:** `docs/deployment.md` was written for the original non-proxy contract and never updated when we moved to the UUPS proxy flow via `Deploy.s.sol`. We'll update the docs to match the actual CreateX + proxy deployment process.

**OZ Follow-up:** It's actually inverted — the documentation describes the upgradeable flow, but the script deploys the non-upgradeable version. The script needs to be updated to match the docs, not the other way around.

**Status:** Needs clarification. Verify whether the live deployments use the proxy or non-proxy contract, and align both docs and script to the actual production state.

---

## #6: Cross-chain deposits depend on relayer liveness

**Finding:** Cross-chain `selfBatchDeposit` is not truly self-serve — the relayer must call `relayAndDeposit` on the destination chain. Only `selfBatchWithdraw` is genuinely free of trusted-role liveness dependencies.

**Our Response:** We have a designed but unimplemented `emergencyReplaceBurn()` escape hatch that uses CCTP V2's `replaceDepositForBurn` to let users reclaim stuck bridged USDC directly to their wallet if the relayer is down.

**OZ Follow-up:** Would need to see the full change in a follow-up audit. From the snippet it's unclear how `burnOwner` would be synced across chains. The `hookData` approach (via `depositForBurnWithHook`) may be the right solution here as well.

**Critical discovery:** `replaceDepositForBurn` **does not exist in CCTP V2** — it was a V1 function removed entirely. The `escape_hatch_solidity.md` spec is invalid. hookData also doesn't solve relayer liveness since it's just metadata carried in the message — it doesn't make relay permissionless.

**Revised approach options:**

1. **Permissionless wrapper contract** — deploy a wrapper that anyone can call. Set `destinationCaller` to the wrapper address. The wrapper calls `receiveMessage`, parses hookData, and deposits into vaults. Anyone (including the user) can trigger it, removing relayer as a bottleneck.
2. **Timeout-based fallback** — owner can unlock relay permissions after N blocks of inactivity.
3. **Accept as centralization risk** — relayer is a trusted role; document accordingly.

**Status:** Investigating the permissionless wrapper approach as the cleanest solution.

---

## #7: Contract usable as general-purpose CCTP bridge

**Finding:** `mintRecipient` in `selfBatchDeposit` burns is unconstrained — a user can burn USDC and direct it to any address on any chain, bypassing vault deposits entirely.

**Our Response:** We'll constrain `mintRecipient` to `address(this)` in `selfBatchDeposit` burns since the deposit is always intended to land in the contract for relayer deposit into vaults. Combined with the escape hatch (#6), users still have a trustless exit if the relayer is down. This constraint applies only to `selfBatchDeposit`, not `selfBatchWithdraw`.

**OZ Follow-up (from #2):** If the approach changes to constrain `mintRecipient` to `user` instead of `address(this)` per OZ's #2 feedback, this implementation would also need to be revised accordingly.

**Implementation:**

```solidity
// Add to selfBatchDeposit(), inside the burns loop
if (burns[i].mintRecipient != bytes32(uint256(uint160(address(this))))) revert InvalidMintRecipient();
```

---

## Production Hotfixes (post-audit)

### Aave-source rebalance fees reverted on `aUsdc`

**Issue:** `rebalance()` and `withdrawAndBridge()` route fee collection through `_collectFees`, which required every entry in `feeVaults[]` to be in `approvedVaults`. The executor's fee engine passes `aUsdc` as the fee vault when the source position is Aave (fees taken in aUSDC shares before redeeming through the Aave Pool). aUSDC is the receipt token, not a Morpho ERC4626 vault, and adding it to `approvedVaults` would mis-route deposits/withdrawals through the ERC4626 branch in `_depositToVault` / `_withdrawFromVault`. Result: every Aave-source rebalance reverted with `VaultNotApproved(aUsdc)`. Two failed rebalances were observed on Optimism on 2026-04-27 before the fix.

**Fix:** Carve `aUsdc` out of the whitelist check in `_collectFees`, mirroring the inline aUSDC handling already present in `selfBatchWithdraw` (lines 780-790). Also added an explicit `address(0)` guard so chains where `aUsdc == address(0)` (Unichain, Monad) don't accidentally accept the zero address as a fee vault.

```solidity
for (uint256 i = 0; i < feeVaults.length; i++) {
    address fv = feeVaults[i];
    if (fv == address(0)) revert ZeroAddress();
    if (fv != aUsdc && !approvedVaults[fv]) revert VaultNotApproved(fv);
    IERC20(fv).safeTransferFrom(user, address(this), feeAmounts[i]);
}
```

Applied identically to both `QuicknodeEarn.sol` (legacy reference) and `QuicknodeEarnProxy.sol` (deployed UUPS impl). Tests in `test/QuicknodeEarn.test.ts` cover: aUsdc accepted as feeVault, random non-approved address rejected, `address(0)` rejected.

**Status:** Deployed as new implementation on all 7 chains via `executeUpgrade(uint32)`. Proxy address `0xcc204B…70d2` unchanged; storage (owner, executor, relayer, approvedVaults, vaultList) preserved. New impl addresses recorded in `multichain-deployments.md`.

---

## Open Action Items

| # | Action | Priority |
|---|--------|----------|
| 1 | Add `fromVault == toVault` revert to `rebalance()` | **Ship now** |
| 2 | Constrain `mintRecipient` in `withdrawAndBridge` to `user` (per OZ #2 feedback) | **Ship now** |
| 3 | Switch `_cctpBurn` to `depositForBurnWithHook` with `hookData = abi.encode(user)` | **Next upgrade** |
| 4 | Add hookData user verification to `relayAndDeposit` | **Next upgrade** |
| 5 | Implement timelock on owner role changes + upgrades behind multisig | **Future** |
| 6 | Align `docs/deployment.md` and `Deploy.s.sol` to match production state | **Ship now** |
| 7 | Investigate permissionless wrapper contract for relayer liveness (#6) | **Investigate** |
| 8 | Constrain `selfBatchDeposit` `mintRecipient` (pending #2 decision) | **Next upgrade** |
