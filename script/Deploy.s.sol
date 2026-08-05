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

    // Expected QuicknodeEarnProxy.VERSION after this upgrade. Bump with the contract.
    uint256 constant VERSION_EXPECTED = 2;

    // Per-chain constructor args (immutables baked into bytecode)
    struct ChainConfig {
        address usdc;
        address msgTransmitter;  // zero if CCTP not on chain
        address tokenMessenger;  // zero if CCTP not on chain
    }

    function getConfig(uint32 chainId) internal pure returns (ChainConfig memory) {
        address usdc;
        if      (chainId == 1)     usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // Ethereum
        else if (chainId == 10)    usdc = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85; // Optimism
        else if (chainId == 130)   usdc = 0x078D782b760474a361dDA0AF3839290b0EF57AD6; // Unichain
        else if (chainId == 137)   usdc = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359; // Polygon
        else if (chainId == 143)   usdc = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603; // Monad
        else if (chainId == 8453)  usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Base
        else if (chainId == 42161) usdc = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // Arbitrum
        else revert("Unsupported chain");

        // CCTP V2 uses the same deterministic addresses on every supported chain.
        return ChainConfig({
            usdc:           usdc,
            msgTransmitter: MSG_TRANSMITTER,
            tokenMessenger: TOKEN_MESSENGER
        });
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

    /// @notice Fresh CREATE3 deploy of a new ERC1967Proxy + impl at a parameterised
    ///         salt version, with executor and relayer wired up in the same broadcast.
    ///         Used to ship a parallel deployment alongside an existing v11 proxy
    ///         (e.g. after a contract upgrade) without disturbing live users.
    ///
    /// @dev    Flow per chain:
    ///         1. Read EXECUTOR_ADDRESS and RELAYER_ADDRESS from env. Require that
    ///            the deployer EOA == EXECUTOR_ADDRESS so a single broadcast can
    ///            both deploy the proxy and call the owner-only setter functions.
    ///         2. Deploy implementation (regular CREATE).
    ///         3. Deploy ERC1967Proxy via CreateX CREATE3 with the supplied salt
    ///            version. Init data calls `initialize(deployer, initialVaults)`
    ///            inside the proxy's constructor — owner is set to deployer
    ///            (== executor), vault whitelist is seeded.
    ///         4. Owner calls `setExecutor(EXECUTOR_ADDRESS)` and
    ///            `setRelayer(RELAYER_ADDRESS)`.
    ///         5. Post-deploy assertions: owner == executor address,
    ///            executor == EXECUTOR_ADDRESS, relayer == RELAYER_ADDRESS,
    ///            vault count == initialVaults.length. Reverts if any mismatch.
    ///
    /// @param chainId         Target chain id (must match the connected RPC).
    /// @param saltVersion     CreateX salt version. Existing prod uses v11 — bump to
    ///                        v12+ to get a new deterministic proxy address.
    /// @param initialVaults   Vaults to whitelist in `initialize`. Owner can later
    ///                        add more via `addVault`/`batchAddVaults` or remove
    ///                        any via `removeVault`.
    function deployFreshProxy(
        uint32 chainId,
        uint96 saltVersion,
        address[] calldata initialVaults
    ) external {
        ChainConfig memory cfg = getConfig(chainId);

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        address executorAddr = vm.envAddress("EXECUTOR_ADDRESS");
        address relayerAddr  = vm.envAddress("RELAYER_ADDRESS");

        require(
            deployer == executorAddr,
            "deployer EOA must equal EXECUTOR_ADDRESS for single-broadcast deploy"
        );
        require(saltVersion != 11, "salt v11 is occupied by the existing prod proxy");

        // Salt format: first 20 bytes = deployer, last 12 bytes = version
        bytes32 salt = bytes32(abi.encodePacked(deployer, bytes12(saltVersion)));

        console.log("=== Fresh proxy deploy ===");
        console.log("Chain ID:        ", chainId);
        console.log("Salt version:    ", saltVersion);
        console.log("Deployer:        ", deployer);
        console.log("Executor (env):  ", executorAddr);
        console.log("Relayer  (env):  ", relayerAddr);
        console.log("Initial vaults:  ", initialVaults.length);

        vm.startBroadcast(deployerKey);

        // Step 1: deploy implementation (regular CREATE)
        QuicknodeEarnProxy impl = new QuicknodeEarnProxy(
            cfg.usdc,
            cfg.msgTransmitter,
            cfg.tokenMessenger
        );

        // Step 2: deploy ERC1967Proxy via CreateX CREATE3 — initializes inside constructor
        bytes memory initData = abi.encodeCall(
            QuicknodeEarnProxy.initialize,
            (deployer, initialVaults)
        );
        bytes memory proxyInitCode = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(address(impl), initData)
        );
        address proxy = ICreateX(CREATEX).deployCreate3(salt, proxyInitCode);

        // Step 3: wire executor and relayer (owner-only — works because deployer is owner)
        QuicknodeEarnProxy rebalancer = QuicknodeEarnProxy(proxy);
        rebalancer.setExecutor(executorAddr);
        rebalancer.setRelayer(relayerAddr);

        vm.stopBroadcast();

        // Step 4: post-deploy assertions — fail loudly if anything is misconfigured
        require(proxy != address(0), "Proxy deploy failed");
        require(rebalancer.owner()    == executorAddr, "owner != EXECUTOR_ADDRESS");
        require(rebalancer.executor() == executorAddr, "executor != EXECUTOR_ADDRESS");
        require(rebalancer.relayer()  == relayerAddr,  "relayer != RELAYER_ADDRESS");
        require(
            rebalancer.getApprovedVaults().length == initialVaults.length,
            "vault count mismatch"
        );

        console.log("--- Deployment complete ---");
        console.log("Implementation:  ", address(impl));
        console.log("Proxy:           ", proxy);
        console.log("Owner:           ", rebalancer.owner());
        console.log("Executor:        ", rebalancer.executor());
        console.log("Relayer:         ", rebalancer.relayer());
        console.log("Vaults seeded:   ", rebalancer.getApprovedVaults().length);
        console.log("USDC:            ", address(rebalancer.usdc()));
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
            cfg.msgTransmitter,
            cfg.tokenMessenger
        ));
        vm.stopBroadcast();

        console.log("New impl:    ", impl);
        console.log("USDC:        ", cfg.usdc);
        console.log("Next step:   owner calls upgradeToAndCall(newImpl, \"\") on the proxy");
    }

    /// @notice Deploy a new impl and upgrade the proxy at 0x48b415…bd8e in one broadcast.
    ///         Reverts if deployer != owner.
    function executeUpgrade(uint32 chainId) external {
        ChainConfig memory cfg = getConfig(chainId);

        // The chain id is a hand-typed argument while the RPC is a separate flag.
        // Without this, a mismatched pair bakes one chain's USDC into another
        // chain's implementation and upgrades the live proxy to it.
        require(block.chainid == chainId, "chainId argument does not match the RPC");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        address proxy       = 0x48b415841165304f7EfaA7D5dD5FC65cc7B4bd8e;

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
            cfg.msgTransmitter,
            cfg.tokenMessenger
        );

        // Step 2: Point the proxy at the new implementation. Empty initData — no
        //         re-initialisation needed (no new storage variables).
        rebalancer.upgradeToAndCall(address(newImpl), "");

        vm.stopBroadcast();

        // Post-conditions, not just logs: fail loudly rather than leave a live
        // proxy pointing at a wrong-chain implementation.
        require(address(rebalancer.usdc()) == cfg.usdc, "usdc != chain config");
        require(rebalancer.VERSION() == VERSION_EXPECTED, "implementation version mismatch");
        require(rebalancer.owner() == deployer, "owner changed during upgrade");

        console.log("New impl:        ", address(newImpl));
        console.log("Owner (kept):    ", rebalancer.owner());
        console.log("Executor (kept): ", rebalancer.executor());
        console.log("Relayer (kept):  ", rebalancer.relayer());
        console.log("Vaults (kept):   ", rebalancer.getApprovedVaults().length);
        console.log("USDC:            ", address(rebalancer.usdc()));
    }
}
