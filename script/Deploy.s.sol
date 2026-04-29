// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import { QuicknodeEarn } from "../contracts/QuicknodeEarn.sol";
import { QuicknodeEarnProxy } from "../contracts/QuicknodeEarnProxy.sol";
import "../contracts/interfaces/ICreateX.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Minimal interface to read vault list from the existing deployed contract.
interface IExistingRebalancer {
    function getApprovedVaults() external view returns (address[] memory);
}

/// @dev Deploy/upgrade entry points for QuicknodeEarn (legacy) and QuicknodeEarnProxy (UUPS).
///      Functions: run, runWithVaults, deployProxy, deployProxyWithVaults, deployProxyImpl, executeUpgrade.
///      All read PRIVATE_KEY from env. See deployment.md for invocation.
contract DeployQuicknodeEarn is Script {
    // CreateX factory — same address on all EVM chains
    address constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    // Old v10 contract (non-proxy, deterministic address — used to seed initial vaults)
    address constant OLD_CONTRACT = 0x3124F026970C322DdCb017EAa667b7d50A42c5Cc;

    // CCTP V2 MessageTransmitter — same deterministic address on every supported chain.
    address constant MSG_TRANSMITTER  = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    // CCTP V2 TokenMessenger — same deterministic address on every supported chain.
    address constant TOKEN_MESSENGER  = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;

    // Per-chain constructor args (immutables baked into bytecode)
    struct ChainConfig {
        address usdc;
        address aavePool;        // deprecated (Aave removed) — always address(0)
        address aUsdc;           // deprecated (Aave removed) — always address(0)
        address msgTransmitter;  // zero if CCTP not on chain
        address tokenMessenger;  // zero if CCTP not on chain
    }

    function getConfig(uint32 chainId) internal pure returns (ChainConfig memory) {
        if (chainId == 1) { // Ethereum
            return ChainConfig({
                usdc:            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
                aavePool:        address(0),
                aUsdc:           address(0),
                msgTransmitter:  MSG_TRANSMITTER,
                tokenMessenger:  TOKEN_MESSENGER
            });
        } else if (chainId == 10) { // Optimism
            return ChainConfig({
                usdc:            0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85,
                aavePool:        address(0),
                aUsdc:           address(0),
                msgTransmitter:  MSG_TRANSMITTER,
                tokenMessenger:  TOKEN_MESSENGER
            });
        } else if (chainId == 130) { // Unichain
            return ChainConfig({
                usdc:            0x078D782b760474a361dDA0AF3839290b0EF57AD6,
                aavePool:        address(0),
                aUsdc:           address(0),
                msgTransmitter:  MSG_TRANSMITTER,
                tokenMessenger:  TOKEN_MESSENGER
            });
        } else if (chainId == 137) { // Polygon
            return ChainConfig({
                usdc:            0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359,
                aavePool:        address(0),
                aUsdc:           address(0),
                msgTransmitter:  MSG_TRANSMITTER,
                tokenMessenger:  TOKEN_MESSENGER
            });
        } else if (chainId == 143) { // Monad
            return ChainConfig({
                usdc:            0x754704Bc059F8C67012fEd69BC8A327a5aafb603,
                aavePool:        address(0),
                aUsdc:           address(0),
                msgTransmitter:  MSG_TRANSMITTER,
                tokenMessenger:  TOKEN_MESSENGER
            });
        } else if (chainId == 8453) { // Base
            return ChainConfig({
                usdc:            0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
                aavePool:        address(0),
                aUsdc:           address(0),
                msgTransmitter:  MSG_TRANSMITTER,
                tokenMessenger:  TOKEN_MESSENGER
            });
        } else if (chainId == 42161) { // Arbitrum
            return ChainConfig({
                usdc:            0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
                aavePool:        address(0),
                aUsdc:           address(0),
                msgTransmitter:  MSG_TRANSMITTER,
                tokenMessenger:  TOKEN_MESSENGER
            });
        }
        revert("Unsupported chain");
    }

    // -------------------------------------------------------------------------
    // Legacy non-upgradeable QuicknodeEarn deploys
    // -------------------------------------------------------------------------

    /// @notice Deploy non-upgradeable QuicknodeEarn with an explicit list of approved vaults.
    function runWithVaults(uint32 chainId, address[] calldata initialVaults) external {
        ChainConfig memory cfg = getConfig(chainId);

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Guarded salt: first 20 bytes = deployer, last 12 bytes = version 11
        bytes32 salt = bytes32(abi.encodePacked(deployer, bytes12(uint96(11))));

        console.log("=== Deploy legacy with explicit vaults ===");
        console.log("Chain ID:        ", chainId);
        console.log("Deployer:        ", deployer);
        console.log("Initial vaults:  ", initialVaults.length);

        vm.startBroadcast(deployerKey);

        bytes memory initCode = abi.encodePacked(
            type(QuicknodeEarn).creationCode,
            abi.encode(
                cfg.usdc,
                cfg.aavePool,
                cfg.aUsdc,
                cfg.msgTransmitter,
                cfg.tokenMessenger,
                deployer,
                initialVaults
            )
        );

        address deployed = ICreateX(CREATEX).deployCreate3(salt, initCode);

        vm.stopBroadcast();

        require(deployed != address(0), "Deploy failed");

        QuicknodeEarn rebalancer = QuicknodeEarn(deployed);
        console.log("Deployed:        ", deployed);
        console.log("Owner:           ", rebalancer.owner());
        console.log("Vaults on chain: ", rebalancer.getApprovedVaults().length);
        console.log("USDC:            ", address(rebalancer.usdc()));
    }

    /// @notice Deploy non-upgradeable QuicknodeEarn, seeding vaults from the old v10 contract.
    function run(uint32 chainId) external {
        ChainConfig memory cfg = getConfig(chainId);

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Guarded salt: first 20 bytes = deployer, last 12 bytes = version 11
        bytes32 salt = bytes32(abi.encodePacked(deployer, bytes12(uint96(11))));

        console.log("=== Deploy legacy (seed from old contract) ===");
        console.log("Chain ID:   ", chainId);
        console.log("Deployer:   ", deployer);
        console.log("Salt (v11): version 11");

        // Read approved vaults from the old contract to seed
        address[] memory initialVaults;
        if (OLD_CONTRACT.code.length > 0) {
            initialVaults = IExistingRebalancer(OLD_CONTRACT).getApprovedVaults();
        } else {
            initialVaults = new address[](0);
        }
        console.log("Seeding vaults:", initialVaults.length);

        vm.startBroadcast(deployerKey);

        bytes memory initCode = abi.encodePacked(
            type(QuicknodeEarn).creationCode,
            abi.encode(
                cfg.usdc,
                cfg.aavePool,
                cfg.aUsdc,
                cfg.msgTransmitter,
                cfg.tokenMessenger,
                deployer,
                initialVaults
            )
        );

        address deployed = ICreateX(CREATEX).deployCreate3(salt, initCode);

        vm.stopBroadcast();

        require(deployed != address(0), "Deploy failed");

        QuicknodeEarn rebalancer = QuicknodeEarn(deployed);
        console.log("Deployed:   ", deployed);
        console.log("Owner:      ", rebalancer.owner());
        console.log("Vaults:     ", rebalancer.getApprovedVaults().length);
        console.log("USDC:       ", address(rebalancer.usdc()));
    }

    // -------------------------------------------------------------------------
    // UUPS proxy deploys (initial + upgrade)
    // -------------------------------------------------------------------------

    /// @notice Initial deterministic UUPS deploy of QuicknodeEarnProxy with explicit vaults.
    ///         Deploys the implementation (regular CREATE), then deploys ERC1967Proxy via
    ///         CreateX CREATE3 with salt v11 — yields the same proxy address on every chain.
    ///         Initial owner is the deployer; transfer ownership to multisig in a follow-up tx.
    function deployProxyWithVaults(uint32 chainId, address[] calldata initialVaults) external {
        ChainConfig memory cfg = getConfig(chainId);

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        bytes32 salt = bytes32(abi.encodePacked(deployer, bytes12(uint96(11))));

        console.log("=== Deploy proxy with explicit vaults ===");
        console.log("Chain ID:        ", chainId);
        console.log("Deployer:        ", deployer);
        console.log("Initial vaults:  ", initialVaults.length);

        vm.startBroadcast(deployerKey);

        // Step 1: Deploy implementation (regular CREATE — address doesn't matter)
        QuicknodeEarnProxy impl = new QuicknodeEarnProxy(
            cfg.usdc,
            cfg.aavePool,
            cfg.aUsdc,
            cfg.msgTransmitter,
            cfg.tokenMessenger
        );
        console.log("Implementation:  ", address(impl));

        // Step 2: Deploy ERC1967Proxy via CreateX CREATE3 (deterministic address).
        //         Constructor calldelegates initialize() through the proxy.
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

    /// @notice Initial deterministic UUPS deploy of QuicknodeEarnProxy, seeding vaults
    ///         from the old v10 contract.
    function deployProxy(uint32 chainId) external {
        ChainConfig memory cfg = getConfig(chainId);

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        bytes32 salt = bytes32(abi.encodePacked(deployer, bytes12(uint96(11))));

        console.log("=== Deploy proxy (seed from old contract) ===");
        console.log("Chain ID:   ", chainId);
        console.log("Deployer:   ", deployer);
        console.log("Salt (v11): version 11");

        address[] memory initialVaults;
        if (OLD_CONTRACT.code.length > 0) {
            initialVaults = IExistingRebalancer(OLD_CONTRACT).getApprovedVaults();
        } else {
            initialVaults = new address[](0);
        }
        console.log("Seeding vaults:", initialVaults.length);

        vm.startBroadcast(deployerKey);

        QuicknodeEarnProxy impl = new QuicknodeEarnProxy(
            cfg.usdc,
            cfg.aavePool,
            cfg.aUsdc,
            cfg.msgTransmitter,
            cfg.tokenMessenger
        );
        console.log("Implementation:", address(impl));

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
        console.log("Proxy:      ", proxy);
        console.log("Owner:      ", rebalancer.owner());
        console.log("Vaults:     ", rebalancer.getApprovedVaults().length);
        console.log("USDC:       ", address(rebalancer.usdc()));
    }

    /// @notice Deploy a new impl without upgrading. Owner must call upgradeToAndCall separately.
    ///         For the current setup where owner == deployer, use executeUpgrade instead.
    function deployProxyImpl(uint32 chainId) external returns (address impl) {
        ChainConfig memory cfg = getConfig(chainId);

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("=== Deploy new proxy implementation only ===");
        console.log("Chain ID:    ", chainId);
        console.log("Deployer:    ", deployer);

        vm.startBroadcast(deployerKey);
        impl = address(new QuicknodeEarnProxy(
            cfg.usdc,
            cfg.aavePool,
            cfg.aUsdc,
            cfg.msgTransmitter,
            cfg.tokenMessenger
        ));
        vm.stopBroadcast();

        console.log("New impl:    ", impl);
        console.log("USDC:        ", cfg.usdc);
        console.log("Next step:   owner calls upgradeToAndCall(newImpl, \"\") on the proxy");
    }

    /// @notice Deploy a new impl and upgrade the proxy at 0xcc204B…70d2 in one broadcast.
    ///         Reverts if deployer != owner.
    function executeUpgrade(uint32 chainId) external {
        ChainConfig memory cfg = getConfig(chainId);

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        address proxy       = 0xcc204B4cF3e796dAF4eDCFDeCfACfB1fc61F70d2;

        require(proxy.code.length > 0, "Proxy not deployed on this chain");

        QuicknodeEarnProxy rebalancer = QuicknodeEarnProxy(proxy);
        require(rebalancer.owner() == deployer, "Deployer is not proxy owner");

        console.log("=== Execute upgrade ===");
        console.log("Chain ID:        ", chainId);
        console.log("Proxy:           ", proxy);
        console.log("Deployer:        ", deployer);

        vm.startBroadcast(deployerKey);

        // Step 1: Deploy new implementation with this chain's per-chain immutables.
        QuicknodeEarnProxy newImpl = new QuicknodeEarnProxy(
            cfg.usdc,
            cfg.aavePool,
            cfg.aUsdc,
            cfg.msgTransmitter,
            cfg.tokenMessenger
        );

        // Step 2: Point the proxy at the new implementation. Empty initData — no
        //         re-initialisation needed (no new storage variables).
        rebalancer.upgradeToAndCall(address(newImpl), "");

        vm.stopBroadcast();

        // Verify state is preserved.
        console.log("New impl:        ", address(newImpl));
        console.log("Owner (kept):    ", rebalancer.owner());
        console.log("Executor (kept): ", rebalancer.executor());
        console.log("Relayer (kept):  ", rebalancer.relayer());
        console.log("Vaults (kept):   ", rebalancer.getApprovedVaults().length);
        console.log("USDC:            ", address(rebalancer.usdc()));
    }
}
