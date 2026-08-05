// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Minimal smart-contract wallet used to prove the Earn contract works for
///      account-abstraction accounts (ERC-4337) and multi-sig wallets (Safe), not
///      only EOAs. It has no private key, so it authorises Permit2 pulls through
///      EIP-1271 `isValidSignature` exactly as a Safe or a 4337 account does.
///      `execute` stands in for whatever the real account uses to make an outbound
///      call (Safe's `execTransaction`, a 4337 account's `execute` invoked by the
///      EntryPoint). In every case the Earn contract sees `msg.sender` as this
///      wallet's address, which is the account itself.
contract MockSmartWallet {
    /// @dev EIP-1271 magic value: bytes4(keccak256("isValidSignature(bytes32,bytes)")).
    bytes4 internal constant MAGIC = 0x1626ba7e;

    /// @notice Signature blob this wallet treats as authorised. Stands in for a
    ///         Safe owner threshold being met.
    bytes public approvedSignature;

    function setApprovedSignature(bytes calldata sig) external {
        approvedSignature = sig;
    }

    /// @notice EIP-1271 verification. Returns the magic value for an authorised
    ///         signature and a failure value otherwise.
    function isValidSignature(bytes32, bytes calldata signature) external view returns (bytes4) {
        if (keccak256(signature) == keccak256(approvedSignature)) return MAGIC;
        return 0xffffffff;
    }

    /// @notice Make an arbitrary outbound call, so the wallet can drive the Earn
    ///         contract the way a real smart account would.
    function execute(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }
}
