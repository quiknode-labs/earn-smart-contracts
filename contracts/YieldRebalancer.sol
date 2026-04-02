// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @dev Minimal Aave V3 Pool interface for supply/withdraw
interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/// @dev Minimal CCTP V2 MessageTransmitter interface for relaying messages
interface IMessageTransmitter {
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool);
}

/// @dev Minimal CCTP V2 TokenMessenger interface for cross-chain burns
interface ITokenMessengerV2 {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external returns (bytes32);
}

/// @notice Parameters for a single CCTP V2 cross-chain burn within `selfBatchDeposit`
///         and `selfBatchWithdraw` (bridge-back on close).
/// @dev All fields are value types so the struct is calldata-safe.
struct BridgeBurn {
    address tokenMessenger;       // CCTP V2 TokenMessenger contract address
    uint32  destDomain;           // CCTP destination domain (e.g. 6 = Base, 15 = Monad)
    bytes32 mintRecipient;        // bytes32-padded address to receive minted USDC on dest chain
    bytes32 destinationCaller;    // bytes32-padded address permitted to relay on dest chain (MEV protection)
    uint256 amount;               // USDC amount to burn for this destination
    uint256 maxFee;               // Maximum fee the CCTP protocol may charge (0 for standard)
    uint32  minFinalityThreshold; // 0 = fast finality (seconds), 2000 = standard finality (full chain finality)
}

/// @title YieldRebalancer
/// @notice Non-custodial yield-optimiser that moves user funds between whitelisted
///         Morpho (ERC4626) vaults and the Aave V3 Pool to maximise supply APY.
/// @dev Architecture overview:
///      - Users retain full custody: they grant ERC20 approvals to this contract but
///        never transfer principal in; all vault shares/aTokens are held by the user.
///      - The owner (a trusted rebalancer EOA/service) calls the privileged functions
///        (`deposit`, `rebalance`, `withdrawAndBridge`, `relayAndDeposit`)
///        to move capital on the user's behalf.
///      - Users can create strategies via `selfBatchDeposit` and close them via
///        `selfBatchWithdraw` without owner involvement.
///      - Fee model: a performance fee is collected as vault shares (not USDC). The executor
///        computes 15% of yield earned across ALL strategy vaults, converts each to vault
///        shares, and passes them as `feeVaults[]`/`feeAmounts[]` on rebalance/withdraw
///        calls. The contract transfers those shares from the user to itself, accumulating
///        them in `heldFeeShares`. The owner sweeps accumulated shares via `sweep()`.
///        Fee arrays may be empty (no-fee rebalance) or contain vaults unrelated to the
///        current `fromVault`/`toVault` pair — the executor collects from ALL vaults with
///        accrued yield in a single operation.
///      - Vault whitelist: only addresses in `approvedVaults` may receive deposits. This
///        prevents the owner from draining users into arbitrary contracts.
///      - Two-step ownership (`Ownable2Step`) prevents accidental ownership transfer to
///        an uncontrolled address.
///      - CCTP integration: `withdrawAndBridge` burns USDC cross-chain via Circle's
///        CCTP V2; `relayAndDeposit` relays a CCTP message and atomically deposits.
///      - `selfBatchDeposit` and `selfBatchWithdraw` are deliberately user-callable
///        with no owner requirement, providing a trustless exit path independent of
///        the rebalancer.
contract YieldRebalancer is Initializable, Ownable2Step, ReentrancyGuard, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice The USDC token this contract operates on.
    IERC20  public immutable usdc;

    /// @notice The Aave V3 Pool contract address.
    ///         When `vault == aavePool`, deposit/withdraw routes through `IPool`.
    ///         May be `address(0)` on chains where Aave V3 is not deployed.
    address public immutable aavePool;

    /// @notice The Aave aUSDC (interest-bearing) token address.
    ///         Used to pull the user's aUSDC balance when withdrawing from Aave.
    ///         May be `address(0)` on chains where Aave V3 is not deployed.
    address public immutable aUsdc;

    /// @notice The CCTP V2 MessageTransmitter address for relaying bridge messages.
    ///         `address(0)` disables CCTP relay functionality (`relayAndDeposit` reverts).
    address public immutable messageTransmitter;

    /// @notice Maps vault address → whether it is whitelisted for deposits.
    mapping(address => bool) public approvedVaults;

    /// @notice Enumerable list of all currently approved vault addresses.
    ///         Maintained in sync with `approvedVaults`.
    address[] public vaultList;

    /// @notice Accumulated vault shares taken as performance fees, keyed by vault address.
    ///         Incremented each time the executor passes non-empty `feeVaults`/`feeAmounts`
    ///         to `rebalance`, `selfBatchWithdraw`, or `withdrawAndBridge`.
    ///         The owner drains a specific vault's accumulated shares via `sweep(token, amount)`.
    mapping(address => uint256) public heldFeeShares;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a vault is added to the whitelist.
    /// @param vault The address of the newly approved vault.
    event VaultAdded(address indexed vault);

    /// @notice Emitted when a vault is removed from the whitelist.
    /// @param vault The address of the vault that was de-listed.
    event VaultRemoved(address indexed vault);

    /// @notice Emitted after a successful single-vault deposit.
    /// @param user            The user who owns the resulting shares/aTokens.
    /// @param vault           The vault or Aave Pool that received USDC.
    /// @param usdcAmount      USDC deposited (6 decimals).
    /// @param sharesReceived  Vault shares minted (or aUSDC received for Aave, ~1:1).
    event Deposited(
        address indexed user,
        address indexed vault,
        uint256 usdcAmount,
        uint256 sharesReceived
    );

    /// @notice Emitted after a successful rebalance between two vaults.
    /// @param user       The user whose position was moved.
    /// @param fromVault  The vault that was withdrawn from.
    /// @param toVault    The vault that received the re-deposited USDC.
    /// @param shares     Shares (or aUSDC) pulled from `fromVault`.
    /// @param usdcAmount USDC received on withdrawal (full amount deposited into toVault).
    event Rebalanced(
        address indexed user,
        address indexed fromVault,
        address indexed toVault,
        uint256 shares,
        uint256 usdcAmount
    );

    /// @notice Emitted when `selfBatchDeposit` completes, summarising a new multi-vault strategy.
    /// @param user       The user who created the strategy.
    /// @param totalUsdc  Total USDC pulled from the user in one transfer.
    event StrategyCreated(
        address indexed user,
        uint256 totalUsdc
    );

    /// @notice Emitted for each vault leg of a `selfBatchWithdraw` call.
    /// @param user        The user whose position was closed.
    /// @param vault       The vault that was withdrawn from.
    /// @param shares      Shares (or aUSDC) redeemed.
    /// @param usdcReceived USDC returned to the user.
    event StrategyExited(
        address indexed user,
        address indexed vault,
        uint256 shares,
        uint256 usdcReceived
    );

    /// @notice Emitted whenever vault shares are collected as a performance fee.
    /// @param user    The user who paid the fee.
    /// @param vaults  The vault addresses from which fee shares were taken.
    ///                May include vaults unrelated to the current rebalance operation —
    ///                fees are collected from ALL strategy vaults with accrued yield.
    /// @param amounts The share amounts taken from each vault in `vaults`.
    event PerformanceFeeCollected(
        address indexed user,
        address[] vaults,
        uint256[] amounts
    );

    /// @notice Emitted when accumulated fees (or any token) are swept to a recipient.
    /// @param token      The ERC20 token swept.
    /// @param recipient  The address that received the tokens.
    /// @param amount     Amount transferred.
    event FeeSwept(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );

    /// @notice Emitted after `withdrawAndBridge` burns USDC via CCTP.
    /// @param user       User whose vault position was bridged.
    /// @param vault      The vault that was withdrawn from.
    /// @param shares     Shares (or aUSDC) redeemed.
    /// @param usdcBurned USDC sent to the CCTP TokenMessenger for burning.
    /// @param destDomain CCTP destination domain ID.
    event BridgeInitiated(
        address indexed user,
        address indexed vault,
        uint256 shares,
        uint256 usdcBurned,
        uint32  destDomain
    );

    /// @notice Emitted after USDC from a bridge relay is deposited into a vault.
    /// @param user           User who receives the vault shares.
    /// @param vault          Destination vault.
    /// @param usdcAmount     USDC deposited.
    /// @param sharesReceived Shares minted (or aUSDC for Aave, ~1:1).
    event DepositedFromBridge(
        address indexed user,
        address indexed vault,
        uint256 usdcAmount,
        uint256 sharesReceived
    );

    /// @notice Emitted for each CCTP burn in `selfBatchDeposit` when bridging USDC cross-chain.
    /// @dev Separate from `BridgeInitiated` because no vault withdrawal is involved —
    ///      raw USDC is burned directly from the user's deposit.
    /// @param user          The user who initiated the deposit+bridge.
    /// @param amount        USDC burned via CCTP.
    /// @param destDomain    CCTP destination domain ID.
    /// @param mintRecipient bytes32-padded address receiving minted USDC on dest chain.
    event BridgeBurnInitiated(
        address indexed user,
        uint256 amount,
        uint32  destDomain,
        bytes32 mintRecipient
    );

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when an operation targets a vault that is not in the whitelist.
    /// @param vault The non-approved vault address.
    error VaultNotApproved(address vault);

    /// @notice Thrown when a zero-amount argument is passed where a positive value is required.
    error ZeroAmount();

    /// @notice Thrown when a zero address is passed where a non-zero address is required.
    error ZeroAddress();

    /// @notice Thrown when an array argument has an invalid length or a zero-length array is forbidden.
    error InvalidInput();

    /// @notice Thrown when `feeVaults` and `feeAmounts` arrays have different lengths.
    error ArrayLengthMismatch();

    /// @notice Thrown when the low-level call to the CCTP TokenMessenger's `depositForBurn` fails.
    error CctpBurnFailed();

    /// @notice Thrown when the CCTP `receiveMessage` relay call returns false.
    error MessageRelayFailed();

    // -------------------------------------------------------------------------
    // Constructor (implementation only — sets immutables, disables initializers)
    // -------------------------------------------------------------------------

    /// @notice Deploy the YieldRebalancer implementation.
    /// @dev Sets immutable addresses baked into bytecode. Storage-based state (owner,
    ///      vault whitelist) is set via `initialize()` through the proxy.
    ///      `_disableInitializers()` prevents the implementation from being initialized
    ///      directly — only the proxy should call `initialize()`.
    ///      `Ownable(msg.sender)` is a dummy value required by the constructor; the real
    ///      owner is set in `initialize()` via `_transferOwnership()`.
    /// @param _usdc               USDC token address.
    /// @param _aavePool           Aave V3 Pool address; `address(0)` if Aave not on chain.
    /// @param _aUsdc              Aave aUSDC token address; `address(0)` if Aave not on chain.
    /// @param _messageTransmitter CCTP V2 MessageTransmitter; `address(0)` disables relay.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _usdc,
        address _aavePool,
        address _aUsdc,
        address _messageTransmitter
    ) Ownable(msg.sender) {
        if (_usdc == address(0)) revert ZeroAddress();

        usdc               = IERC20(_usdc);
        aavePool           = _aavePool;
        aUsdc              = _aUsdc;
        messageTransmitter = _messageTransmitter;

        _disableInitializers();
    }

    // -------------------------------------------------------------------------
    // Initializer (called once through proxy)
    // -------------------------------------------------------------------------

    /// @notice Initialize storage-based state through the proxy.
    /// @dev Called exactly once by the ERC1967Proxy constructor. Sets the real owner
    ///      and optionally seeds the vault whitelist. Subsequent upgrades preserve
    ///      storage and do NOT re-run this function.
    /// @param _owner         Initial owner (rebalancer EOA). Receives all owner privileges.
    /// @param _initialVaults Optional list of vaults to whitelist atomically.
    ///                       Duplicates and zero addresses are silently skipped.
    function initialize(
        address _owner,
        address[] calldata _initialVaults
    ) external initializer {
        if (_owner == address(0)) revert ZeroAddress();
        _transferOwnership(_owner);

        for (uint256 i = 0; i < _initialVaults.length; i++) {
            address vault = _initialVaults[i];
            if (vault != address(0) && !approvedVaults[vault]) {
                approvedVaults[vault] = true;
                vaultList.push(vault);
                emit VaultAdded(vault);
            }
        }
    }

    // -------------------------------------------------------------------------
    // Owner-only: Vault management
    // -------------------------------------------------------------------------

    /// @notice Add a single vault to the whitelist.
    /// @dev Idempotent: re-adding an already-approved vault is a no-op (no duplicate in `vaultList`).
    /// @param vault The vault address to whitelist. Must not be `address(0)`.
    function addVault(address vault) external onlyOwner {
        if (vault == address(0)) revert ZeroAddress();
        if (!approvedVaults[vault]) {
            approvedVaults[vault] = true;
            vaultList.push(vault);
            emit VaultAdded(vault);
        }
    }

    /// @notice Add multiple vaults to the whitelist in one transaction.
    /// @dev Each element is validated and silently skipped if already approved.
    ///      Reverts if any element is `address(0)`.
    /// @param vaults Array of vault addresses to whitelist.
    function batchAddVaults(address[] calldata vaults) external onlyOwner {
        for (uint256 i = 0; i < vaults.length; i++) {
            address vault = vaults[i];
            if (vault == address(0)) revert ZeroAddress();
            if (!approvedVaults[vault]) {
                approvedVaults[vault] = true;
                vaultList.push(vault);
                emit VaultAdded(vault);
            }
        }
    }

    /// @notice Remove a vault from the whitelist.
    /// @dev Uses a swap-and-pop on `vaultList` for O(n) removal; order is not preserved.
    ///      Reverts if `vault` is not currently approved.
    /// @param vault The vault address to de-list.
    function removeVault(address vault) external onlyOwner {
        if (!approvedVaults[vault]) revert VaultNotApproved(vault);
        approvedVaults[vault] = false;

        // Remove from vaultList array (swap-and-pop, does not preserve order)
        uint256 len = vaultList.length;
        for (uint256 i = 0; i < len; i++) {
            if (vaultList[i] == vault) {
                vaultList[i] = vaultList[len - 1];
                vaultList.pop();
                break;
            }
        }

        emit VaultRemoved(vault);
    }

    // -------------------------------------------------------------------------
    // Owner-only: Deposits
    // -------------------------------------------------------------------------

    /// @notice Deposit USDC from `user` into a single whitelisted vault.
    /// @dev Two deposit paths:
    ///      - **Aave** (`vault == aavePool`): USDC is supplied to `IPool.supply`, which
    ///        mints aUSDC 1:1 directly to `user`. The contract never holds aUSDC.
    ///      - **Morpho / ERC4626**: USDC is deposited via `IERC4626.deposit`, which
    ///        mints vault shares to `user`. The contract never holds shares.
    ///      The reason Aave does not go through ERC4626 is that the Aave V3 Pool is not
    ///      itself an ERC4626 vault — it exposes a separate `supply` / `withdraw` API and
    ///      returns rebasing aTokens rather than fixed-ratio shares.
    /// @param user       The user on whose behalf USDC is deposited; receives shares/aTokens.
    /// @param vault      Whitelisted vault address or `aavePool`.
    /// @param usdcAmount Amount of USDC to pull from `user` and deposit (6 decimals).
    function deposit(
        address user,
        address vault,
        uint256 usdcAmount
    ) external onlyOwner nonReentrant {
        if (user == address(0)) revert ZeroAddress();
        if (!approvedVaults[vault]) revert VaultNotApproved(vault);
        if (usdcAmount == 0) revert ZeroAmount();

        usdc.safeTransferFrom(user, address(this), usdcAmount);

        if (vault == aavePool) {
            usdc.forceApprove(aavePool, usdcAmount);
            IPool(aavePool).supply(address(usdc), usdcAmount, user, 0);
            emit Deposited(user, vault, usdcAmount, usdcAmount); // aTokens ~1:1
        } else {
            usdc.forceApprove(vault, usdcAmount);
            uint256 sharesReceived = IERC4626(vault).deposit(usdcAmount, user);
            emit Deposited(user, vault, usdcAmount, sharesReceived);
        }
    }

    // -------------------------------------------------------------------------
    // Internal: Performance fee extraction
    // -------------------------------------------------------------------------

    /// @dev Transfer vault shares from `user` to this contract as a performance fee.
    ///      Only ERC4626 (Morpho) vaults are supported here — Aave fees use aUSDC and
    ///      are handled inline by `selfBatchWithdraw`. Each fee vault must be whitelisted.
    ///      `feeVaults` may contain vaults unrelated to the current `fromVault`/`toVault`
    ///      pair — the executor collects fees from ALL strategy vaults with accrued yield
    ///      in a single call to amortise gas. Reverts if array lengths differ.
    ///      Emits `PerformanceFeeCollected` if at least one fee entry is present.
    function _collectFees(
        address user,
        address[] calldata feeVaults,
        uint256[] calldata feeAmounts
    ) internal {
        if (feeVaults.length != feeAmounts.length) revert ArrayLengthMismatch();
        if (feeVaults.length == 0) return;
        for (uint256 i = 0; i < feeVaults.length; i++) {
            if (!approvedVaults[feeVaults[i]]) revert VaultNotApproved(feeVaults[i]);
            IERC20(feeVaults[i]).safeTransferFrom(user, address(this), feeAmounts[i]);
            heldFeeShares[feeVaults[i]] += feeAmounts[i];
        }
        emit PerformanceFeeCollected(user, feeVaults, feeAmounts);
    }

    // -------------------------------------------------------------------------
    // Owner-only: Rebalancing
    // -------------------------------------------------------------------------

    /// @notice Atomically move a user's position from one vault to another.
    /// @dev Flow:
    ///      1. Validate fee array lengths.
    ///      2. Collect performance fee shares from user (may span multiple vaults).
    ///      3. Pull `shares` from `fromVault` and redeem to USDC.
    ///      4. Deposit full USDC amount into `toVault` on behalf of `user`.
    ///      Pass empty arrays for `feeVaults`/`feeAmounts` to perform a no-fee rebalance.
    ///      The user must have pre-approved this contract to spend their `fromVault` token
    ///      (ERC4626 shares or aUSDC) and any fee vault tokens before the rebalancer calls this.
    /// @param user       The user whose position is being rebalanced.
    /// @param fromVault  The vault to withdraw from. Must be whitelisted and differ from `toVault`.
    /// @param toVault    The vault to deposit into. Must be whitelisted and differ from `fromVault`.
    /// @param shares     ERC4626 shares (Morpho) or aUSDC amount (Aave) to move.
    /// @param feeVaults  Vault addresses from which to collect performance fee shares.
    ///                   May be empty (no fee) or contain vaults outside the rebalance pair.
    /// @param feeAmounts Corresponding share amounts to collect from each vault in `feeVaults`.
    function rebalance(
        address user,
        address fromVault,
        address toVault,
        uint256 shares,
        address[] calldata feeVaults,
        uint256[] calldata feeAmounts
    ) external onlyOwner nonReentrant {
        if (user == address(0)) revert ZeroAddress();
        if (!approvedVaults[fromVault]) revert VaultNotApproved(fromVault);
        if (!approvedVaults[toVault])   revert VaultNotApproved(toVault);
        if (fromVault == toVault) revert InvalidInput();
        if (shares == 0) revert ZeroAmount();

        // --- Performance fee extraction (vault shares, before withdrawal) ---
        _collectFees(user, feeVaults, feeAmounts);

        // --- Withdrawal leg ---
        uint256 usdcReceived;
        if (fromVault == aavePool) {
            IERC20(aUsdc).safeTransferFrom(user, address(this), shares);
            usdcReceived = IPool(aavePool).withdraw(address(usdc), shares, address(this));
        } else {
            IERC20(fromVault).safeTransferFrom(user, address(this), shares);
            usdcReceived = IERC4626(fromVault).redeem(shares, address(this), address(this));
        }

        // --- Deposit leg (full amount — fees already taken as shares) ---
        if (toVault == aavePool) {
            usdc.forceApprove(aavePool, usdcReceived);
            IPool(aavePool).supply(address(usdc), usdcReceived, user, 0);
        } else {
            usdc.forceApprove(toVault, usdcReceived);
            IERC4626(toVault).deposit(usdcReceived, user);
        }

        emit Rebalanced(user, fromVault, toVault, shares, usdcReceived);
    }

    // -------------------------------------------------------------------------
    // Owner-only: Atomic withdraw + CCTP burn
    // -------------------------------------------------------------------------

    /// @notice Atomically withdraw from a vault and burn USDC cross-chain via CCTP V2.
    /// @dev USDC only exists in this contract for the duration of the single transaction —
    ///      it is withdrawn from the vault and immediately burned by the TokenMessenger.
    ///      A low-level `call` is used instead of a typed interface call because some
    ///      CCTP deployments are behind upgradeable proxies whose return-value encoding
    ///      differs from the ABI; a direct interface call would revert on return-data
    ///      decoding even when the underlying call succeeds.
    ///      Setting `destinationCaller` to `address(this)` (as bytes32) on the destination
    ///      chain means only _this_ contract can relay, which prevents MEV bots from
    ///      front-running the relay and stealing the minted USDC.
    ///      Performance fees are collected as vault shares before the withdrawal.
    /// @param user                  The user whose vault position is bridged.
    /// @param vault                 The vault to withdraw from. Must be whitelisted.
    /// @param shares                ERC4626 shares (Morpho) or aUSDC amount (Aave) to redeem.
    /// @param feeVaults             Vault addresses from which to collect performance fee shares.
    /// @param feeAmounts            Corresponding share amounts to collect from each vault in `feeVaults`.
    /// @param tokenMessenger        CCTP V2 TokenMessenger contract address.
    /// @param destDomain            CCTP destination domain ID (e.g. 6 = Base, 0 = Ethereum).
    /// @param mintRecipient         bytes32-padded address to receive minted USDC on dest chain.
    /// @param destinationCaller     bytes32-padded address permitted to relay on dest chain.
    ///                              Set to `address(0)` to allow anyone to relay (no MEV protection).
    /// @param maxFee                Maximum fee the CCTP protocol may charge (0 for standard).
    /// @param minFinalityThreshold  0 = fast finality (seconds), 2000 = standard finality (full chain finality).
    /// @return netUsdc              USDC burned via CCTP.
    function withdrawAndBridge(
        address user,
        address vault,
        uint256 shares,
        address[] calldata feeVaults,
        uint256[] calldata feeAmounts,
        address tokenMessenger,
        uint32  destDomain,
        bytes32 mintRecipient,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32  minFinalityThreshold
    ) external onlyOwner nonReentrant returns (uint256 netUsdc) {
        if (user == address(0)) revert ZeroAddress();
        if (!approvedVaults[vault]) revert VaultNotApproved(vault);
        if (shares == 0) revert ZeroAmount();
        if (tokenMessenger == address(0)) revert ZeroAddress();

        // --- Performance fee extraction (vault shares, before withdrawal) ---
        _collectFees(user, feeVaults, feeAmounts);

        // --- Withdrawal ---
        if (vault == aavePool) {
            IERC20(aUsdc).safeTransferFrom(user, address(this), shares);
            netUsdc = IPool(aavePool).withdraw(address(usdc), shares, address(this));
        } else {
            IERC20(vault).safeTransferFrom(user, address(this), shares);
            netUsdc = IERC4626(vault).redeem(shares, address(this), address(this));
        }

        // --- CCTP burn (low-level call to avoid proxy return-value revert) ---
        usdc.forceApprove(tokenMessenger, netUsdc);

        (bool success, ) = tokenMessenger.call(
            abi.encodeWithSelector(
                ITokenMessengerV2.depositForBurn.selector,
                netUsdc,
                destDomain,
                mintRecipient,
                address(usdc),
                destinationCaller,
                maxFee,
                minFinalityThreshold
            )
        );
        if (!success) revert CctpBurnFailed();

        emit BridgeInitiated(user, vault, shares, netUsdc, destDomain);
    }

    // -------------------------------------------------------------------------
    // Owner-only: Atomic relay + deposit (single transaction)
    // -------------------------------------------------------------------------

    /// @notice Atomically relay a CCTP V2 message and deposit the minted USDC into a vault.
    /// @dev Flow:
    ///      1. Snapshot USDC balance of this contract before the relay.
    ///      2. Call `IMessageTransmitter.receiveMessage` — Circle's contract mints USDC
    ///         directly to this contract's address.
    ///      3. Compute minted amount from the balance delta (avoids trusting the relay return value).
    ///      4. Deposit the full minted amount into `vault` on behalf of `user`.
    ///      The balance-delta pattern is used rather than reading the relay return value because
    ///      CCTP's `receiveMessage` returns a bool, not the minted amount, and off-by-one USDC
    ///      from accumulated fees would otherwise be deposited.
    ///      Setting `destinationCaller = address(this)` (as bytes32) at burn time on the source
    ///      chain means only this contract can relay — this is the recommended MEV-protection
    ///      pattern for atomic relay+deposit, eliminating the need for a second rebalancer tx.
    /// @param message     Raw CCTP V2 message bytes emitted from the source-chain burn event.
    /// @param attestation Circle attestation signature authorising the relay.
    /// @param user        The user who will receive vault shares or aTokens.
    /// @param vault       Whitelisted destination vault or `aavePool`.
    function relayAndDeposit(
        bytes calldata message,
        bytes calldata attestation,
        address user,
        address vault
    ) external onlyOwner nonReentrant {
        if (user == address(0)) revert ZeroAddress();
        if (!approvedVaults[vault]) revert VaultNotApproved(vault);
        if (messageTransmitter == address(0)) revert ZeroAddress();

        // Step 1: Snapshot USDC balance before relay
        uint256 before = usdc.balanceOf(address(this));

        // Step 2: Relay the CCTP message — USDC minted to this contract
        bool success = IMessageTransmitter(messageTransmitter).receiveMessage(message, attestation);
        if (!success) revert MessageRelayFailed();

        // Step 3: Compute minted amount from balance delta
        uint256 amount = usdc.balanceOf(address(this)) - before;
        if (amount == 0) revert ZeroAmount();

        // Step 4: Deposit minted USDC into vault on behalf of user
        if (vault == aavePool) {
            usdc.forceApprove(aavePool, amount);
            IPool(aavePool).supply(address(usdc), amount, user, 0);
            emit DepositedFromBridge(user, vault, amount, amount);
        } else {
            usdc.forceApprove(vault, amount);
            uint256 sharesReceived = IERC4626(vault).deposit(amount, user);
            emit DepositedFromBridge(user, vault, amount, sharesReceived);
        }
    }

    /// @notice Relay a CCTP message, then split the minted USDC across multiple vaults.
    /// @dev Used when a single bridge burn aggregates capital destined for multiple vaults
    ///      on this chain. The relayer calls this instead of relayAndDeposit when dest_vaults
    ///      contains more than one entry.
    function relayAndBatchDeposit(
        bytes calldata message,
        bytes calldata attestation,
        address user,
        address[] calldata vaults,
        uint256[] calldata amounts
    ) external onlyOwner nonReentrant {
        if (user == address(0)) revert ZeroAddress();
        if (vaults.length != amounts.length) revert InvalidInput();
        if (vaults.length == 0) revert InvalidInput();
        if (messageTransmitter == address(0)) revert ZeroAddress();

        for (uint256 i = 0; i < vaults.length; i++) {
            if (!approvedVaults[vaults[i]]) revert VaultNotApproved(vaults[i]);
            if (amounts[i] == 0) revert ZeroAmount();
        }

        // Step 1: Snapshot USDC balance before relay
        uint256 before = usdc.balanceOf(address(this));

        // Step 2: Relay the CCTP message — USDC minted to this contract
        bool success = IMessageTransmitter(messageTransmitter).receiveMessage(message, attestation);
        if (!success) revert MessageRelayFailed();

        // Step 3: Verify minted amount covers all allocations
        uint256 minted = usdc.balanceOf(address(this)) - before;
        uint256 totalNeeded = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalNeeded += amounts[i];
        }
        if (minted < totalNeeded) revert ZeroAmount();

        // Step 4: Deposit into each vault on behalf of user
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i] == aavePool) {
                usdc.forceApprove(aavePool, amounts[i]);
                IPool(aavePool).supply(address(usdc), amounts[i], user, 0);
                emit DepositedFromBridge(user, vaults[i], amounts[i], amounts[i]);
            } else {
                usdc.forceApprove(vaults[i], amounts[i]);
                uint256 sharesReceived = IERC4626(vaults[i]).deposit(amounts[i], user);
                emit DepositedFromBridge(user, vaults[i], amounts[i], sharesReceived);
            }
        }
    }

    // -------------------------------------------------------------------------
    // User-callable: Batch Deposits
    // -------------------------------------------------------------------------

    /// @notice Deposit USDC from `msg.sender` into multiple vaults and optionally burn
    ///         USDC cross-chain via CCTP V2, all in one transaction.
    /// @dev User-callable (no `onlyOwner`). Uses `msg.sender` as the depositor,
    ///      allowing users to initiate their own deposits and pay their own gas.
    ///      The user must have pre-approved this contract to spend at least
    ///      `sum(amounts) + sum(burns[i].amount)` USDC before calling.
    ///      Works for both Morpho ERC4626 vaults and the Aave V3 Pool.
    ///      When `burns` is empty, behaves identically to a single-chain deposit.
    ///      When `burns` is non-empty, executes CCTP V2 `depositForBurn` for each entry,
    ///      burning USDC on the source chain so it can be minted on the destination chain.
    ///      The relayer picks up the burns and calls `relayAndDeposit` on the dest chain.
    ///      Emits `StrategyCreated` at the end with total USDC (local + bridged).
    /// @param vaults  Ordered list of vault addresses on the source chain. Each must be whitelisted.
    ///                May be empty if all capital is bridged.
    /// @param amounts USDC amounts corresponding 1:1 with `vaults`. Each must be > 0.
    /// @param burns   Array of CCTP burn parameters for cross-chain deposits.
    ///                May be empty for single-chain deposits.
    function selfBatchDeposit(
        address[] calldata vaults,
        uint256[] calldata amounts,
        BridgeBurn[] calldata burns
    ) external nonReentrant {
        if (vaults.length != amounts.length) revert InvalidInput();
        if (vaults.length == 0 && burns.length == 0) revert InvalidInput();

        // Validate all vaults and compute total USDC needed
        uint256 total = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            if (!approvedVaults[vaults[i]]) revert VaultNotApproved(vaults[i]);
            if (amounts[i] == 0) revert ZeroAmount();
            total += amounts[i];
        }
        for (uint256 i = 0; i < burns.length; i++) {
            if (burns[i].amount == 0) revert ZeroAmount();
            if (burns[i].tokenMessenger == address(0)) revert ZeroAddress();
            total += burns[i].amount;
        }

        // Pull total USDC from msg.sender in one transfer
        usdc.safeTransferFrom(msg.sender, address(this), total);

        // Deposit into each local vault
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i] == aavePool) {
                usdc.forceApprove(aavePool, amounts[i]);
                IPool(aavePool).supply(address(usdc), amounts[i], msg.sender, 0);
                emit Deposited(msg.sender, vaults[i], amounts[i], amounts[i]);
            } else {
                usdc.forceApprove(vaults[i], amounts[i]);
                uint256 sharesReceived = IERC4626(vaults[i]).deposit(amounts[i], msg.sender);
                emit Deposited(msg.sender, vaults[i], amounts[i], sharesReceived);
            }
        }

        // Execute CCTP burns for cross-chain deposits
        for (uint256 i = 0; i < burns.length; i++) {
            usdc.forceApprove(burns[i].tokenMessenger, burns[i].amount);

            (bool success, ) = burns[i].tokenMessenger.call(
                abi.encodeWithSelector(
                    ITokenMessengerV2.depositForBurn.selector,
                    burns[i].amount,
                    burns[i].destDomain,
                    burns[i].mintRecipient,
                    address(usdc),
                    burns[i].destinationCaller,
                    burns[i].maxFee,
                    burns[i].minFinalityThreshold
                )
            );
            if (!success) revert CctpBurnFailed();

            emit BridgeBurnInitiated(msg.sender, burns[i].amount, burns[i].destDomain, burns[i].mintRecipient);
        }

        emit StrategyCreated(msg.sender, total);
    }

    // -------------------------------------------------------------------------
    // User-callable: Batch Withdrawal (strategy closing)
    // -------------------------------------------------------------------------

    /// @notice Close all vault positions and withdraw USDC to caller.
    /// @dev User-callable (no owner required). Uses msg.sender throughout.
    ///      `shares[i]` is the GROSS share amount (fee + net). The contract
    ///      withholds `feeAmounts[i]` shares as a performance fee and redeems
    ///      the remainder to msg.sender as USDC.
    ///      `feeAmounts[i]` must be < `shares[i]`. Pass 0 for vaults with no fee.
    ///      Vaults where the effective amount resolves to zero are silently skipped.
    ///      Aave path: `shares[i]` is treated as aUSDC amount. Fee shares for Aave are
    ///      tracked under the `aUsdc` token address in `heldFeeShares` (not `aavePool`).
    ///      When `burns` is non-empty, redeemed USDC is accumulated in the contract and
    ///      burned via CCTP to bridge back to the user's source chain. Any remainder
    ///      after burns is transferred to msg.sender. Pass `type(uint256).max` as
    ///      `burns[i].amount` to burn all redeemed USDC (recommended for close flows).
    /// @param vaults     Vault addresses to withdraw from. Each must be whitelisted.
    /// @param shares     Gross share amounts per vault (0 = full balance).
    /// @param feeAmounts Fee share amounts per vault, aligned with `vaults`. 0 = no fee.
    /// @param burns      Array of CCTP burn parameters for cross-chain bridge-back.
    ///                   May be empty for single-chain withdrawals.
    function selfBatchWithdraw(
        address[] calldata vaults,
        uint256[] calldata shares,
        uint256[] calldata feeAmounts,
        BridgeBurn[] calldata burns
    ) external nonReentrant {
        if (vaults.length == 0 || shares.length != vaults.length) revert InvalidInput();
        if (feeAmounts.length != vaults.length) revert ArrayLengthMismatch();

        // When burns are present, USDC goes to the contract first (for CCTP burn).
        // When burns are empty, USDC goes directly to the user (existing behavior).
        bool hasBurns = burns.length > 0;
        address usdcRecipient = hasBurns ? address(this) : msg.sender;
        uint256 preBalance = hasBurns ? usdc.balanceOf(address(this)) : 0;

        address[] memory feeVaultsEmitted = new address[](vaults.length);
        uint256[] memory feeAmountsEmitted = new uint256[](vaults.length);
        uint256 feeCount = 0;

        for (uint256 i = 0; i < vaults.length; i++) {
            address vault = vaults[i];
            if (!approvedVaults[vault]) revert VaultNotApproved(vault);

            if (vault == aavePool) {
                uint256 amt = shares[i] > 0 ? shares[i] : IERC20(aUsdc).balanceOf(msg.sender);
                if (amt == 0) continue;
                IERC20(aUsdc).safeTransferFrom(msg.sender, address(this), amt);
                uint256 feeAmt = feeAmounts[i];
                if (feeAmt > 0) {
                    if (feeAmt >= amt) revert InvalidInput();
                    heldFeeShares[aUsdc] += feeAmt;
                    amt -= feeAmt;
                    feeVaultsEmitted[feeCount] = aUsdc;
                    feeAmountsEmitted[feeCount] = feeAmt;
                    feeCount++;
                }
                uint256 usdcReceived = IPool(aavePool).withdraw(address(usdc), amt, usdcRecipient);
                emit StrategyExited(msg.sender, vault, amt, usdcReceived);
            } else {
                uint256 amt = shares[i] > 0 ? shares[i] : IERC20(vault).balanceOf(msg.sender);
                if (amt == 0) continue;
                IERC20(vault).safeTransferFrom(msg.sender, address(this), amt);
                uint256 feeAmt = feeAmounts[i];
                if (feeAmt > 0) {
                    if (feeAmt >= amt) revert InvalidInput();
                    heldFeeShares[vault] += feeAmt;
                    amt -= feeAmt;
                    feeVaultsEmitted[feeCount] = vault;
                    feeAmountsEmitted[feeCount] = feeAmt;
                    feeCount++;
                }
                uint256 usdcReceived = IERC4626(vault).redeem(amt, usdcRecipient, address(this));
                emit StrategyExited(msg.sender, vault, amt, usdcReceived);
            }
        }

        if (feeCount > 0) {
            address[] memory fv = new address[](feeCount);
            uint256[] memory fa = new uint256[](feeCount);
            for (uint256 i = 0; i < feeCount; i++) { fv[i] = feeVaultsEmitted[i]; fa[i] = feeAmountsEmitted[i]; }
            emit PerformanceFeeCollected(msg.sender, fv, fa);
        }

        // Execute CCTP burns for cross-chain bridge-back
        if (hasBurns) {
            uint256 netUsdc = usdc.balanceOf(address(this)) - preBalance;

            for (uint256 i = 0; i < burns.length; i++) {
                if (burns[i].tokenMessenger == address(0)) revert ZeroAddress();
                uint256 burnAmount = burns[i].amount == type(uint256).max ? netUsdc : burns[i].amount;
                if (burnAmount == 0) revert ZeroAmount();
                if (burnAmount > netUsdc) revert InvalidInput();

                usdc.forceApprove(burns[i].tokenMessenger, burnAmount);

                (bool success, ) = burns[i].tokenMessenger.call(
                    abi.encodeWithSelector(
                        ITokenMessengerV2.depositForBurn.selector,
                        burnAmount,
                        burns[i].destDomain,
                        burns[i].mintRecipient,
                        address(usdc),
                        burns[i].destinationCaller,
                        burns[i].maxFee,
                        burns[i].minFinalityThreshold
                    )
                );
                if (!success) revert CctpBurnFailed();

                emit BridgeBurnInitiated(msg.sender, burnAmount, burns[i].destDomain, burns[i].mintRecipient);
                netUsdc -= burnAmount;
            }

            // Send any remainder to the user
            if (netUsdc > 0) {
                usdc.safeTransfer(msg.sender, netUsdc);
            }
        }
    }

    // -------------------------------------------------------------------------
    // Owner-only: Fee management
    // -------------------------------------------------------------------------

    /// @notice Sweep a specific amount of an ERC20 token to the owner.
    /// @dev Use this to drain accumulated vault share fees tracked in `heldFeeShares`,
    ///      or to recover accidentally sent tokens. Decrements `heldFeeShares` bookkeeping
    ///      by up to `amount` (capped at the tracked balance to avoid underflow).
    /// @param token  The ERC20 token to sweep.
    /// @param amount The amount to transfer to the owner.
    function sweep(address token, uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        uint256 held = heldFeeShares[token];
        heldFeeShares[token] = held > amount ? held - amount : 0;
        IERC20(token).safeTransfer(owner(), amount);
        emit FeeSwept(token, owner(), amount);
    }

    // -------------------------------------------------------------------------
    // UUPS upgrade authorization
    // -------------------------------------------------------------------------

    /// @dev Only the owner can authorize an implementation upgrade.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @notice Return the full list of currently whitelisted vault addresses.
    /// @return Array of approved vault addresses (may include `aavePool`).
    function getApprovedVaults() external view returns (address[] memory) {
        return vaultList;
    }

    /// @notice Check whether a specific vault address is currently whitelisted.
    /// @param vault The address to query.
    /// @return True if the vault is approved, false otherwise.
    function isVaultApproved(address vault) external view returns (bool) {
        return approvedVaults[vault];
    }
}

