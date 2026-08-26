// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Morpho Vault V2 stand-in for force-deallocate tests. ERC4626 plus:
///      - a settable `idle` pool: withdrawals and redemptions revert beyond it,
///        simulating a V2 vault whose deposits are auto-allocated to markets
///        and which has no liquidity adapter configured.
///      - `forceDeallocate` that tops up `idle` and charges the WAD-scaled
///        `penalty` through the vault's own public withdraw, so real share-burn
///        and allowance semantics are exercised.
///
///      IMPORTANT — why totalAssets is tracked rather than read from balanceOf:
///      the real VaultV2 documents that "totalAssets is decreased normally along
///      with totalSupply (the share price doesn't change except because of
///      rounding errors)" when the penalty is charged. Inheriting OpenZeppelin's
///      `totalAssets() = asset.balanceOf(this)` would instead hold assets flat
///      while supply falls, so the share price would RISE and hand the penalty
///      straight back to the shares still in motion. A test built on that mock
///      would report an effective penalty of ~1 wei instead of the real amount
///      and would pass even if the penalty were free. `_totalAssets` is
///      decremented on the penalty leg to model the real vault.
contract MockVaultV2 is ERC4626 {
    uint256 public idle;
    uint256 public penalty; // WAD-scaled (1e18 = 100%)
    uint256 private _trackedAssets;
    address public lastAdapter;
    bytes   public lastData;

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_
    ) ERC4626(asset_) ERC20(name_, symbol_) {}

    function setIdle(uint256 idle_) external {
        idle = idle_;
    }

    function setPenalty(uint256 penalty_) external {
        penalty = penalty_;
    }

    function totalAssets() public view override returns (uint256) {
        return _trackedAssets;
    }

    function forceDeallocate(
        address adapter,
        bytes calldata data,
        uint256 assets,
        address onBehalf
    ) external returns (uint256 penaltyShares) {
        lastAdapter = adapter;
        lastData = data;
        idle += assets;
        uint256 penaltyAssets = Math.mulDiv(assets, penalty, 1e18, Math.Rounding.Ceil);
        // The real vault calls withdraw unconditionally, even at a zero penalty, so
        // a gated vault reverts on the gate check either way. Mirror that rather
        // than short-circuiting, or the zero-penalty tests would exercise a path
        // the real vault never takes.
        penaltyShares = withdraw(penaltyAssets, address(this), onBehalf);
    }

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        _trackedAssets += assets;
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev Enforce the idle cap on every exit that moves assets out of the
    ///      vault. The penalty leg (receiver == vault) keeps the assets inside,
    ///      so it does not consume idle, but it still reduces totalAssets so the
    ///      share price stays flat, matching the real vault.
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (receiver != address(this)) {
            require(assets <= idle, "MockVaultV2: insufficient idle");
            idle -= assets;
        }
        _trackedAssets -= assets;
        super._withdraw(caller, receiver, owner, assets, shares);
    }
}
