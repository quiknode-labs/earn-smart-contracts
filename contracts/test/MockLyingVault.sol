// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev A vault that reports far more than it delivers. `transferFrom` and
///      `redeem` both succeed while moving nothing, and `redeem` returns an
///      operator-set figure. Used to prove that callers spend only USDC they
///      actually received, never USDC already resting in the Earn contract.
contract MockLyingVault {
    uint256 public reportedAssets;

    function setReportedAssets(uint256 reportedAssets_) external {
        reportedAssets = reportedAssets_;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function allowance(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function redeem(uint256, address, address) external view returns (uint256) {
        return reportedAssets;
    }
}
