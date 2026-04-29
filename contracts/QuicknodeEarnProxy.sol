// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @dev Minimal CCTP V2 MessageTransmitter interface for relaying messages
interface IMessageTransmitter {
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool);
}

/// @dev Minimal CCTP V2 TokenMessenger interface for cross-chain burns
interface ITokenMessengerV2 {
    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external returns (bytes32);
}

/// @notice Parameters for a single CCTP V2 cross-chain burn within `selfBatchDeposit`
///         and `selfBatchWithdraw` (bridge-back on close).
/// @dev All fields are value types so the struct is calldata-safe.
struct BridgeBurn {
    uint32  destDomain;           // CCTP destination domain (e.g. 6 = Base, 15 = Monad)
    bytes32 mintRecipient;        // bytes32-padded address to receive minted USDC on dest chain
    bytes32 destinationCaller;    // bytes32-padded address permitted to relay on dest chain (MEV protection)
    uint256 amount;               // USDC amount to burn for this destination
    uint256 maxFee;               // Maximum fee the CCTP protocol may charge (0 for standard)
    uint32  minFinalityThreshold; // 0 = fast finality (seconds), 2000 = standard finality (full chain finality)
}

/// @title QuicknodeEarnProxy
/// @notice Non-custodial yield-optimiser that moves user funds between whitelisted
///         ERC4626 vaults (Morpho) to maximise supply APY.
///         UUPS-upgradeable variant — deploy an ERC1967 proxy pointing at this
///         implementation and call `initialize()` once through the proxy.
/// @dev Architecture overview:
///      - Users retain full custody: they grant ERC20 approvals to this contract but
///        never transfer principal in; all vault shares are held by the user.
///      - Three privileged roles:
///        - **Owner** (multisig): vault whitelist, fee sweeps, role assignment.
///        - **Executor**: calls `rebalance` and `withdrawAndBridge` to move capital.
///        - **Relayer**: calls `relayAndDeposit` to relay CCTP messages and deposit.
///      - Users can create strategies via `selfBatchDeposit` and close them via
///        `selfBatchWithdraw` without owner involvement.
///      - Fee model: a performance fee is collected as vault shares (not USDC). The executor
///        computes 15% of yield earned across ALL strategy vaults, converts each to vault
///        shares, and passes them as `feeVaults[]`/`feeAmounts[]` on rebalance/withdraw
///        calls. The contract transfers those shares from the user to itself. The owner
///        sweeps accumulated fee tokens via `sweep()`.
///        Fee arrays may be empty (no-fee rebalance) or contain vaults unrelated to the
///        current `fromVault`/`toVault` pair — the executor collects from ALL vaults with
///        accrued yield in a single operation.
///      - Vault whitelist: only addresses in `approvedVaults` may receive deposits. This
///        prevents the owner from draining users into arbitrary contracts.
///      - Two-step ownership (`Ownable2StepUpgradeable`) prevents accidental ownership transfer to
///        an uncontrolled address.
///      - CCTP V2 integration: `withdrawAndBridge` burns USDC cross-chain after a
///        vault withdrawal; `relayAndDeposit` relays a CCTP message and atomically
///        deposits on the destination chain; `selfBatchDeposit` and `selfBatchWithdraw`
///        accept optional `BridgeBurn[]` arrays for cross-chain deposits and bridge-back
///        on close.
///      - `selfBatchDeposit` and `selfBatchWithdraw` are deliberately user-callable
///        with no owner requirement, providing a trustless exit path independent of
///        the rebalancer.
///      - UUPS: only the owner may authorise an upgrade (`_authorizeUpgrade`).
///        The implementation's constructor calls `_disableInitializers()` to prevent
///        direct initialisation of the implementation contract itself.
///      - All mutable state lives in ERC-7201 namespaced storage. Parents have no
///        persistent storage that could collide: Ownable2StepUpgradeable is on an
///        ERC-7201 namespaced layout, and ReentrancyGuardTransient uses transient
///        storage (EIP-1153 TSTORE/TLOAD) so it has no persistent slots at all.
///        No parent or child slot is sequential, so adds and reorders in any of them
///        cannot shift another contract's slots.
contract QuicknodeEarnProxy is Ownable2StepUpgradeable, ReentrancyGuardTransient, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // ERC-7201 namespaced storage
    // -------------------------------------------------------------------------

    /// @custom:storage-location erc7201:quicknode.earn.storage
    struct EarnStorage {
        mapping(address => bool) approvedVaults;
        address[] vaultList;
        address executor;
        address relayer;
    }

    // keccak256(abi.encode(uint256(keccak256("quicknode.earn.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EARN_STORAGE_LOCATION = 0xa4cde844567bd426696e28bbfd17699530d36b5e6952a4ce0ac418703884c900;

    function _getEarnStorage() private pure returns (EarnStorage storage $) {
        assembly { $.slot := EARN_STORAGE_LOCATION }
    }

    // -------------------------------------------------------------------------
    // Immutables (stored in implementation bytecode, not proxy storage)
    // -------------------------------------------------------------------------

    /// @notice The USDC token this contract operates on.
    IERC20  public immutable usdc;

    /// @notice Preserved for ABI backwards compatibility with the previously deployed
    ///         implementation. Aave integration has been removed; always `address(0)`
    ///         in new deployments.
    address public immutable aavePool;

    /// @notice Preserved for ABI backwards compatibility with the previously deployed
    ///         implementation. Aave integration has been removed; always `address(0)`
    ///         in new deployments.
    address public immutable aUsdc;

    /// @notice The CCTP V2 MessageTransmitter address for relaying bridge messages.
    ///         `address(0)` disables CCTP relay functionality (`relayAndDeposit` reverts).
    address public immutable messageTransmitter;

    /// @notice The CCTP V2 TokenMessenger address for initiating cross-chain USDC burns.
    ///         `address(0)` disables all CCTP burn paths (`withdrawAndBridge`, `selfBatchDeposit`
    ///         with burns, and `selfBatchWithdraw` with burns will revert).
    address public immutable tokenMessenger;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when the executor address is updated.
    /// @param oldExecutor The previous executor address.
    /// @param newExecutor The new executor address.
    event ExecutorUpdated(address indexed oldExecutor, address indexed newExecutor);

    /// @notice Emitted when the relayer address is updated.
    /// @param oldRelayer The previous relayer address.
    /// @param newRelayer The new relayer address.
    event RelayerUpdated(address indexed oldRelayer, address indexed newRelayer);

    /// @notice Emitted when a vault is added to the whitelist.
    /// @param vault The address of the newly approved vault.
    event VaultAdded(address indexed vault);

    /// @notice Emitted when a vault is removed from the whitelist.
    /// @param vault The address of the vault that was de-listed.
    event VaultRemoved(address indexed vault);

    /// @notice Emitted after a successful single-vault deposit.
    /// @param user            The user who owns the resulting vault shares.
    /// @param vault           The ERC4626 vault that received USDC.
    /// @param usdcAmount      USDC deposited (6 decimals).
    /// @param sharesReceived  Vault shares minted.
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
    /// @param shares     ERC4626 shares pulled from `fromVault`.
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
    /// @param shares      Net ERC4626 shares redeemed after fee deduction.
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
    /// @param shares     ERC4626 shares redeemed.
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
    /// @param sharesReceived ERC4626 shares minted.
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

    /// @notice Thrown when a non-executor address calls an executor-only function.
    error UnauthorizedExecutor();

    /// @notice Thrown when a non-relayer address calls a relayer-only function.
    error UnauthorizedRelayer();

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

    /// @notice Thrown when the low-level call to the CCTP TokenMessenger's `depositForBurnWithHook` fails.
    error CctpBurnFailed();

    /// @notice Thrown when the CCTP `receiveMessage` relay call returns false.
    error MessageRelayFailed();

    /// @notice Thrown when `relayAndDeposit`'s `user` parameter does not match the
    ///         beneficiary committed in the CCTP message's hookData at burn time.
    error InvalidUser();

    /// @notice Thrown when `emergencyClaimBridge` is called by an address other than the
    ///         hookData beneficiary committed at burn time.
    error Unauthorized();

    /// @notice Emitted when a user claims a bridged CCTP burn directly via
    ///         `emergencyClaimBridge`, bypassing the relayer.
    /// @param user   The hookData beneficiary who claimed the bridge.
    /// @param amount USDC amount delivered to the beneficiary's wallet.
    event BridgeClaimed(address indexed user, uint256 amount);

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    /// @dev Restricts a function to the designated executor address.
    modifier onlyExecutor() {
        if (msg.sender != _getEarnStorage().executor) revert UnauthorizedExecutor();
        _;
    }

    /// @dev Restricts a function to the designated relayer address.
    modifier onlyRelayer() {
        if (msg.sender != _getEarnStorage().relayer) revert UnauthorizedRelayer();
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor + Initializer
    // -------------------------------------------------------------------------

    /// @notice Set immutable chain-specific addresses and disable initializers on the
    ///         implementation contract itself.
    /// @dev Called once at deployment of the implementation. The proxy delegates all
    ///      calls (including `initialize`) to this contract, so this constructor only
    ///      runs against the implementation's own storage — not the proxy's.
    ///      Pass `address(0)` for `_messageTransmitter` on chains where CCTP is not
    ///      available. `_aavePool` and `_aUsdc` are preserved for ABI backwards
    ///      compatibility — pass `address(0)` for both in new deployments.
    /// @param _usdc               USDC token address.
    /// @param _aavePool           Deprecated (Aave removed). Pass `address(0)`.
    /// @param _aUsdc              Deprecated (Aave removed). Pass `address(0)`.
    /// @param _messageTransmitter CCTP V2 MessageTransmitter; `address(0)` disables relay.
    /// @param _tokenMessenger     CCTP V2 TokenMessenger; `address(0)` disables CCTP burns.
    constructor(
        address _usdc,
        address _aavePool,
        address _aUsdc,
        address _messageTransmitter,
        address _tokenMessenger
    ) {
        if (_usdc == address(0)) revert ZeroAddress();

        usdc               = IERC20(_usdc);
        aavePool           = _aavePool;
        aUsdc              = _aUsdc;
        messageTransmitter = _messageTransmitter;
        tokenMessenger     = _tokenMessenger;

        _disableInitializers();
    }

    /// @notice Initialise the proxy — sets the owner and seeds the vault whitelist.
    /// @dev Must be called exactly once, through the proxy, immediately after deployment.
    ///      Protected by the `initializer` modifier from `Initializable`.
    /// @param _owner         Initial owner. Receives all owner privileges.
    /// @param _initialVaults Optional list of vaults to whitelist atomically.
    ///                       Duplicates and zero addresses are silently skipped.
    function initialize(address _owner, address[] calldata _initialVaults) external initializer {
        if (_owner == address(0)) revert ZeroAddress();

        __Ownable_init(_owner);
        __Ownable2Step_init();

        EarnStorage storage $ = _getEarnStorage();
        for (uint256 i = 0; i < _initialVaults.length; i++) {
            address vault = _initialVaults[i];
            if (vault != address(0) && !$.approvedVaults[vault]) {
                $.approvedVaults[vault] = true;
                $.vaultList.push(vault);
                emit VaultAdded(vault);
            }
        }
    }

    // -------------------------------------------------------------------------
    // UUPS: Upgrade authorisation
    // -------------------------------------------------------------------------

    /// @dev Only the owner may authorise a contract upgrade.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // -------------------------------------------------------------------------
    // Owner-only: Vault management
    // -------------------------------------------------------------------------

    /// @notice Add a single vault to the whitelist.
    /// @dev Idempotent: re-adding an already-approved vault is a no-op (no duplicate in `vaultList`).
    /// @param vault The vault address to whitelist. Must not be `address(0)`.
    function addVault(address vault) external onlyOwner {
        if (vault == address(0)) revert ZeroAddress();
        EarnStorage storage $ = _getEarnStorage();
        if (!$.approvedVaults[vault]) {
            $.approvedVaults[vault] = true;
            $.vaultList.push(vault);
            emit VaultAdded(vault);
        }
    }

    /// @notice Add multiple vaults to the whitelist in one transaction.
    /// @dev Each element is validated and silently skipped if already approved.
    ///      Reverts if any element is `address(0)`.
    /// @param vaults Array of vault addresses to whitelist.
    function batchAddVaults(address[] calldata vaults) external onlyOwner {
        EarnStorage storage $ = _getEarnStorage();
        for (uint256 i = 0; i < vaults.length; i++) {
            address vault = vaults[i];
            if (vault == address(0)) revert ZeroAddress();
            if (!$.approvedVaults[vault]) {
                $.approvedVaults[vault] = true;
                $.vaultList.push(vault);
                emit VaultAdded(vault);
            }
        }
    }

    /// @notice Remove a vault from the whitelist.
    /// @dev Uses a swap-and-pop on `vaultList` for O(n) removal; order is not preserved.
    ///      Reverts if `vault` is not currently approved.
    /// @param vault The vault address to de-list.
    function removeVault(address vault) external onlyOwner {
        EarnStorage storage $ = _getEarnStorage();
        if (!$.approvedVaults[vault]) revert VaultNotApproved(vault);
        $.approvedVaults[vault] = false;

        // Remove from vaultList array (swap-and-pop, does not preserve order)
        uint256 len = $.vaultList.length;
        for (uint256 i = 0; i < len; i++) {
            if ($.vaultList[i] == vault) {
                $.vaultList[i] = $.vaultList[len - 1];
                $.vaultList.pop();
                break;
            }
        }

        emit VaultRemoved(vault);
    }

    // -------------------------------------------------------------------------
    // Owner-only: Role management
    // -------------------------------------------------------------------------

    /// @notice Set the executor address permitted to call `rebalance` and `withdrawAndBridge`.
    /// @param _executor The new executor address. Use `address(0)` to revoke.
    function setExecutor(address _executor) external onlyOwner {
        EarnStorage storage $ = _getEarnStorage();
        address old = $.executor;
        $.executor = _executor;
        emit ExecutorUpdated(old, _executor);
    }

    /// @notice Set the relayer address permitted to call `relayAndDeposit`.
    /// @param _relayer The new relayer address. Use `address(0)` to revoke.
    function setRelayer(address _relayer) external onlyOwner {
        EarnStorage storage $ = _getEarnStorage();
        address old = $.relayer;
        $.relayer = _relayer;
        emit RelayerUpdated(old, _relayer);
    }

    // -------------------------------------------------------------------------
    // Internal: Performance fee extraction
    // -------------------------------------------------------------------------

    /// @dev Transfer fee shares from the user to this contract for each fee vault.
    ///      Every fee vault must be in `approvedVaults`.
    function _collectFees(
        address user,
        address[] calldata feeVaults,
        uint256[] calldata feeAmounts
    ) internal {
        if (feeVaults.length == 0) return;
        EarnStorage storage $ = _getEarnStorage();
        for (uint256 i = 0; i < feeVaults.length; i++) {
            address fv = feeVaults[i];
            if (fv == address(0)) revert ZeroAddress();
            if (!$.approvedVaults[fv]) revert VaultNotApproved(fv);
            IERC20(fv).safeTransferFrom(user, address(this), feeAmounts[i]);
        }
        emit PerformanceFeeCollected(user, feeVaults, feeAmounts);
    }

    /// @dev Deposit USDC into an ERC4626 vault on behalf of `user`.
    function _depositToVault(address vault, uint256 amount, address user) internal returns (uint256 sharesReceived) {
        usdc.forceApprove(vault, amount);
        sharesReceived = IERC4626(vault).deposit(amount, user);
        if (sharesReceived == 0) revert ZeroAmount();
    }

    /// @dev Pull ERC4626 vault shares from `user` and redeem to USDC held by this contract.
    function _withdrawFromVault(address vault, address user, uint256 shares) internal returns (uint256 usdcReceived) {
        IERC20(vault).safeTransferFrom(user, address(this), shares);
        usdcReceived = IERC4626(vault).redeem(shares, address(this), address(this));
    }

    /// @dev Burn USDC cross-chain via CCTP V2 TokenMessenger using `depositForBurnWithHook`.
    ///      `beneficiary` is ABI-encoded as hookData and committed into the signed CCTP
    ///      message, allowing `relayAndDeposit` on the destination chain to verify the
    ///      intended vault-share recipient. Low-level call avoids proxy return-value revert.
    function _cctpBurn(
        uint256 amount,
        uint32  destDomain,
        bytes32 mintRecipient,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32  minFinalityThreshold,
        address beneficiary
    ) internal {
        if (tokenMessenger == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (mintRecipient == bytes32(0)) revert ZeroAddress();
        usdc.forceApprove(tokenMessenger, amount);
        (bool success, ) = tokenMessenger.call(
            abi.encodeCall(
                ITokenMessengerV2.depositForBurnWithHook,
                (amount, destDomain, mintRecipient, address(usdc),
                 destinationCaller, maxFee, minFinalityThreshold, abi.encode(beneficiary))
            )
        );
        if (!success) revert CctpBurnFailed();
    }

    // -------------------------------------------------------------------------
    // Executor-only: Rebalancing
    // -------------------------------------------------------------------------

    /// @notice Atomically move a user's position from one vault to another.
    /// @dev Flow:
    ///      1. Collect performance fee shares from user (may span multiple vaults).
    ///      2. Pull `shares` from `fromVault` and redeem to USDC.
    ///      3. Deposit full USDC amount into `toVault` on behalf of `user`.
    ///      Pass empty arrays for `feeVaults`/`feeAmounts` to perform a no-fee rebalance.
    ///      The user must have pre-approved this contract to spend their `fromVault`
    ///      ERC4626 shares and any fee vault tokens before the rebalancer calls this.
    /// @param user       The user whose position is being rebalanced.
    /// @param fromVault  The vault to withdraw from.
    /// @param toVault    The vault to deposit into. Must be whitelisted.
    /// @param shares     ERC4626 shares to move.
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
    ) external onlyExecutor nonReentrant {
        if (shares == 0) revert ZeroAmount();
        if (fromVault == toVault) revert InvalidInput();
        if (feeVaults.length != feeAmounts.length) revert ArrayLengthMismatch();
        if (!_getEarnStorage().approvedVaults[toVault]) revert VaultNotApproved(toVault);
        if (IERC20(toVault).allowance(user, address(this)) == 0) revert InvalidInput();

        // --- Performance fee extraction (vault shares, before withdrawal) ---
        _collectFees(user, feeVaults, feeAmounts);

        // --- Withdrawal leg ---
        uint256 before = usdc.balanceOf(address(this));
        uint256 usdcReceived = _withdrawFromVault(fromVault, user, shares);

        // --- Deposit leg (full amount — fees already taken as shares) ---
        _depositToVault(toVault, usdcReceived, user);

        // --- Return any remainder to the user ---
        uint256 remainder = usdc.balanceOf(address(this)) - before;
        if (remainder > 0) {
            usdc.safeTransfer(user, remainder);
        }

        emit Rebalanced(user, fromVault, toVault, shares, usdcReceived);
    }

    // -------------------------------------------------------------------------
    // Executor-only: Atomic withdraw + CCTP burn
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
    /// @param vault                 The vault to withdraw from.
    /// @param shares                ERC4626 shares to redeem.
    /// @param feeVaults             Vault addresses from which to collect performance fee shares.
    /// @param feeAmounts            Corresponding share amounts to collect from each vault in `feeVaults`.
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
        uint32  destDomain,
        bytes32 mintRecipient,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32  minFinalityThreshold
    ) external onlyExecutor nonReentrant returns (uint256 netUsdc) {
        if (shares == 0) revert ZeroAmount();
        if (feeVaults.length != feeAmounts.length) revert ArrayLengthMismatch();

        // Allowed pairings:
        //   (this, this)  — MEV-protected cross-chain rebalance; the relayer
        //                   completes the deposit via relayAndDeposit.
        //   (user,   0)   — permissionless cross-chain exit; anyone can call
        //                   receiveMessage on the destination chain to mint USDC
        //                   directly to the user's wallet.
        bytes32 selfB = bytes32(uint256(uint160(address(this))));
        bytes32 userB = bytes32(uint256(uint160(user)));
        bool isRebalance = (mintRecipient == selfB && destinationCaller == selfB);
        bool isExit      = (mintRecipient == userB && destinationCaller == bytes32(0));
        if (!isRebalance && !isExit) revert InvalidInput();

        // --- Performance fee extraction (vault shares, before withdrawal) ---
        _collectFees(user, feeVaults, feeAmounts);

        // --- Withdrawal ---
        netUsdc = _withdrawFromVault(vault, user, shares);

        // --- CCTP burn (hookData = user, verified by relayAndDeposit on dest chain) ---
        _cctpBurn(netUsdc, destDomain, mintRecipient, destinationCaller, maxFee, minFinalityThreshold, user);

        emit BridgeInitiated(user, vault, shares, netUsdc, destDomain);
    }

    // -------------------------------------------------------------------------
    // Relayer-only: Atomic relay + deposit (single transaction)
    // -------------------------------------------------------------------------

    /// @notice Atomically relay a CCTP V2 message and deposit the minted USDC into one
    ///         or more whitelisted vaults on behalf of `user`.
    /// @dev Flow:
    ///      1. Snapshot USDC balance of this contract before the relay.
    ///      2. Call `IMessageTransmitter.receiveMessage` — Circle's contract mints USDC
    ///         directly to this contract's address.
    ///      3. Compute minted amount from the balance delta (avoids trusting the relay
    ///         return value — `receiveMessage` returns a bool, not the minted amount).
    ///      4. Verify the minted amount covers the sum of `amounts`.
    ///      5. Deposit into each vault on behalf of `user`.
    ///      Setting `destinationCaller = address(this)` (as bytes32) at burn time on the
    ///      source chain means only this contract can relay — this is the recommended
    ///      MEV-protection pattern for atomic relay+deposit.
    ///      Works for both single-vault (1-element arrays) and multi-vault relay+deposit.
    /// @param message     Raw CCTP V2 message bytes emitted from the source-chain burn event.
    /// @param attestation Circle attestation signature authorising the relay.
    /// @param user        The user who will receive vault shares.
    /// @param vaults      Whitelisted ERC4626 destination vaults.
    /// @param amounts     USDC amounts to deposit into each vault, aligned 1:1 with `vaults`.
    ///                    Sum must be ≤ the USDC minted by the relay. Each entry must be > 0.
    function relayAndDeposit(
        bytes calldata message,
        bytes calldata attestation,
        address user,
        address[] calldata vaults,
        uint256[] calldata amounts
    ) external onlyRelayer nonReentrant {
        if (vaults.length == 0) revert InvalidInput();
        if (vaults.length != amounts.length) revert ArrayLengthMismatch();

        // Verify `user` matches the beneficiary committed in hookData at burn time.
        // CCTP V2 message layout: 148-byte header + 228-byte burn body = 376 bytes
        // before hookData; beneficiary is abi.encode(address) = 32 bytes.
        if (message.length < 408) revert InvalidInput();
        if (abi.decode(message[376:408], (address)) != user) revert InvalidUser();

        EarnStorage storage $ = _getEarnStorage();
        for (uint256 i = 0; i < vaults.length; i++) {
            if (!$.approvedVaults[vaults[i]]) revert VaultNotApproved(vaults[i]);
            if (IERC20(vaults[i]).allowance(user, address(this)) == 0) revert InvalidInput();
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
            uint256 sharesReceived = _depositToVault(vaults[i], amounts[i], user);
            emit DepositedFromBridge(user, vaults[i], amounts[i], sharesReceived);
        }

        // Step 5: Return any remainder to the user (e.g. CCTP fee buffer)
        uint256 remainder = usdc.balanceOf(address(this)) - before;
        if (remainder > 0) {
            usdc.safeTransfer(user, remainder);
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
        EarnStorage storage $ = _getEarnStorage();
        uint256 total = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            if (!$.approvedVaults[vaults[i]]) revert VaultNotApproved(vaults[i]);
            if (amounts[i] == 0) revert ZeroAmount();
            total += amounts[i];
        }
        // Per-burn allowed pairings:
        //   (this, this)       — MEV-protected vault deposit on dest chain via relayAndDeposit.
        //   (msg.sender, 0)    — permissionless mint back to caller's wallet on dest chain.
        bytes32 selfB = bytes32(uint256(uint160(address(this))));
        bytes32 senderB = bytes32(uint256(uint160(msg.sender)));
        for (uint256 i = 0; i < burns.length; i++) {
            if (burns[i].amount == 0) revert ZeroAmount();
            bytes32 mr = burns[i].mintRecipient;
            bytes32 dc = burns[i].destinationCaller;
            bool isVaultDeposit = (mr == selfB && dc == selfB);
            bool isDirectMint   = (mr == senderB && dc == bytes32(0));
            if (!isVaultDeposit && !isDirectMint) revert InvalidInput();
            total += burns[i].amount;
        }

        // Pull total USDC from msg.sender in one transfer
        uint256 before = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), total);

        // Deposit into each local vault
        for (uint256 i = 0; i < vaults.length; i++) {
            uint256 sharesReceived = _depositToVault(vaults[i], amounts[i], msg.sender);
            emit Deposited(msg.sender, vaults[i], amounts[i], sharesReceived);
        }

        // Execute CCTP burns for cross-chain deposits (hookData = msg.sender)
        for (uint256 i = 0; i < burns.length; i++) {
            _cctpBurn(burns[i].amount, burns[i].destDomain,
                burns[i].mintRecipient, burns[i].destinationCaller, burns[i].maxFee, burns[i].minFinalityThreshold,
                msg.sender);
            emit BridgeBurnInitiated(msg.sender, burns[i].amount, burns[i].destDomain, burns[i].mintRecipient);
        }

        // Return any remainder to the user
        uint256 remainder = usdc.balanceOf(address(this)) - before;
        if (remainder > 0) {
            usdc.safeTransfer(msg.sender, remainder);
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
    ///      When `burns` is non-empty, redeemed USDC is accumulated in the contract and
    ///      burned via CCTP to bridge back to the user's source chain. Any remainder
    ///      after burns is transferred to msg.sender. Pass `type(uint256).max` as
    ///      `burns[i].amount` to burn all redeemed USDC (recommended for close flows).
    /// @param vaults     ERC4626 vault addresses to withdraw from.
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
        // Per-burn pairing: (msg.sender, 0) — permissionless bridge-back to the
        // caller's wallet. type(uint256).max ("burn all") only valid in the final entry.
        bytes32 senderB = bytes32(uint256(uint160(msg.sender)));
        for (uint256 i = 0; i < burns.length; i++) {
            if (i + 1 < burns.length && burns[i].amount == type(uint256).max) revert InvalidInput();
            if (burns[i].mintRecipient != senderB || burns[i].destinationCaller != bytes32(0)) revert InvalidInput();
        }

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

            // L-06: the (shares[i] == 0 → full balance) sentinel was removed; callers must
            // pass the explicit gross share amount. This closes the max-approval footgun
            // where a zero entry would silently drain the user's full balance from `vault`.
            if (shares[i] == 0) revert ZeroAmount();
            uint256 amt = shares[i];
            IERC20(vault).safeTransferFrom(msg.sender, address(this), amt);
            uint256 feeAmt = feeAmounts[i];
            if (feeAmt > 0) {
                if (feeAmt >= amt) revert InvalidInput();
                amt -= feeAmt;
                feeVaultsEmitted[feeCount] = vault;
                feeAmountsEmitted[feeCount] = feeAmt;
                feeCount++;
            }
            uint256 usdcReceived = IERC4626(vault).redeem(amt, usdcRecipient, address(this));
            emit StrategyExited(msg.sender, vault, amt, usdcReceived);
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
                uint256 burnAmount = burns[i].amount == type(uint256).max ? netUsdc : burns[i].amount;
                if (burnAmount > netUsdc) revert InvalidInput();

                _cctpBurn(burnAmount, burns[i].destDomain,
                    burns[i].mintRecipient, burns[i].destinationCaller, burns[i].maxFee, burns[i].minFinalityThreshold,
                    msg.sender);
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
    // User-callable: CCTP escape hatch
    // -------------------------------------------------------------------------

    /// @notice Consume a pending CCTP V2 message and deliver the minted USDC straight
    ///         to the beneficiary's wallet, bypassing the vault deposit. Use when the
    ///         relayer cannot complete `relayAndDeposit` (relayer down, beneficiary
    ///         has no destination-vault allowance, etc.).
    /// @dev Authorization is via the hookData beneficiary committed at burn time
    ///      (encoded by `_cctpBurn`, validated by `relayAndDeposit`). Only callable by
    ///      that beneficiary on the destination chain. Works because this contract is
    ///      the `destinationCaller` per the L-02 pairing constraint for the
    ///      `(this, this)` case.
    /// @param message     Raw CCTP V2 message bytes from Circle's Iris API.
    /// @param attestation Circle attestation signature authorising the relay.
    function emergencyClaimBridge(
        bytes calldata message,
        bytes calldata attestation
    ) external nonReentrant {
        if (message.length < 408) revert InvalidInput();
        address beneficiary = abi.decode(message[376:408], (address));
        if (msg.sender != beneficiary) revert Unauthorized();

        uint256 before = usdc.balanceOf(address(this));
        bool ok = IMessageTransmitter(messageTransmitter).receiveMessage(message, attestation);
        if (!ok) revert MessageRelayFailed();

        uint256 minted = usdc.balanceOf(address(this)) - before;
        usdc.safeTransfer(beneficiary, minted);

        emit BridgeClaimed(beneficiary, minted);
    }

    // -------------------------------------------------------------------------
    // Owner-only: Fee management
    // -------------------------------------------------------------------------

    /// @notice Sweep a specific amount of an ERC20 token to the owner.
    /// @dev Use this to drain accumulated fee tokens (vault shares or USDC bridge
    ///      fees), or to recover accidentally sent tokens.
    /// @param token  The ERC20 token to sweep.
    /// @param amount The amount to transfer to the owner.
    function sweep(address token, uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(owner(), amount);
        emit FeeSwept(token, owner(), amount);
    }

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @notice Return the full list of currently whitelisted vault addresses.
    /// @return Array of approved vault addresses.
    function getApprovedVaults() external view returns (address[] memory) {
        return _getEarnStorage().vaultList;
    }

    /// @notice Check whether a specific vault address is currently whitelisted.
    /// @param vault The address to query.
    /// @return True if the vault is approved, false otherwise.
    function isVaultApproved(address vault) external view returns (bool) {
        return _getEarnStorage().approvedVaults[vault];
    }

    /// @notice The executor address permitted to call `rebalance` and `withdrawAndBridge`.
    function executor() external view returns (address) {
        return _getEarnStorage().executor;
    }

    /// @notice The relayer address permitted to call `relayAndDeposit`.
    function relayer() external view returns (address) {
        return _getEarnStorage().relayer;
    }
}
