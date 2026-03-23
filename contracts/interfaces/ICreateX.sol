// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interface for the CreateX factory deployed at 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed
/// @dev CREATE3 address depends only on (factory, guardedSalt) — independent of initcode/constructor args.
///      Guarded salt: first 20 bytes = deployer address, prevents front-running.
interface ICreateX {
    /// @notice Deploy a contract via CREATE3 using the provided salt and initCode.
    /// @param salt    32-byte guarded salt (first 20 bytes must equal msg.sender)
    /// @param initCode  ABI-encoded bytecode + constructor arguments
    /// @return newContract  The address of the deployed contract
    function deployCreate3(bytes32 salt, bytes calldata initCode) external payable returns (address newContract);

    /// @notice Compute the CREATE3 address for a given salt and deployer without deploying.
    /// @param salt      32-byte guarded salt
    /// @param deployer  The address that will call deployCreate3
    /// @return computedAddress  The deterministic address the contract will be deployed to
    function computeCreate3Address(bytes32 salt, address deployer) external view returns (address computedAddress);
}
