// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @dev Minimal Circle CCTP V2 MessageTransmitter interface.
///      Used by `relayAndDeposit` to finalize a cross-chain transfer: the relayer
///      submits the original CCTP message + Circle attestation, which mints USDC
///      on the destination chain.
interface IMessageTransmitter {
    /// @notice Verify `attestation` against Circle's attester set and execute the
    ///         embedded mint. Returns true on success; reverts on invalid attestation
    ///         or replayed nonce.
    /// @param message     The raw CCTP message emitted on the source chain.
    /// @param attestation Circle-signed attestation bytes (from the Iris API).
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool);
}

/// @dev Minimal Circle CCTP V2 TokenMessenger interface for cross-chain burns.
///      `depositForBurnWithHook` is called via low-level `call` in `_cctpBurn`
///      rather than a typed interface call so it tolerates ABI variation across
///      CCTP V2 proxy deployments — a typed void-return call would revert on any
///      proxy that surfaces non-empty return data, while a typed bytes-returning
///      call would revert on any proxy that returns nothing. The low-level call
///      simply checks `success` and discards the return data.
interface ITokenMessengerV2 {
    /// @notice Burn `amount` of `burnToken` on the source chain and arrange a mint
    ///         of the same amount (minus fees) to `mintRecipient` on `destinationDomain`.
    ///         `hookData` is committed into the signed message and forwarded on the
    ///         destination chain — this contract encodes the beneficiary address there
    ///         so `relayAndDeposit` can verify the intended vault-share recipient.
    /// @param amount               USDC amount to burn.
    /// @param destinationDomain    CCTP domain ID of the target chain.
    /// @param mintRecipient        bytes32-encoded address that will receive minted USDC.
    /// @param burnToken            The token to burn (USDC).
    /// @param destinationCaller    If non-zero, only this address may call `receiveMessage`.
    /// @param maxFee               Maximum fee (in USDC) the relayer may deduct.
    /// @param minFinalityThreshold Minimum source-chain finality before attestation.
    /// @param hookData             Arbitrary bytes forwarded to the destination — we encode
    ///                             the beneficiary address for on-chain verification.
    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external;
}

/// @dev Minimal Uniswap Permit2 SignatureTransfer interface (canonical deployment).
///      Used by `bridgePermit2` and `selfBatchDepositPermit2` to pull USDC with an
///      off-chain EIP-712 signature instead of a per-call ERC20 approval.
///      The absent return value on `permitTransferFrom` is load-bearing: Solidity
///      emits the `extcodesize` existence check only when no return data is decoded,
///      so on a chain without Permit2 the call reverts instead of silently
///      succeeding. A silent success would let a caller reach the deposit and burn
///      legs having transferred nothing. Do not add a return type.
interface ISignatureTransfer {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }
    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }
    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }
    /// @notice Transfer `transferDetails.requestedAmount` of `permit.permitted.token`
    ///         from `owner` to `transferDetails.to`, authorised by `signature`.
    ///         Permit2 itself enforces nonce uniqueness, deadline expiry, signature
    ///         validity, and `requestedAmount <= permit.permitted.amount`.
    /// @param permit         The token, amount, nonce and deadline the owner signed over.
    /// @param transferDetails Recipient and the amount actually requested, which must not
    ///                        exceed the signed amount.
    /// @param owner          The account that signed the permit. Permit2 recovers an EOA
    ///                       signature with ecrecover and verifies a contract signer via
    ///                       EIP-1271, which is what lets multi-sig and ERC-4337 accounts
    ///                       use these paths.
    /// @param signature      EIP-712 signature, or the EIP-1271 blob for a contract signer.
    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}

/// @dev Minimal Morpho Vault V2 interface for force-deallocation.
///      `forceDeallocate` is permissionless on the vault side: it moves `assets`
///      from `adapter` back into the vault's idle balance so a subsequent redeem
///      can succeed, and charges a curator-set penalty (protocol-capped at 2%)
///      by burning vault shares from `onBehalf` through the vault's own public
///      withdraw path. When the caller IS `onBehalf`, no share allowance is
///      required for the penalty charge.
interface IMorphoVaultV2 {
    /// @notice Move `assets` out of `adapter` and back into the vault's idle balance so a
    ///         subsequent redeem can be served, charging a penalty in vault shares.
    /// @param adapter  Vault V2 adapter to deallocate from.
    /// @param data     Adapter-specific market identifier: abi-encoded MarketParams
    ///                 for MorphoMarketV1AdapterV2, empty bytes for MorphoVaultV1Adapter.
    /// @param assets   Asset amount to move from the adapter into vault idle.
    /// @param onBehalf Account whose shares pay the penalty.
    /// @return penaltyShares Vault shares burned from `onBehalf` as the penalty.
    function forceDeallocate(
        address adapter,
        bytes calldata data,
        uint256 assets,
        address onBehalf
    ) external returns (uint256 penaltyShares);
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

/// @notice One force-deallocation instruction for a Morpho Vault V2 source vault,
///         used by `rebalance` and `withdrawAndBridge`.
/// @dev `data` identifies the underlying market to the adapter: abi-encoded
///      MarketParams for MorphoMarketV1AdapterV2, empty bytes for
///      MorphoVaultV1Adapter. The executor sizes `assets` off-chain to cover only
///      the shortfall the vault's normal redeem path cannot serve (idle balance
///      plus the vault's configured liquidityAdapter market, which redeem draws
///      automatically and penalty-free).
struct ForceDealloc {
    address adapter; // Vault V2 adapter registered on the source vault
    bytes   data;    // adapter-specific market identifier blob
    uint256 assets;  // asset amount to deallocate from this adapter
}

/// @title QuicknodeEarn
/// @notice Non-custodial yield-optimiser that moves user funds between whitelisted
///         ERC4626 vaults (Morpho) to maximise supply APY.
/// @dev Architecture overview:
///      - Users retain full custody: they grant ERC20 approvals to this contract but
///        never transfer principal in; all vault shares are held by the user.
///      - Three privileged roles:
///        - **Owner** (multisig): vault whitelist, fee sweeps, role assignment.
///        - **Executor**: calls `rebalance` and `withdrawAndBridge` to move capital.
///        - **Relayer**: calls `relayAndDeposit` to relay CCTP messages and deposit.
///      - Users can create strategies via `selfBatchDeposit` and close them via
///        `selfBatchWithdraw` without owner involvement.
///      - Fee model: a rebalance fee is collected as vault shares (not USDC). The executor
///        computes the fee off-chain (gas-cost-plus: the move's gas cost in USDC times a
///        per-chain multiplier), converts it to vault shares, and passes them as
///        `feeVaults[]`/`feeAmounts[]` on rebalance/withdraw calls. The contract transfers
///        those shares from the user to itself. The owner sweeps accumulated fee tokens
///        via `sweep()`.
///        Fee arrays may be empty (no-fee rebalance) or contain vaults unrelated to the
///        current `fromVault`/`toVault` pair — the executor collects from ALL vaults with
///        accrued yield in a single operation.
///      - Vault whitelist: only addresses in `approvedVaults` may receive deposits. This
///        prevents the owner from draining users into arbitrary contracts.
///      - Two-step ownership (`Ownable2Step`) prevents accidental ownership transfer to
///        an uncontrolled address.
///      - CCTP V2 integration: `withdrawAndBridge` burns USDC cross-chain after a
///        vault withdrawal; `relayAndDeposit` relays a CCTP message and atomically
///        deposits on the destination chain; `selfBatchDeposit` and `selfBatchWithdraw`
///        accept optional `BridgeBurn[]` arrays for cross-chain deposits and bridge-back
///        on close; `bridge` and `bridgePermit2` are standalone wallet-to-wallet
///        transfers unrelated to any vault position.
///      - Morpho Vault V2 force-deallocation: a V2 vault usually holds almost no idle
///        USDC, so a plain redeem can fail even though the underlying liquidity is
///        recoverable. `rebalance`, `withdrawAndBridge` and `selfBatchWithdraw` accept
///        an optional `ForceDealloc[]` that frees adapter liquidity first, for a
///        penalty the vault charges against the position being moved. See
///        `_forceDeallocate` for the penalty accounting and its two caps.
///      - Permit2: `bridgePermit2` and `selfBatchDepositPermit2` pull USDC with an
///        off-chain EIP-712 signature instead of a per-call ERC20 approval. Permit2
///        verifies contract signers through EIP-1271, so multi-sig and ERC-4337
///        accounts work on these paths as well as EOAs.
///      - `selfBatchDeposit` and `selfBatchWithdraw` are deliberately user-callable with
///        no owner requirement. Note that they are a convenience, not the source of the
///        exit guarantee: vault shares live in the user's own wallet, so a user can
///        always redeem directly against the vault (calling Morpho's permissionless
///        `forceDeallocate` first if it is illiquid) without touching this contract.
contract QuicknodeEarn is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Canonical Permit2 deployment address (same on all EVM chains).
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice Hard ceiling on the force-deallocate penalty, in basis points of the
    ///         shares being moved. Morpho caps a vault's own penalty at 2% of the
    ///         DEALLOCATED assets, and a legitimate deallocation never exceeds the
    ///         position being moved, so an honest move stays under 2%. The extra
    ///         headroom absorbs rounding. This bound is what limits the damage a
    ///         compromised executor can do: without it, the only on-chain limit
    ///         would be the caller-supplied `maxPenaltyShares`, which is set by the
    ///         same actor that supplies the deallocation instructions.
    uint256 public constant MAX_FORCE_DEALLOC_PENALTY_BPS = 300;

    /// @notice Implementation version, incremented on each upgrade. Lets an
    ///         off-chain caller detect which ABI a given chain expects during a
    ///         staged multi-chain rollout.
    uint256 public constant VERSION = 2;

    /// @notice `service` value meaning the caller will complete the destination
    ///         mint themselves. Every standalone burn uses a zero destination
    ///         caller, so the caller (or any third party) can always relay.
    uint8 public constant BRIDGE_SELF_RELAY = 0;

    /// @notice `service` value meaning we are expected to complete the destination
    ///         mint on the caller's behalf. The contract does NOT price this: it
    ///         records what was paid and leaves the decision to relay to the
    ///         off-chain quote, so pricing can change without a contract upgrade.
    ///         An underpaid request is simply not relayed; the caller can still
    ///         self-relay, so no funds are ever at risk.
    uint8 public constant BRIDGE_SPONSORED_RELAY = 1;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice The USDC token this contract operates on.
    IERC20  public immutable usdc;

    /// @notice The CCTP V2 MessageTransmitter address for relaying bridge messages.
    ///         `address(0)` disables CCTP relay functionality (`relayAndDeposit` reverts).
    address public immutable messageTransmitter;

    /// @notice The CCTP V2 TokenMessenger address for initiating cross-chain USDC burns.
    ///         `address(0)` disables all CCTP burn paths (`withdrawAndBridge`, `selfBatchDeposit`
    ///         with burns, and `selfBatchWithdraw` with burns will revert).
    address public immutable tokenMessenger;

    /// @notice Maps vault address → whether it is whitelisted for deposits.
    mapping(address vault => bool approved) public approvedVaults;

    /// @notice Enumerable list of all currently approved vault addresses.
    ///         Maintained in sync with `approvedVaults`.
    address[] public vaultList;


    /// @notice The executor address permitted to call `rebalance` and `withdrawAndBridge`.
    ///         Set by the owner via `setExecutor()`. May be an EOA or a contract.
    address public executor;

    /// @notice The relayer address permitted to call `relayAndDeposit`.
    ///         Set by the owner via `setRelayer()`. May be an EOA or a contract.
    address public relayer;

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

    /// @notice Emitted when an executor force-dealloc call moved liquidity out of a
    ///         Morpho Vault V2 source vault before the redeem.
    /// @param user              The user whose position bears the penalty (as a reduced redeem).
    /// @param vault             The Vault V2 that was force-deallocated.
    /// @param assetsDeallocated Total assets moved from adapters into vault idle.
    /// @param penaltyShares     Total vault shares burned as the penalty.
    event ForceDeallocated(
        address indexed user,
        address indexed vault,
        uint256 assetsDeallocated,
        uint256 penaltyShares
    );

    /// @notice Emitted for every standalone bridge. This is the ONLY event the
    ///         standalone path emits, deliberately: `BridgeBurnInitiated` denotes
    ///         strategy activity and the event-processor attributes it to a
    ///         strategy, so reusing it here would misclassify a plain transfer.
    /// @dev Carries every field an indexer needs to act without decoding
    ///      calldata. That matters because a smart-account (ERC-4337 / multi-sig)
    ///      transaction wraps our call, and the outer calldata is not decodable,
    ///      so anything readable only from calldata would be unknowable for those
    ///      users. Emitted unconditionally, including when `fee` is zero.
    /// @param user                 The account that bridged (EOA, multi-sig, or 4337 account).
    /// @param service              Who is expected to complete the destination mint:
    ///                             `BRIDGE_SELF_RELAY` (0) means the user claims it themselves,
    ///                             `BRIDGE_SPONSORED_RELAY` (1) means we relay it for them.
    ///                             Indexed so an indexer can filter cheaply.
    /// @param fee                  USDC retained by this contract.
    /// @param amount               USDC burned via CCTP, after `fee` is deducted. Circle may
    ///                             deduct up to `maxFee` again on the destination chain, so the
    ///                             recipient can receive less than this.
    /// @param destDomain           CCTP destination domain ID.
    /// @param mintRecipient        Address receiving the minted USDC on the destination chain.
    /// @param maxFee               Circle's fee cap. Zero on a standard transfer.
    /// @param minFinalityThreshold 2000 = standard, 1000 or lower = Circle Fast Transfer.
    event BridgeExecuted(
        address indexed user,
        uint8   indexed service,
        uint256 fee,
        uint256 amount,
        uint32  destDomain,
        address mintRecipient,
        uint256 maxFee,
        uint32  minFinalityThreshold
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

    /// @notice Thrown when the cumulative force-deallocate penalty exceeds either the
    ///         caller-supplied cap or the contract's own `MAX_FORCE_DEALLOC_PENALTY_BPS`
    ///         ceiling. The caller-supplied cap guards against a curator repricing the
    ///         vault penalty between off-chain simulation and on-chain inclusion; the
    ///         constant ceiling guards the position holder against the caller itself.
    /// @param penaltyShares Cumulative penalty shares charged by the vault.
    /// @param cap           The lower of the two caps that was breached.
    error PenaltyTooHigh(uint256 penaltyShares, uint256 cap);

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
        if (msg.sender != executor) revert UnauthorizedExecutor();
        _;
    }

    /// @dev Restricts a function to the designated relayer address.
    modifier onlyRelayer() {
        if (msg.sender != relayer) revert UnauthorizedRelayer();
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Deploy QuicknodeEarn.
    /// @dev Sets all immutable addresses and optionally seeds the vault whitelist.
    ///      Only `_usdc` and `_owner` must be non-zero. Pass `address(0)` for
    ///      `_messageTransmitter` and `_tokenMessenger` on chains where CCTP is
    ///      not available — relay/burn paths will revert with `ZeroAddress`.
    /// @param _usdc               USDC token address.
    /// @param _messageTransmitter CCTP V2 MessageTransmitter; `address(0)` disables relay.
    /// @param _tokenMessenger     CCTP V2 TokenMessenger; `address(0)` disables CCTP burns.
    /// @param _owner              Initial owner. Receives all owner privileges.
    /// @param _initialVaults      Optional list of vaults to whitelist atomically.
    ///                            Duplicates and zero addresses are silently skipped.
    constructor(
        address _usdc,
        address _messageTransmitter,
        address _tokenMessenger,
        address _owner,
        address[] memory _initialVaults
    ) Ownable(_owner) {
        if (_usdc == address(0)) revert ZeroAddress();

        usdc               = IERC20(_usdc);
        messageTransmitter = _messageTransmitter;
        tokenMessenger     = _tokenMessenger;

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
    // Owner-only: Role management
    // -------------------------------------------------------------------------

    /// @notice Set the executor address permitted to call `rebalance` and `withdrawAndBridge`.
    /// @param _executor The new executor address. Use `address(0)` to revoke.
    function setExecutor(address _executor) external onlyOwner {
        address old = executor;
        executor = _executor;
        emit ExecutorUpdated(old, _executor);
    }

    /// @notice Set the relayer address permitted to call `relayAndDeposit`.
    /// @param _relayer The new relayer address. Use `address(0)` to revoke.
    function setRelayer(address _relayer) external onlyOwner {
        address old = relayer;
        relayer = _relayer;
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
    ) private {
        if (feeVaults.length == 0) return;
        for (uint256 i = 0; i < feeVaults.length; i++) {
            address fv = feeVaults[i];
            if (fv == address(0)) revert ZeroAddress();
            if (!approvedVaults[fv]) revert VaultNotApproved(fv);
            IERC20(fv).safeTransferFrom(user, address(this), feeAmounts[i]);
        }
        emit PerformanceFeeCollected(user, feeVaults, feeAmounts);
    }

    /// @dev Deposit USDC into an ERC4626 vault on behalf of `user`.
    function _depositToVault(address vault, uint256 amount, address user) private returns (uint256 sharesReceived) {
        usdc.forceApprove(vault, amount);
        sharesReceived = IERC4626(vault).deposit(amount, user);
        if (sharesReceived == 0) revert ZeroAmount();
    }

    /// @dev Pull ERC4626 vault shares from `user`, force-deallocate liquidity from
    ///      the vault's adapters into its idle balance. The shares being moved must
    ///      ALREADY be held by this contract: the penalty is charged with
    ///      `onBehalf = address(this)`, so it burns from the shares in motion and
    ///      never touches the position holder's wallet balance or allowances.
    /// @dev  Two independent caps apply. `maxPenaltyShares` is supplied by the caller
    ///       and protects the caller against a curator repricing the penalty between
    ///       simulation and inclusion. `MAX_FORCE_DEALLOC_PENALTY_BPS` is a constant
    ///       and protects the position holder against the caller, which matters
    ///       because the same actor supplies both the deallocation sizes and their cap.
    ///       Callers must subtract the returned penalty from the amount they redeem.
    /// @param vault            The Morpho Vault V2 to deallocate from.
    /// @param deallocs         Force-deallocation instructions (may be empty).
    /// @param shares           Shares being moved; the penalty ceiling is a fraction of this.
    /// @param maxPenaltyShares Caller's cap on cumulative penalty shares.
    /// @param holder           Position holder, for the event only.
    /// @return penaltyShares   Vault shares burned from this contract as the penalty.
    function _forceDeallocate(
        address vault,
        ForceDealloc[] calldata deallocs,
        uint256 shares,
        uint256 maxPenaltyShares,
        address holder
    ) private returns (uint256 penaltyShares) {
        if (deallocs.length == 0) return 0;

        uint256 assetsTotal = 0;
        for (uint256 i = 0; i < deallocs.length; i++) {
            if (deallocs[i].assets == 0) revert ZeroAmount();
            assetsTotal += deallocs[i].assets;
            penaltyShares += IMorphoVaultV2(vault).forceDeallocate(
                deallocs[i].adapter,
                deallocs[i].data,
                deallocs[i].assets,
                address(this)
            );
        }
        if (penaltyShares > maxPenaltyShares) revert PenaltyTooHigh(penaltyShares, maxPenaltyShares);
        uint256 ceiling = shares * MAX_FORCE_DEALLOC_PENALTY_BPS / 10_000;
        if (penaltyShares > ceiling) revert PenaltyTooHigh(penaltyShares, ceiling);

        emit ForceDeallocated(holder, vault, assetsTotal, penaltyShares);
    }

    /// @dev Pull ERC4626 vault shares from `user`, optionally force-deallocate
    ///      liquidity from the vault's adapters, then redeem the pulled shares net
    ///      of the penalty. See `_forceDeallocate` for the penalty accounting.
    ///      `usdcReceived` is the MEASURED balance increase, not the vault's reported
    ///      redeem return: a vault that over-reports must not be able to make callers
    ///      spend USDC the contract already holds.
    /// @param vault            The vault to withdraw from.
    /// @param user             The user whose shares are pulled (and who bears the penalty).
    /// @param shares           Gross ERC4626 shares to pull from `user`.
    /// @param deallocs         Force-deallocation instructions (may be empty).
    /// @param maxPenaltyShares Cap on cumulative penalty shares; exceeding it reverts.
    /// @return usdcReceived    USDC actually received by this contract.
    function _withdrawFromVault(
        address vault,
        address user,
        uint256 shares,
        ForceDealloc[] calldata deallocs,
        uint256 maxPenaltyShares
    ) private returns (uint256 usdcReceived) {
        IERC20(vault).safeTransferFrom(user, address(this), shares);

        uint256 penaltyShares = _forceDeallocate(vault, deallocs, shares, maxPenaltyShares, user);

        uint256 before = usdc.balanceOf(address(this));
        IERC4626(vault).redeem(shares - penaltyShares, address(this), address(this));
        usdcReceived = usdc.balanceOf(address(this)) - before;
    }

    /// @dev Pull `amount` USDC from msg.sender into this contract via a Permit2
    ///      SignatureTransfer. The signed token is REQUIRED to be USDC: without
    ///      this check a caller could satisfy the pull with a worthless token
    ///      while the subsequent deposits/burns spend USDC already resting in the
    ///      contract (accumulated bridge fees).
    function _permit2Pull(
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature,
        uint256 amount
    ) private {
        if (permit.permitted.token != address(usdc)) revert InvalidInput();
        ISignatureTransfer(PERMIT2).permitTransferFrom(
            permit,
            ISignatureTransfer.SignatureTransferDetails({ to: address(this), requestedAmount: amount }),
            msg.sender,
            signature
        );
    }

    /// @dev Shared validation for both bridge entry points. Runs BEFORE any funds
    ///      move, so a bad request never reaches an external transfer.
    function _validateBridge(
        uint256 amount,
        uint256 fee,
        uint8   service,
        address mintRecipient
    ) private view {
        if (tokenMessenger == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (fee >= amount) revert InvalidInput();
        if (service > BRIDGE_SPONSORED_RELAY) revert InvalidInput();
        if (mintRecipient == address(0)) revert ZeroAddress();
        // A standalone bridge must not mint into this contract: the proxy sits at
        // the same address on every chain, so a self-recipient burn would park USDC
        // in the destination contract with no vault intent attached. Cross-chain
        // vault deposits have their own path via `selfBatchDeposit` burns.
        if (mintRecipient == address(this)) revert InvalidInput();
    }

    /// @dev Shared tail of `bridge` / `bridgePermit2`: retain `fee` USDC, burn the
    ///      remainder via CCTP with `mintRecipient` on the destination chain and no
    ///      destination caller, so anyone may relay and the mint always lands in the
    ///      recipient's wallet. `mintRecipient` is taken as an `address` and padded
    ///      here: CCTP truncates a bytes32 recipient to its low 20 bytes, so
    ///      accepting bytes32 from the caller would let a padded value defeat the
    ///      self-address check below.
    ///      The fee rests in the contract as USDC until the owner sweeps it.
    function _bridgeBurnWithFee(
        uint256 amount,
        uint256 fee,
        uint8   service,
        uint32  destDomain,
        address mintRecipient,
        uint256 maxFee,
        uint32  minFinalityThreshold
    ) private {
        uint256 bridgeAmount = amount - fee;

        usdc.forceApprove(tokenMessenger, bridgeAmount);
        _cctpBurn(
            bridgeAmount,
            destDomain,
            bytes32(uint256(uint160(mintRecipient))),
            bytes32(0),
            maxFee,
            minFinalityThreshold,
            msg.sender
        );
        usdc.forceApprove(tokenMessenger, 0);

        emit BridgeExecuted(
            msg.sender, service, fee, bridgeAmount,
            destDomain, mintRecipient, maxFee, minFinalityThreshold
        );
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
    ) private {
        if (tokenMessenger == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (mintRecipient == bytes32(0)) revert ZeroAddress();
        // Callers must approve `tokenMessenger` before calling: the approval is hoisted
        // to each call site so a batch of burns issues one approval, not one per burn.
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
    ///      2. Pull `shares` from `fromVault`, execute each `ForceDealloc` with
    ///         `onBehalf = address(this)` (the penalty burns from the pulled shares,
    ///         never from the user's wallet or allowances), then redeem
    ///         `shares - penaltyShares` to USDC. Pass an empty `deallocs` array on
    ///         liquid vaults; the flow is then a plain pull-and-redeem.
    ///      3. Deposit full USDC amount into `toVault` on behalf of `user`.
    ///      Pass empty arrays for `feeVaults`/`feeAmounts` to perform a no-fee rebalance.
    ///      The user must have pre-approved this contract to spend their `fromVault`
    ///      ERC4626 shares and any fee vault tokens before the rebalancer calls this.
    /// @param user       The user whose position is being rebalanced.
    /// @param fromVault  The vault to withdraw from. Deliberately NOT checked against
    ///                   `approvedVaults`, so a position stays exitable after the vault
    ///                   is de-listed (OZ audit finding #7).
    /// @param toVault    The vault to deposit into. Must be whitelisted.
    /// @param shares     ERC4626 shares to move.
    /// @param feeVaults  Vault addresses from which to collect performance fee shares.
    ///                   May be empty (no fee) or contain vaults outside the rebalance pair.
    /// @param feeAmounts Corresponding share amounts to collect from each vault in `feeVaults`.
    /// @param deallocs   Force-deallocation instructions for `fromVault`'s adapters
    ///                   (Morpho Vault V2 only). Empty when the vault's liquid
    ///                   capacity covers the move.
    /// @param maxPenaltyShares Cap on cumulative penalty shares charged by the vault.
    ///                   A curator repricing the penalty between simulation and
    ///                   inclusion makes the call revert instead of overcharging.
    function rebalance(
        address user,
        address fromVault,
        address toVault,
        uint256 shares,
        address[] calldata feeVaults,
        uint256[] calldata feeAmounts,
        ForceDealloc[] calldata deallocs,
        uint256 maxPenaltyShares
    ) external onlyExecutor nonReentrant {
        if (shares == 0) revert ZeroAmount();
        if (fromVault == toVault) revert InvalidInput();
        if (feeVaults.length != feeAmounts.length) revert ArrayLengthMismatch();
        if (!approvedVaults[toVault])   revert VaultNotApproved(toVault);
        if (IERC20(toVault).allowance(user, address(this)) == 0) revert InvalidInput();

        // --- Performance fee extraction (vault shares, before withdrawal) ---
        _collectFees(user, feeVaults, feeAmounts);

        // --- Withdrawal leg ---
        uint256 before = usdc.balanceOf(address(this));
        uint256 usdcReceived = _withdrawFromVault(fromVault, user, shares, deallocs, maxPenaltyShares);

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
    ///      Force-dealloc semantics match `rebalance`: pass an empty `deallocs`
    ///      array when the vault's liquid capacity covers the redeem.
    /// @param user                  The user whose vault position is bridged.
    /// @param vault                 The vault to withdraw from. Deliberately NOT checked
    ///                              against `approvedVaults`, so a position stays exitable
    ///                              after the vault is de-listed (OZ audit finding #7).
    /// @param shares                ERC4626 shares to redeem.
    /// @param feeVaults             Vault addresses from which to collect performance fee shares.
    /// @param feeAmounts            Corresponding share amounts to collect from each vault in `feeVaults`.
    /// @param destDomain            CCTP destination domain ID (e.g. 6 = Base, 0 = Ethereum).
    /// @param mintRecipient         bytes32-padded address to receive minted USDC on dest chain.
    /// @param destinationCaller     bytes32-padded address permitted to relay on dest chain.
    ///                              Set to `address(0)` to allow anyone to relay (no MEV protection).
    /// @param maxFee                Maximum fee the CCTP protocol may charge (0 for standard).
    /// @param minFinalityThreshold  0 = fast finality (seconds), 2000 = standard finality (full chain finality).
    /// @param deallocs              Force-deallocation instructions for `vault`'s adapters
    ///                              (Morpho Vault V2 only). Empty when the vault is liquid.
    /// @param maxPenaltyShares      Cap on cumulative penalty shares charged by the vault.
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
        uint32  minFinalityThreshold,
        ForceDealloc[] calldata deallocs,
        uint256 maxPenaltyShares
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
        netUsdc = _withdrawFromVault(vault, user, shares, deallocs, maxPenaltyShares);

        // --- CCTP burn (hookData = user, verified by relayAndDeposit on dest chain) ---
        usdc.forceApprove(tokenMessenger, netUsdc);
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

        for (uint256 i = 0; i < vaults.length; i++) {
            if (!approvedVaults[vaults[i]]) revert VaultNotApproved(vaults[i]);
            if (IERC20(vaults[i]).allowance(user, address(this)) == 0) revert InvalidInput();
        }

        uint256 before = usdc.balanceOf(address(this));

        bool success = IMessageTransmitter(messageTransmitter).receiveMessage(message, attestation);
        if (!success) revert MessageRelayFailed();

        uint256 minted = usdc.balanceOf(address(this)) - before;
        uint256 totalNeeded = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalNeeded += amounts[i];
        }
        if (minted < totalNeeded) revert ZeroAmount();

        for (uint256 i = 0; i < vaults.length; i++) {
            uint256 sharesReceived = _depositToVault(vaults[i], amounts[i], user);
            emit DepositedFromBridge(user, vaults[i], amounts[i], sharesReceived);
        }

        // Remainder covers the CCTP fee buffer.
        uint256 remainder = usdc.balanceOf(address(this)) - before;
        if (remainder > 0) {
            usdc.safeTransfer(user, remainder);
        }
    }

    /// @dev Validate a batch-deposit request and total the USDC it needs. Also
    ///      returns this contract's USDC balance BEFORE any pull, so the caller's
    ///      remainder calculation is a measured delta and can never reach USDC
    ///      already resting here.
    /// @return localTotal Sum of `amounts`, deposited into local vaults.
    /// @return burnTotal  Sum of `burns[i].amount`, burned via CCTP.
    /// @return before     USDC held by this contract before the pull.
    function _validateBatchDeposit(
        address[] calldata vaults,
        uint256[] calldata amounts,
        BridgeBurn[] calldata burns
    ) private view returns (uint256 localTotal, uint256 burnTotal, uint256 before) {
        if (vaults.length != amounts.length) revert InvalidInput();
        if (vaults.length == 0 && burns.length == 0) revert InvalidInput();

        for (uint256 i = 0; i < vaults.length; i++) {
            if (!approvedVaults[vaults[i]]) revert VaultNotApproved(vaults[i]);
            if (amounts[i] == 0) revert ZeroAmount();
            localTotal += amounts[i];
        }
        // Per-burn allowed pairings:
        //   (this, this)    — MEV-protected vault deposit on dest chain via relayAndDeposit.
        //   (msg.sender, 0) — permissionless mint back to caller's wallet on dest chain.
        bytes32 selfB = bytes32(uint256(uint160(address(this))));
        bytes32 senderB = bytes32(uint256(uint160(msg.sender)));
        for (uint256 i = 0; i < burns.length; i++) {
            if (burns[i].amount == 0) revert ZeroAmount();
            bytes32 mr = burns[i].mintRecipient;
            bytes32 dc = burns[i].destinationCaller;
            bool isVaultDeposit = (mr == selfB && dc == selfB);
            bool isDirectMint   = (mr == senderB && dc == bytes32(0));
            if (!isVaultDeposit && !isDirectMint) revert InvalidInput();
            burnTotal += burns[i].amount;
        }
        before = usdc.balanceOf(address(this));
    }

    /// @dev Deposit and burn legs shared by both batch-deposit entry points. The
    ///      USDC must already have been pulled in by the caller; only the pull
    ///      mechanism differs between them.
    function _executeBatchDeposit(
        address[] calldata vaults,
        uint256[] calldata amounts,
        BridgeBurn[] calldata burns,
        uint256 localTotal,
        uint256 burnTotal,
        uint256 before
    ) private {
        for (uint256 i = 0; i < vaults.length; i++) {
            uint256 sharesReceived = _depositToVault(vaults[i], amounts[i], msg.sender);
            emit Deposited(msg.sender, vaults[i], amounts[i], sharesReceived);
        }

        // hookData = msg.sender. A single approval covers every burn in the batch.
        if (burns.length > 0) usdc.forceApprove(tokenMessenger, burnTotal);
        for (uint256 i = 0; i < burns.length; i++) {
            _cctpBurn(burns[i].amount, burns[i].destDomain,
                burns[i].mintRecipient, burns[i].destinationCaller, burns[i].maxFee, burns[i].minFinalityThreshold,
                msg.sender);
            emit BridgeBurnInitiated(msg.sender, burns[i].amount, burns[i].destDomain, burns[i].mintRecipient);
        }
        if (burns.length > 0) usdc.forceApprove(tokenMessenger, 0);

        uint256 remainder = usdc.balanceOf(address(this)) - before;
        if (remainder > 0) usdc.safeTransfer(msg.sender, remainder);

        emit StrategyCreated(msg.sender, localTotal + burnTotal);
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
        (uint256 localTotal, uint256 burnTotal, uint256 before) =
            _validateBatchDeposit(vaults, amounts, burns);
        usdc.safeTransferFrom(msg.sender, address(this), localTotal + burnTotal);
        _executeBatchDeposit(vaults, amounts, burns, localTotal, burnTotal, before);
    }

    /// @notice Batch deposit into whitelisted vaults using a Permit2 signature for USDC.
    /// @dev Identical to `selfBatchDeposit()` but pulls USDC via Uniswap's canonical
    ///      Permit2 SignatureTransfer instead of a direct ERC20 `transferFrom`. The
    ///      user must have approved USDC to the Permit2 contract once (`PERMIT2`);
    ///      after that, every deposit is authorised purely by an off-chain EIP-712
    ///      signature. Permit2 itself enforces nonce uniqueness, deadline expiry,
    ///      and signature validity. The signed token MUST be USDC and the signed
    ///      amount must cover `sum(amounts) + sum(burns[i].amount)`; a non-USDC
    ///      token reverts (see `_permit2Pull`).
    /// @param vaults    Ordered list of vault addresses on the source chain. Each must be
    ///                  whitelisted. May be empty if all capital is bridged.
    /// @param amounts   USDC amounts corresponding 1:1 with `vaults`. Each must be > 0.
    /// @param burns     Array of CCTP burn parameters for cross-chain deposits.
    ///                  May be empty for single-chain deposits.
    /// @param permit    Permit2 `PermitTransferFrom` payload signed by msg.sender.
    /// @param signature EIP-712 signature authorising the Permit2 transfer.
    function selfBatchDepositPermit2(
        address[] calldata vaults,
        uint256[] calldata amounts,
        BridgeBurn[] calldata burns,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external nonReentrant {
        (uint256 localTotal, uint256 burnTotal, uint256 before) =
            _validateBatchDeposit(vaults, amounts, burns);
        _permit2Pull(permit, signature, localTotal + burnTotal);
        _executeBatchDeposit(vaults, amounts, burns, localTotal, burnTotal, before);
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
    ///      On a Morpho Vault V2 whose idle balance cannot cover the redeem, pass
    ///      `deallocs[i]` to free liquidity from that vault's adapters first, so the
    ///      exit does not depend on the executor. Pass empty outer arrays to skip
    ///      force-deallocation entirely (the common case).
    /// @param vaults           ERC4626 vault addresses to withdraw from.
    /// @param shares           Gross share amounts per vault (0 reverts).
    /// @param feeAmounts       Fee share amounts per vault, aligned with `vaults`. 0 = no fee.
    /// @param burns            Array of CCTP burn parameters for cross-chain bridge-back.
    ///                         May be empty for single-chain withdrawals.
    /// @param deallocs         Per-vault force-deallocation instructions. Either empty, or
    ///                         aligned 1:1 with `vaults` (inner arrays may be empty).
    /// @param maxPenaltyShares Per-vault cap on penalty shares, aligned with `deallocs`.
    function selfBatchWithdraw(
        address[] calldata vaults,
        uint256[] calldata shares,
        uint256[] calldata feeAmounts,
        BridgeBurn[] calldata burns,
        ForceDealloc[][] calldata deallocs,
        uint256[] calldata maxPenaltyShares
    ) external nonReentrant {
        if (vaults.length == 0 || shares.length != vaults.length) revert InvalidInput();
        if (feeAmounts.length != vaults.length) revert ArrayLengthMismatch();
        bool hasDeallocs = deallocs.length > 0;
        if (hasDeallocs && (deallocs.length != vaults.length || maxPenaltyShares.length != vaults.length)) {
            revert ArrayLengthMismatch();
        }
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

            // A zero share amount is rejected rather than treated as "full balance":
            // an implicit sentinel would drain the whole position of any user holding
            // a max approval.  (OZ audit finding L-06.)
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
            // Free adapter liquidity so an illiquid Vault V2 can still be exited.
            // The penalty burns from the shares already pulled above.
            if (hasDeallocs) {
                amt -= _forceDeallocate(vault, deallocs[i], amt, maxPenaltyShares[i], msg.sender);
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
            usdc.forceApprove(tokenMessenger, netUsdc);

            for (uint256 i = 0; i < burns.length; i++) {
                uint256 burnAmount = burns[i].amount == type(uint256).max ? netUsdc : burns[i].amount;
                if (burnAmount > netUsdc) revert InvalidInput();

                _cctpBurn(burnAmount, burns[i].destDomain,
                    burns[i].mintRecipient, burns[i].destinationCaller, burns[i].maxFee, burns[i].minFinalityThreshold,
                    msg.sender);
                emit BridgeBurnInitiated(msg.sender, burnAmount, burns[i].destDomain, burns[i].mintRecipient);
                netUsdc -= burnAmount;
            }

            usdc.forceApprove(tokenMessenger, 0);

            // Send any remainder to the user
            if (netUsdc > 0) {
                usdc.safeTransfer(msg.sender, netUsdc);
            }
        }
    }

    // -------------------------------------------------------------------------
    // User-callable: Standalone CCTP Bridge (caller-supplied fee)
    // -------------------------------------------------------------------------

    /// @notice Bridge USDC cross-chain to a wallet via CCTP V2, retaining `fee` USDC.
    /// @dev User-callable. Pulls `amount` USDC from msg.sender, retains `fee` in the
    ///      contract (sweepable by the owner via `sweep()`), and burns the remainder
    ///      via `depositForBurnWithHook` with the caller committed as the hookData
    ///      beneficiary.
    ///      Like the performance fee on `rebalance` / `withdrawAndBridge` /
    ///      `selfBatchWithdraw`, `fee` is computed off-chain and passed in rather
    ///      than fixed on-chain. The contract only enforces `fee < amount`; the
    ///      caller is the one paying it.
    ///      There is no `destinationCaller` parameter: it is always zero, so anyone
    ///      may relay the message and the mint always lands in `mintRecipient`'s
    ///      wallet. Allowing a caller-chosen destination caller would let a user
    ///      strand their own funds permanently, because only that address could ever
    ///      relay and this contract's `emergencyClaimBridge` could not reach it.
    /// @param amount               Total USDC to pull from the user (fee deducted from this).
    /// @param fee                  USDC retained by the contract. Must be < `amount`. May be 0.
    /// @param service              `BRIDGE_SELF_RELAY` (0) if the caller will complete the
    ///                             destination mint, `BRIDGE_SPONSORED_RELAY` (1) if we will.
    ///                             Recorded in `BridgeExecuted` so an indexer never has to
    ///                             infer the arrangement from the fee or from calldata.
    /// @param destDomain           CCTP destination domain ID (e.g. 6 = Base, 0 = Ethereum).
    /// @param mintRecipient        Address to receive the minted USDC on the destination chain.
    /// @param maxFee               Maximum fee the CCTP protocol may charge (0 for standard).
    /// @param minFinalityThreshold 0 = fast finality (seconds), 2000 = standard finality (full chain finality).
    function bridge(
        uint256 amount,
        uint256 fee,
        uint8   service,
        uint32  destDomain,
        address mintRecipient,
        uint256 maxFee,
        uint32  minFinalityThreshold
    ) external nonReentrant {
        _validateBridge(amount, fee, service, mintRecipient);
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        _bridgeBurnWithFee(amount, fee, service, destDomain, mintRecipient, maxFee, minFinalityThreshold);
    }

    /// @notice Bridge USDC cross-chain using a Permit2 signature instead of a direct approval.
    /// @dev Identical to `bridge()` but pulls USDC via Permit2 SignatureTransfer.
    ///      The user must have approved USDC to the canonical Permit2 contract once
    ///      (`PERMIT2`); after that, every bridge call is authorised purely by an
    ///      off-chain EIP-712 signature. The signed token MUST be USDC and the
    ///      signed amount must be >= `amount`; a non-USDC token reverts (see
    ///      `_permit2Pull`).
    /// @param amount               Total USDC to pull from the user (fee deducted from this).
    /// @param fee                  USDC retained by the contract. Must be < `amount`. May be 0.
    /// @param service              `BRIDGE_SELF_RELAY` (0) if the caller will complete the
    ///                             destination mint, `BRIDGE_SPONSORED_RELAY` (1) if we will.
    ///                             Recorded in `BridgeExecuted` so an indexer never has to
    ///                             infer the arrangement from the fee or from calldata.
    /// @param destDomain           CCTP destination domain ID (e.g. 6 = Base, 0 = Ethereum).
    /// @param mintRecipient        Address to receive the minted USDC on the destination chain.
    /// @param maxFee               Maximum fee the CCTP protocol may charge (0 for standard).
    /// @param minFinalityThreshold 0 = fast finality (seconds), 2000 = standard finality (full chain finality).
    /// @param permit               Permit2 `PermitTransferFrom` payload signed by msg.sender.
    /// @param signature            EIP-712 signature authorising the Permit2 transfer.
    function bridgePermit2(
        uint256 amount,
        uint256 fee,
        uint8   service,
        uint32  destDomain,
        address mintRecipient,
        uint256 maxFee,
        uint32  minFinalityThreshold,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external nonReentrant {
        _validateBridge(amount, fee, service, mintRecipient);
        _permit2Pull(permit, signature, amount);

        _bridgeBurnWithFee(amount, fee, service, destDomain, mintRecipient, maxFee, minFinalityThreshold);
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
        return vaultList;
    }

    /// @notice Check whether a specific vault address is currently whitelisted.
    /// @param vault The address to query.
    /// @return True if the vault is approved, false otherwise.
    function isVaultApproved(address vault) external view returns (bool) {
        return approvedVaults[vault];
    }
}

