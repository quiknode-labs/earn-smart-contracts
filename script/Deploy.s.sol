// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../contracts/YieldRebalancer.sol";
import "../contracts/interfaces/ICreateX.sol";

/// @dev Production deployment script via CreateX CREATE3.
///      Vaults are NOT seeded at deploy time — run scripts/add-vaults.ts after deployment.
///
/// Base:  forge script script/Deploy.s.sol --rpc-url $BASE_RPC_URL --broadcast --sig "run(uint32)" 8453
/// Monad: forge script script/Deploy.s.sol --rpc-url $MONAD_RPC_URL --broadcast --sig "run(uint32)" 143
contract DeployYieldRebalancer is Script {
    // CreateX factory — same address on all EVM chains
    address constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    // Per-chain constructor args
    struct ChainConfig {
        address usdc;
        address aavePool;   // zero if Aave not on chain
        address aUsdc;      // zero if Aave not on chain
        address msgTransmitter;
    }

    function getConfig(uint32 chainId) internal pure returns (ChainConfig memory) {
        if (chainId == 8453) { // Base
            return ChainConfig({
                usdc:            0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
                aavePool:        0xA238Dd80C259a72e81d7e4664a9801593F98d1c5,
                aUsdc:           0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB,
                msgTransmitter:  0x81D40F21F12A8F0E3252Bccb954D722d4c464B64
            });
        } else if (chainId == 143) { // Monad
            return ChainConfig({
                usdc:            0x754704Bc059F8C67012fEd69BC8A327a5aafb603,
                aavePool:        address(0),
                aUsdc:           address(0),
                msgTransmitter:  address(0)
            });
        }
        revert("Unsupported chain");
    }

    function run(uint32 chainId) external {
        ChainConfig memory cfg = getConfig(chainId);

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Guarded salt: first 20 bytes = deployer, last 12 bytes = version 3
        bytes32 salt = bytes32(abi.encodePacked(deployer, bytes12(uint96(3))));

        address predicted = ICreateX(CREATEX).computeCreate3Address(salt, deployer);
        console.log("Chain ID:  ", chainId);
        console.log("Deployer:  ", deployer);
        console.log("Salt (v3): version 3");
        console.log("Predicted: ", predicted);

        // Empty vault list — add vaults post-deploy via scripts/add-vaults.ts
        address[] memory noVaults = new address[](0);

        bytes memory initCode = abi.encodePacked(
            type(YieldRebalancer).creationCode,
            abi.encode(
                cfg.usdc,
                cfg.aavePool,
                cfg.aUsdc,
                cfg.msgTransmitter,
                deployer,   // owner
                noVaults,   // no vaults at deploy time
                uint16(50), // maxFeeBps: 0.50%
                deployer    // feeRecipient
            )
        );

        vm.startBroadcast(deployerKey);
        address deployed = ICreateX(CREATEX).deployCreate3(salt, initCode);
        vm.stopBroadcast();

        require(deployed != address(0), "Deploy failed");
        console.log("Deployed:  ", deployed);
        console.log("Owner:     ", YieldRebalancer(deployed).owner());
    }
}
