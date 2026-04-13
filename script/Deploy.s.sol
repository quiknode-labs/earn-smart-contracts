// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../contracts/QuicknodeEarnProxy.sol";
import "../contracts/interfaces/ICreateX.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Minimal interface to read vault list from the existing deployed contract.
interface IExistingRebalancer {
    function getApprovedVaults() external view returns (address[] memory);
}

/// @dev Production deployment script for QuicknodeEarnProxy behind a UUPS proxy.
///
///      First deploy (proxy does not exist yet):
///        forge script script/Deploy.s.sol --rpc-url $BASE_RPC_URL --broadcast --sig "run(uint32)" 8453
///
///      Upgrade (proxy already deployed):
///        forge script script/Deploy.s.sol --rpc-url $BASE_RPC_URL --broadcast --sig "upgrade(uint32)" 8453
contract DeployQuicknodeEarnProxy is Script {
    // CreateX factory -same address on all EVM chains
    address constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    // Old v10 contract (non-proxy, deterministic address -used to seed initial vaults)
    address constant OLD_CONTRACT = 0x3124F026970C322DdCb017EAa667b7d50A42c5Cc;

    // CCTP V2 MessageTransmitter — same deterministic address on every supported chain.
    address constant MSG_TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;

    // Per-chain constructor args (immutables baked into implementation bytecode)
    struct ChainConfig {
        address usdc;
        address aavePool;       // zero if Aave not on chain
        address aUsdc;          // zero if Aave not on chain
        address msgTransmitter; // zero if CCTP not on chain
    }

    function getConfig(uint32 chainId) internal pure returns (ChainConfig memory) {
        if (chainId == 1) { // Ethereum
            return ChainConfig({
                usdc:            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
                aavePool:        0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2,
                aUsdc:           0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c,
                msgTransmitter:  MSG_TRANSMITTER
            });
        } else if (chainId == 10) { // Optimism (native USDC + USDCn aToken)
            return ChainConfig({
                usdc:            0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85,
                aavePool:        0x794a61358D6845594F94dc1DB02A252b5b4814aD,
                aUsdc:           0x38d693cE1dF5AaDF7bC62595A37D667aD57922e5,
                msgTransmitter:  MSG_TRANSMITTER
            });
        } else if (chainId == 130) { // Unichain — Morpho only
            return ChainConfig({
                usdc:            0x078D782b760474a361dDA0AF3839290b0EF57AD6,
                aavePool:        address(0),
                aUsdc:           address(0),
                msgTransmitter:  MSG_TRANSMITTER
            });
        } else if (chainId == 137) { // Polygon (native USDC + USDCn aToken)
            return ChainConfig({
                usdc:            0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359,
                aavePool:        0x794a61358D6845594F94dc1DB02A252b5b4814aD,
                aUsdc:           0xA4D94019934D8333Ef880ABFFbF2FDd611C762BD,
                msgTransmitter:  MSG_TRANSMITTER
            });
        } else if (chainId == 143) { // Monad
            return ChainConfig({
                usdc:            0x754704Bc059F8C67012fEd69BC8A327a5aafb603,
                aavePool:        address(0),
                aUsdc:           address(0),
                msgTransmitter:  MSG_TRANSMITTER
            });
        } else if (chainId == 8453) { // Base
            return ChainConfig({
                usdc:            0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
                aavePool:        0xA238Dd80C259a72e81d7e4664a9801593F98d1c5,
                aUsdc:           0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB,
                msgTransmitter:  MSG_TRANSMITTER
            });
        } else if (chainId == 42161) { // Arbitrum
            return ChainConfig({
                usdc:            0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
                aavePool:        0x794a61358D6845594F94dc1DB02A252b5b4814aD,
                aUsdc:           0x724dc807b04555b71ed48a6896b6F41593b8C637,
                msgTransmitter:  MSG_TRANSMITTER
            });
        }
        revert("Unsupported chain");
    }

    /// @notice Deploy a new implementation and the deterministic ERC1967 proxy,
    ///         seeding the proxy with an explicit list of approved vaults via initialize().
    ///         Use this for new chains where the v10 OLD_CONTRACT does not exist —
    ///         the orchestration script (scripts/deploy-chain.ts) reads vaults from the
    ///         approved_vaults Supabase table and passes them in as the second arg.
    function runWithVaults(uint32 chainId, address[] calldata initialVaults) external {
        ChainConfig memory cfg = getConfig(chainId);

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Guarded salt: first 20 bytes = deployer, last 12 bytes = version 11
        bytes32 salt = bytes32(abi.encodePacked(deployer, bytes12(uint96(11))));

        console.log("=== Deploy with explicit vaults ===");
        console.log("Chain ID:        ", chainId);
        console.log("Deployer:        ", deployer);
        console.log("Initial vaults:  ", initialVaults.length);

        vm.startBroadcast(deployerKey);

        // Step 1: Deploy implementation (regular CREATE — address doesn't matter)
        QuicknodeEarnProxy impl = new QuicknodeEarnProxy(
            cfg.usdc,
            cfg.aavePool,
            cfg.aUsdc,
            cfg.msgTransmitter
        );
        console.log("Implementation:  ", address(impl));

        // Step 2: Deploy ERC1967Proxy via CreateX CREATE3 (deterministic address)
        bytes memory initData = abi.encodeCall(
            QuicknodeEarnProxy.initialize,
            (deployer, initialVaults)
        );

        bytes memory proxyInitCode = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(address(impl), initData)
        );

        address proxy = ICreateX(CREATEX).deployCreate3(salt, proxyInitCode);

        vm.stopBroadcast();

        require(proxy != address(0), "Proxy deploy failed");

        QuicknodeEarnProxy rebalancer = QuicknodeEarnProxy(proxy);
        console.log("Proxy:           ", proxy);
        console.log("Owner:           ", rebalancer.owner());
        console.log("Vaults on chain: ", rebalancer.getApprovedVaults().length);
        console.log("USDC:            ", address(rebalancer.usdc()));
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
        QuicknodeEarnProxy impl = new QuicknodeEarnProxy(
            cfg.usdc,
            cfg.aavePool,
            cfg.aUsdc,
            cfg.msgTransmitter
        );
        console.log("Implementation:", address(impl));

        // Step 2: Deploy ERC1967Proxy via CreateX CREATE3 (deterministic address)
        //         The proxy constructor calls initialize() on the implementation via delegatecall.
        bytes memory initData = abi.encodeCall(
            QuicknodeEarnProxy.initialize,
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
        QuicknodeEarnProxy rebalancer = QuicknodeEarnProxy(proxy);
        console.log("Proxy:      ", proxy);
        console.log("Owner:      ", rebalancer.owner());
        console.log("Vaults:     ", rebalancer.getApprovedVaults().length);
        console.log("USDC:       ", address(rebalancer.usdc()));
    }

    /// @notice Upgrade an existing proxy to a new implementation.
    ///         Deploys a new implementation, calls upgradeToAndCall on the proxy,
    ///         and assigns executor + relayer roles from environment variables.
    function upgrade(uint32 chainId) external {
        ChainConfig memory cfg = getConfig(chainId);

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address executorAddr = vm.envAddress("EXECUTOR_ADDRESS");
        address relayerAddr  = vm.envAddress("RELAYER_ADDRESS");

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
        QuicknodeEarnProxy newImpl = new QuicknodeEarnProxy(
            cfg.usdc,
            cfg.aavePool,
            cfg.aUsdc,
            cfg.msgTransmitter
        );
        console.log("New impl:       ", address(newImpl));

        // Upgrade the proxy (no re-initialization needed)
        QuicknodeEarnProxy rebalancer = QuicknodeEarnProxy(proxy);
        rebalancer.upgradeToAndCall(address(newImpl), "");

        // Assign executor and relayer roles
        rebalancer.setExecutor(executorAddr);
        rebalancer.setRelayer(relayerAddr);

        vm.stopBroadcast();

        // Verify the upgrade
        console.log("Owner (kept):   ", rebalancer.owner());
        console.log("Executor:       ", rebalancer.executor());
        console.log("Relayer:        ", rebalancer.relayer());
        console.log("Vaults (kept):  ", rebalancer.getApprovedVaults().length);
        console.log("USDC:           ", address(rebalancer.usdc()));
    }

    /// @notice Upgrade a proxy at an explicit address (for when salt doesn't match).
    ///         Also assigns executor + relayer roles from environment variables.
    function upgradeAt(uint32 chainId, address proxy) external {
        ChainConfig memory cfg = getConfig(chainId);

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address executorAddr = vm.envAddress("EXECUTOR_ADDRESS");
        address relayerAddr  = vm.envAddress("RELAYER_ADDRESS");

        console.log("=== Upgrade At ===");
        console.log("Chain ID:       ", chainId);
        console.log("Proxy (target): ", proxy);

        require(proxy.code.length > 0, "Proxy not deployed at this address");

        vm.startBroadcast(deployerKey);

        QuicknodeEarnProxy newImpl = new QuicknodeEarnProxy(
            cfg.usdc,
            cfg.aavePool,
            cfg.aUsdc,
            cfg.msgTransmitter
        );
        console.log("New impl:       ", address(newImpl));

        QuicknodeEarnProxy rebalancer = QuicknodeEarnProxy(proxy);
        rebalancer.upgradeToAndCall(address(newImpl), "");

        // Assign executor and relayer roles
        rebalancer.setExecutor(executorAddr);
        rebalancer.setRelayer(relayerAddr);

        vm.stopBroadcast();

        console.log("Owner (kept):   ", rebalancer.owner());
        console.log("Executor:       ", rebalancer.executor());
        console.log("Relayer:        ", rebalancer.relayer());
        console.log("Vaults (kept):  ", rebalancer.getApprovedVaults().length);
        console.log("USDC:           ", address(rebalancer.usdc()));
    }
}
