// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev CCTP V2 TokenMessenger stand-in: records `depositForBurnWithHook` calls
///      and pulls the burn amount so balances behave like a real burn. A failure
///      switch exercises the CctpBurnFailed path.
contract MockTokenMessengerV2 {
    uint256 public lastAmount;
    uint32  public lastDestDomain;
    bytes32 public lastMintRecipient;
    bytes32 public lastDestinationCaller;
    uint256 public lastMaxFee;
    uint32  public lastMinFinalityThreshold;
    bytes   public lastHookData;
    uint256 public burnCount;
    bool    public failNext;

    function setFailNext(bool failNext_) external {
        failNext = failNext_;
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
        require(!failNext, "MockTokenMessengerV2: forced failure");
        IERC20(burnToken).transferFrom(msg.sender, address(this), amount);
        lastAmount = amount;
        lastDestDomain = destinationDomain;
        lastMintRecipient = mintRecipient;
        lastDestinationCaller = destinationCaller;
        lastMaxFee = maxFee;
        lastMinFinalityThreshold = minFinalityThreshold;
        lastHookData = hookData;
        burnCount++;
    }
}
