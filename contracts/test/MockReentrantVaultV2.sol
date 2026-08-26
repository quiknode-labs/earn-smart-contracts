// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Malicious Vault V2 stand-in whose `forceDeallocate` re-enters the Earn
///      contract through a user-callable nonReentrant function. Used to prove
///      that ReentrancyGuardTransient spans the new force-dealloc externals and
///      their nested vault calls.
contract MockReentrantVaultV2 is ERC4626 {
    address public target;

    constructor(
        IERC20 asset_,
        address target_
    ) ERC4626(asset_) ERC20("Reentrant Vault", "rV2") {
        target = target_;
    }

    function forceDeallocate(
        address,
        bytes calldata,
        uint256,
        address
    ) external returns (uint256) {
        // emergencyClaimBridge is nonReentrant with no role gate, so the guard
        // is the first check to fire on the nested call.
        (bool ok, bytes memory ret) = target.call(
            abi.encodeWithSignature("emergencyClaimBridge(bytes,bytes)", bytes(""), bytes(""))
        );
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return 0;
    }
}
