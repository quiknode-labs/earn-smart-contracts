import hre from "hardhat";
import { expect } from "chai";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { parseUnits, encodeFunctionData, pad, maxUint256 } from "viem";

/**
 * CCTP V2 coverage for QuicknodeEarnProxy.
 *
 * The main suite (QuicknodeEarn.test.ts) deploys with CCTP disabled
 * (messageTransmitter == tokenMessenger == address(0)), so the cross-chain
 * paths — the most intricate and security-critical code in the contract — are
 * never exercised. This file wires the proxy to mock CCTP contracts
 * (contracts/test/MockCCTP.sol) and covers:
 *
 *   - relayAndDeposit: relay + deposit, remainder refund, beneficiary binding,
 *     and every revert (InvalidUser, short message, length mismatch, empty
 *     vaults, unapproved vault, missing allowance, short mint, relay failure,
 *     non-relayer).
 *   - emergencyClaimBridge: beneficiary claim + unauthorized/short/failed relay.
 *   - withdrawAndBridge: both allowed (mintRecipient, destinationCaller)
 *     pairings, a rejected pairing, hookData beneficiary binding, and reverts.
 *   - selfBatchDeposit / selfBatchWithdraw with CCTP burns: allowed and rejected
 *     pairings, the burn-all sentinel position rule, and zero-amount.
 *   - CCTP-disabled failure modes (zero transmitter / messenger).
 */
describe("QuicknodeEarn — CCTP", function () {
  const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
  const ZERO_BYTES32 =
    "0x0000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`;
  // bytes32(uint256(uint160(addr))) — the right-aligned 32-byte address word the
  // contract compares mintRecipient / destinationCaller against.
  function addrToBytes32(addr: string): `0x${string}` {
    return pad(addr as `0x${string}`, { size: 32 });
  }

  // Build a CCTP V2 message whose hookData beneficiary occupies bytes [376:408]
  // (148-byte header + 228-byte burn body = 376, then abi.encode(address)). This
  // matches the slice the contract decodes in relayAndDeposit / emergencyClaimBridge.
  function buildCctpMessage(beneficiary: string): `0x${string}` {
    const filler = "00".repeat(376);
    return `0x${filler}${addrToBytes32(beneficiary).slice(2)}` as `0x${string}`;
  }

  // BridgeBurn struct builder — defaults the constant fields (standard finality,
  // no fee, domain 6) so call sites show only the varying recipient/caller/amount.
  function burn(mintRecipient: `0x${string}`, destinationCaller: `0x${string}`, amount: bigint) {
    return { destDomain: 6, mintRecipient, destinationCaller, amount, maxFee: 0n, minFinalityThreshold: 0 };
  }

  // Mirrors the proxy-deploy helper in QuicknodeEarn.test.ts.
  async function deployBehindProxy(
    usdcAddr: `0x${string}`,
    msgTransmitter: `0x${string}`,
    tokenMessenger: `0x${string}`,
    ownerAddr: `0x${string}`,
    initialVaults: `0x${string}`[],
  ) {
    const impl = await hre.viem.deployContract("QuicknodeEarnProxy", [
      usdcAddr,
      msgTransmitter,
      tokenMessenger,
    ]);
    const initData = encodeFunctionData({
      abi: impl.abi,
      functionName: "initialize",
      args: [ownerAddr, initialVaults],
    });
    const proxy = await hre.viem.deployContract("ERC1967Proxy", [
      impl.address,
      initData,
    ]);
    return await hre.viem.getContractAt("QuicknodeEarnProxy", proxy.address);
  }

  // Fund `user`, open a vaultA position, and approve the vaultA share token —
  // the shared per-user setup both fixtures need.
  async function openVaultAPosition(rebalancer: any, usdc: any, vaultA: any, user: any) {
    const mintAmount = parseUnits("10000", 6);
    await usdc.write.mint([user.account.address, mintAmount]);

    const depositAmount = parseUnits("1000", 6);
    const usdcAsUser = await hre.viem.getContractAt("MockERC20", usdc.address, {
      client: { wallet: user },
    });
    await usdcAsUser.write.approve([rebalancer.address, mintAmount]);

    const rebalancerAsUser = await hre.viem.getContractAt("QuicknodeEarnProxy", rebalancer.address, {
      client: { wallet: user },
    });
    await rebalancerAsUser.write.selfBatchDeposit([[vaultA.address], [depositAmount], []]);

    const userShares = await vaultA.read.balanceOf([user.account.address]);

    const vaultAAsUser = await hre.viem.getContractAt("MockERC4626", vaultA.address, {
      client: { wallet: user },
    });
    await vaultAAsUser.write.approve([rebalancer.address, maxUint256]);

    return { rebalancerAsUser, userShares, mintAmount, depositAmount };
  }

  // CCTP wired to mocks; owner doubles as executor + relayer; one funded user
  // with an existing vaultA position and share approvals in place.
  async function cctpFixture() {
    const [owner, user, other] = await hre.viem.getWalletClients();
    const publicClient = await hre.viem.getPublicClient();

    const usdc = await hre.viem.deployContract("MockERC20", ["USD Coin", "USDC", 6]);
    const vaultA = await hre.viem.deployContract("MockERC4626", [usdc.address, "Vault A", "vA"]);
    const vaultB = await hre.viem.deployContract("MockERC4626", [usdc.address, "Vault B", "vB"]);

    const tokenMessenger = await hre.viem.deployContract("MockTokenMessenger", [usdc.address]);
    const messageTransmitter = await hre.viem.deployContract("MockMessageTransmitter", [usdc.address]);

    const rebalancer = await deployBehindProxy(
      usdc.address,
      messageTransmitter.address,
      tokenMessenger.address,
      owner.account.address,
      [vaultA.address, vaultB.address],
    );

    // Owner plays executor + relayer for these tests.
    await rebalancer.write.setExecutor([owner.account.address]);
    await rebalancer.write.setRelayer([owner.account.address]);

    // Fund the user and open a vaultA position so withdraw/bridge paths have shares.
    const { rebalancerAsUser, userShares, mintAmount, depositAmount } =
      await openVaultAPosition(rebalancer, usdc, vaultA, user);

    return {
      rebalancer,
      rebalancerAsUser,
      usdc,
      vaultA,
      vaultB,
      tokenMessenger,
      messageTransmitter,
      owner,
      user,
      other,
      publicClient,
      mintAmount,
      depositAmount,
      userShares,
    };
  }

  // CCTP disabled (zero addresses), with a user position — for failure-mode tests.
  async function disabledCctpFixture() {
    const [owner, user, other] = await hre.viem.getWalletClients();

    const usdc = await hre.viem.deployContract("MockERC20", ["USD Coin", "USDC", 6]);
    const vaultA = await hre.viem.deployContract("MockERC4626", [usdc.address, "Vault A", "vA"]);

    const rebalancer = await deployBehindProxy(
      usdc.address,
      ZERO_ADDRESS as `0x${string}`,
      ZERO_ADDRESS as `0x${string}`,
      owner.account.address,
      [vaultA.address],
    );
    await rebalancer.write.setExecutor([owner.account.address]);
    await rebalancer.write.setRelayer([owner.account.address]);

    const { rebalancerAsUser, userShares, depositAmount } =
      await openVaultAPosition(rebalancer, usdc, vaultA, user);

    return { rebalancer, rebalancerAsUser, usdc, vaultA, owner, user, other, depositAmount, userShares };
  }

  // --- relayAndDeposit (relayer-only) ---

  describe("relayAndDeposit", function () {
    it("relays a CCTP message and deposits the minted USDC into the vault for the user", async function () {
      const { rebalancer, messageTransmitter, usdc, vaultA, user, depositAmount } =
        await loadFixture(cctpFixture);
      await messageTransmitter.write.setMintAmount([depositAmount]);
      const message = buildCctpMessage(user.account.address);

      const before = await vaultA.read.balanceOf([user.account.address]);
      await rebalancer.write.relayAndDeposit([
        message,
        "0x",
        user.account.address,
        [vaultA.address],
        [depositAmount],
      ]);
      const after = await vaultA.read.balanceOf([user.account.address]);

      expect(after > before).to.be.true;
      expect(await usdc.read.balanceOf([rebalancer.address])).to.equal(0n);
    });

    it("returns the remainder (CCTP fee buffer) to the user", async function () {
      const { rebalancer, messageTransmitter, usdc, vaultA, user, depositAmount } =
        await loadFixture(cctpFixture);
      const extra = parseUnits("5", 6);
      await messageTransmitter.write.setMintAmount([depositAmount + extra]);
      const message = buildCctpMessage(user.account.address);

      const userBefore = await usdc.read.balanceOf([user.account.address]);
      await rebalancer.write.relayAndDeposit([
        message,
        "0x",
        user.account.address,
        [vaultA.address],
        [depositAmount],
      ]);
      const userAfter = await usdc.read.balanceOf([user.account.address]);

      expect(userAfter - userBefore).to.equal(extra);
      expect(await usdc.read.balanceOf([rebalancer.address])).to.equal(0n);
    });

    it("reverts InvalidUser when the hookData beneficiary differs from the user", async function () {
      const { rebalancer, messageTransmitter, vaultA, user, other, depositAmount } =
        await loadFixture(cctpFixture);
      await messageTransmitter.write.setMintAmount([depositAmount]);
      const message = buildCctpMessage(other.account.address); // beneficiary = other
      await expect(
        rebalancer.write.relayAndDeposit([
          message,
          "0x",
          user.account.address,
          [vaultA.address],
          [depositAmount],
        ]),
      ).to.be.rejectedWith("InvalidUser");
    });

    it("reverts InvalidInput on a message shorter than 408 bytes", async function () {
      const { rebalancer, vaultA, user, depositAmount } = await loadFixture(cctpFixture);
      const shortMessage = ("0x" + "00".repeat(100)) as `0x${string}`;
      await expect(
        rebalancer.write.relayAndDeposit([
          shortMessage,
          "0x",
          user.account.address,
          [vaultA.address],
          [depositAmount],
        ]),
      ).to.be.rejectedWith("InvalidInput");
    });

    it("reverts ArrayLengthMismatch when vaults and amounts differ", async function () {
      const { rebalancer, vaultA, vaultB, user } = await loadFixture(cctpFixture);
      const message = buildCctpMessage(user.account.address);
      await expect(
        rebalancer.write.relayAndDeposit([
          message,
          "0x",
          user.account.address,
          [vaultA.address, vaultB.address],
          [1n],
        ]),
      ).to.be.rejectedWith("ArrayLengthMismatch");
    });

    it("reverts InvalidInput on empty vaults", async function () {
      const { rebalancer, user } = await loadFixture(cctpFixture);
      const message = buildCctpMessage(user.account.address);
      await expect(
        rebalancer.write.relayAndDeposit([message, "0x", user.account.address, [], []]),
      ).to.be.rejectedWith("InvalidInput");
    });

    it("reverts VaultNotApproved for a non-whitelisted destination vault", async function () {
      const { rebalancer, messageTransmitter, vaultA, user, depositAmount } =
        await loadFixture(cctpFixture);
      await messageTransmitter.write.setMintAmount([depositAmount]);
      await rebalancer.write.removeVault([vaultA.address]);
      const message = buildCctpMessage(user.account.address);
      await expect(
        rebalancer.write.relayAndDeposit([
          message,
          "0x",
          user.account.address,
          [vaultA.address],
          [depositAmount],
        ]),
      ).to.be.rejectedWith("VaultNotApproved");
    });

    it("reverts InvalidInput when the user has not approved the destination vault", async function () {
      // `other` is the beneficiary but never approved vaultA's share token.
      const { rebalancer, messageTransmitter, vaultA, other, depositAmount } =
        await loadFixture(cctpFixture);
      await messageTransmitter.write.setMintAmount([depositAmount]);
      const message = buildCctpMessage(other.account.address);
      await expect(
        rebalancer.write.relayAndDeposit([
          message,
          "0x",
          other.account.address,
          [vaultA.address],
          [depositAmount],
        ]),
      ).to.be.rejectedWith("InvalidInput");
    });

    it("reverts ZeroAmount when minted USDC is less than the requested total", async function () {
      const { rebalancer, messageTransmitter, vaultA, user, depositAmount } =
        await loadFixture(cctpFixture);
      await messageTransmitter.write.setMintAmount([depositAmount - 1n]);
      const message = buildCctpMessage(user.account.address);
      await expect(
        rebalancer.write.relayAndDeposit([
          message,
          "0x",
          user.account.address,
          [vaultA.address],
          [depositAmount],
        ]),
      ).to.be.rejectedWith("ZeroAmount");
    });

    it("reverts MessageRelayFailed when the transmitter returns false", async function () {
      const { rebalancer, messageTransmitter, vaultA, user, depositAmount } =
        await loadFixture(cctpFixture);
      await messageTransmitter.write.setSucceed([false]);
      const message = buildCctpMessage(user.account.address);
      await expect(
        rebalancer.write.relayAndDeposit([
          message,
          "0x",
          user.account.address,
          [vaultA.address],
          [depositAmount],
        ]),
      ).to.be.rejectedWith("MessageRelayFailed");
    });

    it("only the relayer can call", async function () {
      const { rebalancer, vaultA, user, other, depositAmount } = await loadFixture(cctpFixture);
      const message = buildCctpMessage(user.account.address);
      const asOther = await hre.viem.getContractAt("QuicknodeEarnProxy", rebalancer.address, {
        client: { wallet: other },
      });
      // Depending on the viem version, a modifier revert surfaces either the
      // decoded name or the raw 4-byte selector (0x3c20627b == UnauthorizedRelayer()).
      await expect(
        asOther.write.relayAndDeposit([
          message,
          "0x",
          user.account.address,
          [vaultA.address],
          [depositAmount],
        ]),
      ).to.be.rejectedWith(/UnauthorizedRelayer|0x3c20627b/);
    });
  });

  // --- emergencyClaimBridge (user-callable escape hatch) ---

  describe("emergencyClaimBridge", function () {
    it("lets the hookData beneficiary claim minted USDC straight to their wallet", async function () {
      const { rebalancer, rebalancerAsUser, messageTransmitter, usdc, user, depositAmount } =
        await loadFixture(cctpFixture);
      await messageTransmitter.write.setMintAmount([depositAmount]);
      const message = buildCctpMessage(user.account.address);

      const before = await usdc.read.balanceOf([user.account.address]);
      await rebalancerAsUser.write.emergencyClaimBridge([message, "0x"]);
      const after = await usdc.read.balanceOf([user.account.address]);

      expect(after - before).to.equal(depositAmount);
      expect(await usdc.read.balanceOf([rebalancer.address])).to.equal(0n);
    });

    it("reverts Unauthorized when the caller is not the beneficiary", async function () {
      const { rebalancer, messageTransmitter, user, other, depositAmount } =
        await loadFixture(cctpFixture);
      await messageTransmitter.write.setMintAmount([depositAmount]);
      const message = buildCctpMessage(user.account.address); // beneficiary = user
      const asOther = await hre.viem.getContractAt("QuicknodeEarnProxy", rebalancer.address, {
        client: { wallet: other },
      });
      await expect(asOther.write.emergencyClaimBridge([message, "0x"])).to.be.rejectedWith(
        "Unauthorized",
      );
    });

    it("reverts InvalidInput on a short message", async function () {
      const { rebalancerAsUser } = await loadFixture(cctpFixture);
      const shortMessage = ("0x" + "00".repeat(100)) as `0x${string}`;
      await expect(
        rebalancerAsUser.write.emergencyClaimBridge([shortMessage, "0x"]),
      ).to.be.rejectedWith("InvalidInput");
    });

    it("reverts MessageRelayFailed when the transmitter returns false", async function () {
      const { rebalancerAsUser, messageTransmitter, user } = await loadFixture(cctpFixture);
      await messageTransmitter.write.setSucceed([false]);
      const message = buildCctpMessage(user.account.address);
      await expect(
        rebalancerAsUser.write.emergencyClaimBridge([message, "0x"]),
      ).to.be.rejectedWith("MessageRelayFailed");
    });
  });

  // --- withdrawAndBridge (executor-only) ---

  describe("withdrawAndBridge", function () {
    it("burns via the (this, this) rebalance pairing and binds hookData to the user", async function () {
      const { rebalancer, tokenMessenger, usdc, vaultA, user, userShares } =
        await loadFixture(cctpFixture);
      const selfB = addrToBytes32(rebalancer.address);

      await rebalancer.write.withdrawAndBridge([
        user.account.address,
        vaultA.address,
        userShares,
        [],
        [],
        6,
        selfB,
        selfB,
        0n,
        0,
      ]);

      expect(await tokenMessenger.read.burnCount()).to.equal(1n);
      expect((await tokenMessenger.read.lastMintRecipient()).toLowerCase()).to.equal(
        selfB.toLowerCase(),
      );
      // hookData == abi.encode(user) — the beneficiary binding relayAndDeposit verifies.
      expect((await tokenMessenger.read.lastHookData()).toLowerCase()).to.equal(
        addrToBytes32(user.account.address).toLowerCase(),
      );
      expect(await usdc.read.balanceOf([rebalancer.address])).to.equal(0n);
    });

    it("burns via the (user, 0) permissionless-exit pairing", async function () {
      const { rebalancer, tokenMessenger, vaultA, user, userShares } =
        await loadFixture(cctpFixture);
      const userB = addrToBytes32(user.account.address);

      await rebalancer.write.withdrawAndBridge([
        user.account.address,
        vaultA.address,
        userShares,
        [],
        [],
        6,
        userB,
        ZERO_BYTES32,
        0n,
        0,
      ]);

      expect(await tokenMessenger.read.burnCount()).to.equal(1n);
      expect((await tokenMessenger.read.lastDestinationCaller()).toLowerCase()).to.equal(
        ZERO_BYTES32.toLowerCase(),
      );
    });

    it("reverts InvalidInput on a disallowed (mintRecipient, destinationCaller) pairing", async function () {
      const { rebalancer, vaultA, user, other, userShares } = await loadFixture(cctpFixture);
      const otherB = addrToBytes32(other.account.address); // neither (this,this) nor (user,0)
      await expect(
        rebalancer.write.withdrawAndBridge([
          user.account.address,
          vaultA.address,
          userShares,
          [],
          [],
          6,
          otherB,
          ZERO_BYTES32,
          0n,
          0,
        ]),
      ).to.be.rejectedWith("InvalidInput");
    });

    it("reverts ZeroAmount on zero shares", async function () {
      const { rebalancer, vaultA, user } = await loadFixture(cctpFixture);
      const selfB = addrToBytes32(rebalancer.address);
      await expect(
        rebalancer.write.withdrawAndBridge([
          user.account.address,
          vaultA.address,
          0n,
          [],
          [],
          6,
          selfB,
          selfB,
          0n,
          0,
        ]),
      ).to.be.rejectedWith("ZeroAmount");
    });

    it("reverts ArrayLengthMismatch on mismatched fee arrays", async function () {
      const { rebalancer, vaultA, user, userShares } = await loadFixture(cctpFixture);
      const selfB = addrToBytes32(rebalancer.address);
      await expect(
        rebalancer.write.withdrawAndBridge([
          user.account.address,
          vaultA.address,
          userShares,
          [vaultA.address],
          [],
          6,
          selfB,
          selfB,
          0n,
          0,
        ]),
      ).to.be.rejectedWith("ArrayLengthMismatch");
    });

    it("reverts CctpBurnFailed when the token messenger reverts", async function () {
      const { rebalancer, tokenMessenger, vaultA, user, userShares } =
        await loadFixture(cctpFixture);
      await tokenMessenger.write.setShouldRevert([true]);
      const selfB = addrToBytes32(rebalancer.address);
      await expect(
        rebalancer.write.withdrawAndBridge([
          user.account.address,
          vaultA.address,
          userShares,
          [],
          [],
          6,
          selfB,
          selfB,
          0n,
          0,
        ]),
      ).to.be.rejectedWith("CctpBurnFailed");
    });

    it("only the executor can call", async function () {
      const { rebalancer, vaultA, user, other, userShares } = await loadFixture(cctpFixture);
      const selfB = addrToBytes32(rebalancer.address);
      const asOther = await hre.viem.getContractAt("QuicknodeEarnProxy", rebalancer.address, {
        client: { wallet: other },
      });
      // viem may report the decoded name or the raw selector
      // (0x83906042 == UnauthorizedExecutor()).
      await expect(
        asOther.write.withdrawAndBridge([
          user.account.address,
          vaultA.address,
          userShares,
          [],
          [],
          6,
          selfB,
          selfB,
          0n,
          0,
        ]),
      ).to.be.rejectedWith(/UnauthorizedExecutor|0x83906042/);
    });
  });

  // --- selfBatchDeposit with CCTP burns (user-callable) ---

  describe("selfBatchDeposit with CCTP burns", function () {
    it("deposits locally and burns cross-chain via the (this, this) pairing", async function () {
      const { rebalancer, rebalancerAsUser, tokenMessenger, usdc, vaultA, depositAmount } =
        await loadFixture(cctpFixture);
      const selfB = addrToBytes32(rebalancer.address);
      const burnAmount = parseUnits("500", 6);

      await rebalancerAsUser.write.selfBatchDeposit([
        [vaultA.address],
        [depositAmount],
        [burn(selfB, selfB, burnAmount)],
      ]);

      expect(await tokenMessenger.read.burnCount()).to.equal(1n);
      expect(await tokenMessenger.read.lastAmount()).to.equal(burnAmount);
      expect(await usdc.read.balanceOf([rebalancer.address])).to.equal(0n);
    });

    it("supports the (msg.sender, 0) direct-mint pairing with no local vaults", async function () {
      const { rebalancerAsUser, tokenMessenger, user } = await loadFixture(cctpFixture);
      const senderB = addrToBytes32(user.account.address);
      const burnAmount = parseUnits("250", 6);

      await rebalancerAsUser.write.selfBatchDeposit([
        [],
        [],
        [burn(senderB, ZERO_BYTES32, burnAmount)],
      ]);

      expect(await tokenMessenger.read.burnCount()).to.equal(1n);
      expect(await tokenMessenger.read.lastAmount()).to.equal(burnAmount);
    });

    it("reverts InvalidInput on a disallowed burn pairing", async function () {
      const { rebalancerAsUser, other } = await loadFixture(cctpFixture);
      const otherB = addrToBytes32(other.account.address);
      await expect(
        rebalancerAsUser.write.selfBatchDeposit([
          [],
          [],
          [burn(otherB, ZERO_BYTES32, parseUnits("100", 6))],
        ]),
      ).to.be.rejectedWith("InvalidInput");
    });

    it("reverts ZeroAmount on a zero burn amount", async function () {
      const { rebalancerAsUser, rebalancer } = await loadFixture(cctpFixture);
      const selfB = addrToBytes32(rebalancer.address);
      await expect(
        rebalancerAsUser.write.selfBatchDeposit([
          [],
          [],
          [burn(selfB, selfB, 0n)],
        ]),
      ).to.be.rejectedWith("ZeroAmount");
    });
  });

  // --- selfBatchWithdraw with CCTP burns (user-callable) ---

  describe("selfBatchWithdraw with CCTP burns", function () {
    it("redeems and bridges back via (msg.sender, 0) with the burn-all sentinel", async function () {
      const { rebalancer, rebalancerAsUser, tokenMessenger, usdc, vaultA, user, userShares } =
        await loadFixture(cctpFixture);
      const senderB = addrToBytes32(user.account.address);

      await rebalancerAsUser.write.selfBatchWithdraw([
        [vaultA.address],
        [userShares],
        [0n],
        [burn(senderB, ZERO_BYTES32, maxUint256)],
      ]);

      expect(await tokenMessenger.read.burnCount()).to.equal(1n);
      expect((await tokenMessenger.read.lastAmount()) > 0n).to.be.true;
      expect(await usdc.read.balanceOf([rebalancer.address])).to.equal(0n);
    });

    it("reverts InvalidInput when mintRecipient is not the caller", async function () {
      const { rebalancerAsUser, vaultA, other, userShares } = await loadFixture(cctpFixture);
      const otherB = addrToBytes32(other.account.address);
      await expect(
        rebalancerAsUser.write.selfBatchWithdraw([
          [vaultA.address],
          [userShares],
          [0n],
          [burn(otherB, ZERO_BYTES32, maxUint256)],
        ]),
      ).to.be.rejectedWith("InvalidInput");
    });

    it("reverts InvalidInput when the burn-all sentinel is not the final entry", async function () {
      const { rebalancerAsUser, vaultA, user, userShares } = await loadFixture(cctpFixture);
      const senderB = addrToBytes32(user.account.address);
      await expect(
        rebalancerAsUser.write.selfBatchWithdraw([
          [vaultA.address],
          [userShares],
          [0n],
          [
            // sentinel (maxUint256) in a non-final position → reverts
            burn(senderB, ZERO_BYTES32, maxUint256),
            burn(senderB, ZERO_BYTES32, 1n),
          ],
        ]),
      ).to.be.rejectedWith("InvalidInput");
    });
  });

  // --- CCTP disabled (zero addresses) ---

  describe("CCTP disabled (zero addresses)", function () {
    it("withdrawAndBridge reverts when tokenMessenger is unset", async function () {
      // The burn path forceApprove()s the (zero) tokenMessenger before reaching
      // _cctpBurn's ZeroAddress guard, so the transaction reverts either way.
      const { rebalancer, vaultA, user, userShares } = await loadFixture(disabledCctpFixture);
      const selfB = addrToBytes32(rebalancer.address);
      await expect(
        rebalancer.write.withdrawAndBridge([
          user.account.address,
          vaultA.address,
          userShares,
          [],
          [],
          6,
          selfB,
          selfB,
          0n,
          0,
        ]),
      ).to.be.rejected;
    });

    it("selfBatchDeposit with a burn reverts when tokenMessenger is unset", async function () {
      const { rebalancerAsUser, rebalancer } = await loadFixture(disabledCctpFixture);
      const selfB = addrToBytes32(rebalancer.address);
      await expect(
        rebalancerAsUser.write.selfBatchDeposit([
          [],
          [],
          [burn(selfB, selfB, parseUnits("100", 6))],
        ]),
      ).to.be.rejected;
    });

    it("relayAndDeposit reverts when messageTransmitter is unset", async function () {
      const { rebalancer, vaultA, user, depositAmount } = await loadFixture(disabledCctpFixture);
      const message = buildCctpMessage(user.account.address);
      await expect(
        rebalancer.write.relayAndDeposit([
          message,
          "0x",
          user.account.address,
          [vaultA.address],
          [depositAmount],
        ]),
      ).to.be.rejected;
    });
  });
});
