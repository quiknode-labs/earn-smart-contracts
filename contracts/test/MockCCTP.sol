// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal mintable-token view used by MockMessageTransmitter. MockERC20
///      exposes a permissionless `mint()`, which lets the transmitter simulate
///      Circle minting USDC to the relay caller.
interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
}

/// @title MockTokenMessenger
/// @notice Test double for Circle's CCTP V2 TokenMessenger.
/// @dev `QuicknodeEarn._cctpBurn` invokes `depositForBurnWithHook` via a
///      low-level call and only checks `success`, discarding return data. This
///      mock simulates the burn by pulling the pre-approved USDC out of the
///      caller (the QuicknodeEarn contract) and records the last call so tests
///      can assert on the forwarded CCTP parameters and the hookData beneficiary.
contract MockTokenMessenger {
    IERC20 public immutable token;

    /// @notice When true, `depositForBurnWithHook` reverts (exercises `CctpBurnFailed`).
    bool public shouldRevert;

    // Last-call capture for assertions.
    uint256 public burnCount;
    uint256 public lastAmount;
    uint32  public lastDestDomain;
    bytes32 public lastMintRecipient;
    address public lastBurnToken;
    bytes32 public lastDestinationCaller;
    uint256 public lastMaxFee;
    uint32  public lastMinFinalityThreshold;
    bytes   public lastHookData;

    constructor(IERC20 _token) {
        token = _token;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external {
        require(!shouldRevert, "MockTokenMessenger: forced revert");

        // Simulate the burn by consuming the caller's pre-approved USDC.
        token.transferFrom(msg.sender, address(this), amount);

        burnCount++;
        lastAmount = amount;
        lastDestDomain = destinationDomain;
        lastMintRecipient = mintRecipient;
        lastBurnToken = burnToken;
        lastDestinationCaller = destinationCaller;
        lastMaxFee = maxFee;
        lastMinFinalityThreshold = minFinalityThreshold;
        lastHookData = hookData;
    }
}

/// @title MockMessageTransmitter
/// @notice Test double for Circle's CCTP V2 MessageTransmitter.
/// @dev `relayAndDeposit` and `emergencyClaimBridge` call `receiveMessage`,
///      which on a real chain causes Circle to mint USDC to the caller. This
///      mock mints a configurable amount of the test USDC to the caller and
///      returns a configurable success flag (false exercises `MessageRelayFailed`).
///      It deliberately ignores the message/attestation bytes — the contract's
///      beneficiary parsing is exercised end-to-end via the message argument,
///      not by this mock.
contract MockMessageTransmitter {
    IMintableERC20 public immutable token;

    uint256 public mintAmount;
    bool public succeed = true;

    constructor(IMintableERC20 _token) {
        token = _token;
    }

    function setMintAmount(uint256 v) external {
        mintAmount = v;
    }

    function setSucceed(bool v) external {
        succeed = v;
    }

    function receiveMessage(bytes calldata, bytes calldata) external returns (bool) {
        if (succeed) {
            token.mint(msg.sender, mintAmount);
        }
        return succeed;
    }
}
