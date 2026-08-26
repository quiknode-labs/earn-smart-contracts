// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC1271Mock {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

/// @dev Permit2 SignatureTransfer stand-in, planted at the canonical PERMIT2
///      address with hardhat_setCode. It mirrors the real Permit2's signer
///      branch: an EOA owner is accepted on an allowlisted signature blob, and a
///      CONTRACT owner is verified through EIP-1271 `isValidSignature`, matching
///      the magic value the real `SignatureVerification` library compares
///      against. This is what lets smart-contract wallets (Safe, ERC-4337
///      accounts) use the Permit2 entry points, since they have no private key.
///      It also enforces the requested-amount cap like the real Permit2.
///      Stateless on purpose: hardhat_setCode copies runtime code, not storage.
contract MockPermit2 {
    bytes4 internal constant MAGIC = 0x1626ba7e;

    struct TokenPermissions {
        address token;
        uint256 amount;
    }
    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }
    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external {
        require(
            transferDetails.requestedAmount <= permit.permitted.amount,
            "MockPermit2: amount exceeds permitted"
        );

        // Real Permit2 branches on whether the claimed signer has code.
        bytes32 digest = keccak256(abi.encode(permit, transferDetails.to, owner));
        if (owner.code.length > 0) {
            require(
                IERC1271Mock(owner).isValidSignature(digest, signature) == MAGIC,
                "MockPermit2: invalid contract signature"
            );
        } else {
            require(signature.length > 0, "MockPermit2: empty signature");
        }

        IERC20(permit.permitted.token).transferFrom(owner, transferDetails.to, transferDetails.requestedAmount);
    }
}
