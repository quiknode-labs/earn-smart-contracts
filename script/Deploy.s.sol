// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../contracts/YieldRebalancer.sol";
import "../contracts/interfaces/ICreateX.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Minimal interface to read vault list from the existing deployed contract.
interface IExistingRebalancer {
    function getApprovedVaults() external view returns (address[] memory);
}

/// @dev Production deployment script for YieldRebalancer behind a UUPS proxy.
///
///      First deploy (proxy does not exist yet):
///        forge script script/Deploy.s.sol --rpc-url $BASE_RPC_URL --broadcast --sig "run(uint32)" 8453
///
///      Upgrade (proxy already deployed):
///        forge script script/Deploy.s.sol --rpc-url $BASE_RPC_URL --broadcast --sig "upgrade(uint32)" 8453
contract DeployYieldRebalancer is Script {
    // CreateX factory -same address on all EVM chains
    address constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    // Old v10 contract (non-proxy, deterministic address -used to seed initial vaults)
    address constant OLD_CONTRACT = 0x3124F026970C322DdCb017EAa667b7d50A42c5Cc;

    // Per-chain constructor args (immutables baked into implementation bytecode)
    struct ChainConfig {
        address usdc;
        address aavePool;       // zero if Aave not on chain
        address aUsdc;          // zero if Aave not on chain
        address msgTransmitter; // zero if CCTP not on chain
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
                msgTransmitter:  0x81D40F21F12A8F0E3252Bccb954D722d4c464B64
            });
        }
        revert("Unsupported chain");
    }

    /// @notice Deploy a new implementation and the deterministic ERC1967 proxy.
    ///         The proxy address never changes -only the implementation behind it.
    function run(uint32 chainId) external {
        ChainConfig memory cfg = getConfig(chainId);

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Guarded salt: first 20 bytes = deployer, last 12 bytes = version 11
        bytes32 salt = bytes32(abi.encodePacked(deployer, bytes12(uint96(11))));

        console.log("=== First Deploy (proxy + implementation) ===");
        console.log("Chain ID:   ", chainId);
        console.log("Deployer:   ", deployer);
        console.log("Salt (v11): version 11");

        // Read approved vaults from the old contract to seed via initialize()
        address[] memory initialVaults;
        if (OLD_CONTRACT.code.length > 0) {
            initialVaults = IExistingRebalancer(OLD_CONTRACT).getApprovedVaults();
        } else {
            initialVaults = new address[](0);
        }
        console.log("Seeding vaults:", initialVaults.length);

        vm.startBroadcast(deployerKey);

        // Step 1: Deploy implementation (regular CREATE -address doesn't matter)
        YieldRebalancer impl = new YieldRebalancer(
            cfg.usdc,
            cfg.aavePool,
            cfg.aUsdc,
            cfg.msgTransmitter
        );
        console.log("Implementation:", address(impl));

        // Step 2: Deploy ERC1967Proxy via CreateX CREATE3 (deterministic address)
        //         The proxy constructor calls initialize() on the implementation via delegatecall.
        bytes memory initData = abi.encodeCall(
            YieldRebalancer.initialize,
            (deployer, initialVaults)
        );

        bytes memory proxyInitCode = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(address(impl), initData)
        );

        address proxy = ICreateX(CREATEX).deployCreate3(salt, proxyInitCode);

        vm.stopBroadcast();

        require(proxy != address(0), "Proxy deploy failed");

        // Verify through the proxy
        YieldRebalancer rebalancer = YieldRebalancer(proxy);
        console.log("Proxy:      ", proxy);
        console.log("Owner:      ", rebalancer.owner());
        console.log("Vaults:     ", rebalancer.getApprovedVaults().length);
        console.log("USDC:       ", address(rebalancer.usdc()));
    }

    /// @notice Upgrade an existing proxy to a new implementation.
    ///         Deploys a new implementation and calls upgradeToAndCall on the proxy.
    function upgrade(uint32 chainId) external {
        ChainConfig memory cfg = getConfig(chainId);

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Compute the proxy address (same salt as initial deploy)
        bytes32 salt = bytes32(abi.encodePacked(deployer, bytes12(uint96(11))));
        address proxy = ICreateX(CREATEX).computeCreate3Address(salt, deployer);

        console.log("=== Upgrade ===");
        console.log("Chain ID:       ", chainId);
        console.log("Proxy (target): ", proxy);

        // Verify proxy exists
        require(proxy.code.length > 0, "Proxy not deployed -run 'run(chainId)' first");

        vm.startBroadcast(deployerKey);

        // Deploy new implementation
        YieldRebalancer newImpl = new YieldRebalancer(
            cfg.usdc,
            cfg.aavePool,
            cfg.aUsdc,
            cfg.msgTransmitter
        );
        console.log("New impl:       ", address(newImpl));

        // Upgrade the proxy (no re-initialization needed)
        YieldRebalancer(proxy).upgradeToAndCall(address(newImpl), "");

        vm.stopBroadcast();

        // Verify the upgrade
        YieldRebalancer rebalancer = YieldRebalancer(proxy);
        console.log("Owner (kept):   ", rebalancer.owner());
        console.log("Vaults (kept):  ", rebalancer.getApprovedVaults().length);
        console.log("USDC:           ", address(rebalancer.usdc()));
    }

    /// @notice Upgrade a proxy at an explicit address (for when salt doesn't match).
    function upgradeAt(uint32 chainId, address proxy) external {
        ChainConfig memory cfg = getConfig(chainId);

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        console.log("=== Upgrade At ===");
        console.log("Chain ID:       ", chainId);
        console.log("Proxy (target): ", proxy);

        require(proxy.code.length > 0, "Proxy not deployed at this address");

        vm.startBroadcast(deployerKey);

        YieldRebalancer newImpl = new YieldRebalancer(
            cfg.usdc,
            cfg.aavePool,
            cfg.aUsdc,
            cfg.msgTransmitter
        );
        console.log("New impl:       ", address(newImpl));

        YieldRebalancer(proxy).upgradeToAndCall(address(newImpl), "");

        vm.stopBroadcast();

        YieldRebalancer rebalancer = YieldRebalancer(proxy);
        console.log("Owner (kept):   ", rebalancer.owner());
        console.log("Vaults (kept):  ", rebalancer.getApprovedVaults().length);
        console.log("USDC:           ", address(rebalancer.usdc()));
        console.log("MsgTransmitter: ", rebalancer.messageTransmitter());
    }
}
