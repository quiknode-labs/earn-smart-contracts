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

/// @dev Production deployment script for QuicknodeEarn (legacy non-upgradeable) and
///      QuicknodeEarnProxy (UUPS) via CreateX CREATE3.
///
///      Legacy non-upgradeable deploy:
///        forge script script/Deploy.s.sol --rpc-url $X_RPC_URL --broadcast \
///          --sig "run(uint32)" 8453
///        forge script script/Deploy.s.sol --rpc-url $X_RPC_URL --broadcast \
///          --sig "runWithVaults(uint32,address[])" 8453 "[0x...]"
///
///      Initial UUPS proxy deploy (deterministic proxy address via CREATE3):
///        forge script script/Deploy.s.sol --rpc-url $X_RPC_URL --broadcast \
///          --sig "deployProxy(uint32)" 8453
///        forge script script/Deploy.s.sol --rpc-url $X_RPC_URL --broadcast \
///          --sig "deployProxyWithVaults(uint32,address[])" 8453 "[0x...]"
///
///      Upgrade existing UUPS proxy (impl-only — multisig signs upgradeToAndCall):
///        forge script script/Deploy.s.sol --rpc-url $X_RPC_URL --broadcast \
///          --sig "deployProxyImpl(uint32)" 8453
///        Then the proxy owner (multisig) calls upgradeToAndCall(newImpl, "")
///        on 0xcc204B4cF3e796dAF4eDCFDeCfACfB1fc61F70d2 in a separate tx.
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
        address aavePool;        // zero if Aave not on chain
        address aUsdc;           // zero if Aave not on chain
        address msgTransmitter;  // zero if CCTP not on chain
        address tokenMessenger;  // zero if CCTP not on chain
    }

    function getConfig(uint32 chainId) internal pure returns (ChainConfig memory) {
        if (chainId == 1) { // Ethereum
            return ChainConfig({
                usdc:            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
                aavePool:        0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2,
                aUsdc:           0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c,
                msgTransmitter:  MSG_TRANSMITTER,
                tokenMessenger:  TOKEN_MESSENGER
            });
        } else if (chainId == 10) { // Optimism (native USDC + USDCn aToken)
            return ChainConfig({
                usdc:            0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85,
                aavePool:        0x794a61358D6845594F94dc1DB02A252b5b4814aD,
                aUsdc:           0x38d693cE1dF5AaDF7bC62595A37D667aD57922e5,
                msgTransmitter:  MSG_TRANSMITTER,
                tokenMessenger:  TOKEN_MESSENGER
            });
        } else if (chainId == 130) { // Unichain — Morpho only
            return ChainConfig({
                usdc:            0x078D782b760474a361dDA0AF3839290b0EF57AD6,
                aavePool:        address(0),
                aUsdc:           address(0),
                msgTransmitter:  MSG_TRANSMITTER,
                tokenMessenger:  TOKEN_MESSENGER
            });
        } else if (chainId == 137) { // Polygon (native USDC + USDCn aToken)
            return ChainConfig({
                usdc:            0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359,
                aavePool:        0x794a61358D6845594F94dc1DB02A252b5b4814aD,
                aUsdc:           0xA4D94019934D8333Ef880ABFFbF2FDd611C762BD,
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
                aavePool:        0xA238Dd80C259a72e81d7e4664a9801593F98d1c5,
                aUsdc:           0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB,
                msgTransmitter:  MSG_TRANSMITTER,
                tokenMessenger:  TOKEN_MESSENGER
            });
        } else if (chainId == 42161) { // Arbitrum
            return ChainConfig({
                usdc:            0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
                aavePool:        0x794a61358D6845594F94dc1DB02A252b5b4814aD,
                aUsdc:           0x724dc807b04555b71ed48a6896b6F41593b8C637,
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

    /// @notice Deploy a new QuicknodeEarnProxy implementation only (for upgrades).
    ///         The deployer no longer owns the production proxies — ownership has
    ///         been transferred to a multisig — so this script does NOT call
    ///         upgradeToAndCall. After the new impl is deployed, the multisig owner
    ///         must call upgradeToAndCall(newImpl, "") on the proxy in a separate tx.
    ///         Storage layout, executor, and relayer settings are preserved across
    ///         the upgrade.
    /// @return impl Address of the freshly deployed implementation.
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
        console.log("aavePool:    ", cfg.aavePool);
        console.log("aUsdc:       ", cfg.aUsdc);
        console.log("Next step:   multisig calls upgradeToAndCall(newImpl, \"\") on the proxy");
    }
}
