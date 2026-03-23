import hre from "hardhat";
import { expect } from "chai";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { getAddress, parseUnits } from "viem";

describe("YieldRebalancer", function () {
  async function deployFixture() {
    const [owner, user, other] = await hre.viem.getWalletClients();
    const publicClient = await hre.viem.getPublicClient();

    // Deploy mock USDC (6 decimals)
    const usdc = await hre.viem.deployContract("MockERC20", [
      "USD Coin",
      "USDC",
      6,
    ]);

    // Deploy two mock ERC4626 vaults
    const vaultA = await hre.viem.deployContract("MockERC4626", [
      usdc.address,
      "Vault A Shares",
      "vA",
    ]);
    const vaultB = await hre.viem.deployContract("MockERC4626", [
      usdc.address,
      "Vault B Shares",
      "vB",
    ]);

    // Deploy YieldRebalancer with fee params
    // Use owner address as placeholder for aavePool/aUsdc (not exercised in non-Aave tests)
    // address(0) for messageTransmitter — CCTP not exercised in these tests
    const rebalancer = await hre.viem.deployContract("YieldRebalancer", [
      usdc.address,
      owner.account.address,   // aavePool placeholder
      owner.account.address,   // aUsdc placeholder
      "0x0000000000000000000000000000000000000000", // messageTransmitter (disabled)
      owner.account.address,   // owner
      [],                      // initialVaults
      50,                      // maxFeeBps: 0.50%
      owner.account.address,   // feeRecipient
    ]);

    // Mint USDC to user
    const mintAmount = parseUnits("10000", 6); // 10,000 USDC
    await usdc.write.mint([user.account.address, mintAmount]);

    return {
      rebalancer,
      usdc,
      vaultA,
      vaultB,
      owner,
      user,
      other,
      publicClient,
      mintAmount,
    };
  }

  describe("Deployment", function () {
    it("should set correct owner", async function () {
      const { rebalancer, owner } = await loadFixture(deployFixture);
      expect(getAddress(await rebalancer.read.owner())).to.equal(
        getAddress(owner.account.address)
      );
    });

    it("should set correct USDC address", async function () {
      const { rebalancer, usdc } = await loadFixture(deployFixture);
      expect(getAddress(await rebalancer.read.usdc())).to.equal(
        getAddress(usdc.address)
      );
    });

    it("should set maxFeeBps and feeRecipient", async function () {
      const { rebalancer, owner } = await loadFixture(deployFixture);
      expect(await rebalancer.read.maxFeeBps()).to.equal(50);
      expect(getAddress(await rebalancer.read.feeRecipient())).to.equal(
        getAddress(owner.account.address)
      );
    });

    it("should revert on zero USDC address", async function () {
      const [owner] = await hre.viem.getWalletClients();
      await expect(
        hre.viem.deployContract("YieldRebalancer", [
          "0x0000000000000000000000000000000000000000",
          owner.account.address,
          owner.account.address,
          "0x0000000000000000000000000000000000000000",
          owner.account.address,
          [],
          50,
          owner.account.address,
        ])
      ).to.be.rejectedWith("ZeroAddress");
    });

    it("should revert if maxFeeBps > 500", async function () {
      const [owner] = await hre.viem.getWalletClients();
      const usdc = await hre.viem.deployContract("MockERC20", ["USDC", "USDC", 6]);
      await expect(
        hre.viem.deployContract("YieldRebalancer", [
          usdc.address,
          owner.account.address,
          owner.account.address,
          "0x0000000000000000000000000000000000000000",
          owner.account.address,
          [],
          501,
          owner.account.address,
        ])
      ).to.be.rejectedWith("MaxFeeBpsTooHigh");
    });
  });

  describe("Vault Management", function () {
    it("should add vault to whitelist", async function () {
      const { rebalancer, vaultA } = await loadFixture(deployFixture);
      await rebalancer.write.addVault([vaultA.address]);

      expect(await rebalancer.read.isVaultApproved([vaultA.address])).to.be
        .true;
      const vaults = await rebalancer.read.getApprovedVaults();
      expect(vaults.length).to.equal(1);
      expect(getAddress(vaults[0])).to.equal(getAddress(vaultA.address));
    });

    it("should emit VaultAdded event", async function () {
      const { rebalancer, vaultA, publicClient } =
        await loadFixture(deployFixture);
      const hash = await rebalancer.write.addVault([vaultA.address]);
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      expect(receipt.status).to.equal("success");
    });

    it("should not double-add a vault", async function () {
      const { rebalancer, vaultA } = await loadFixture(deployFixture);
      await rebalancer.write.addVault([vaultA.address]);
      await rebalancer.write.addVault([vaultA.address]);

      const vaults = await rebalancer.read.getApprovedVaults();
      expect(vaults.length).to.equal(1);
    });

    it("should remove vault from whitelist", async function () {
      const { rebalancer, vaultA } = await loadFixture(deployFixture);
      await rebalancer.write.addVault([vaultA.address]);
      await rebalancer.write.removeVault([vaultA.address]);

      expect(await rebalancer.read.isVaultApproved([vaultA.address])).to.be
        .false;
      const vaults = await rebalancer.read.getApprovedVaults();
      expect(vaults.length).to.equal(0);
    });

    it("should revert removing non-approved vault", async function () {
      const { rebalancer, vaultA } = await loadFixture(deployFixture);
      await expect(
        rebalancer.write.removeVault([vaultA.address])
      ).to.be.rejectedWith("VaultNotApproved");
    });

    it("should revert adding zero address vault", async function () {
      const { rebalancer } = await loadFixture(deployFixture);
      await expect(
        rebalancer.write.addVault([
          "0x0000000000000000000000000000000000000000",
        ])
      ).to.be.rejectedWith("ZeroAddress");
    });

    it("non-owner cannot add vault", async function () {
      const { rebalancer, vaultA, other } = await loadFixture(deployFixture);
      const rebalancerAsOther = await hre.viem.getContractAt(
        "YieldRebalancer",
        rebalancer.address,
        { client: { wallet: other } }
      );
      await expect(
        rebalancerAsOther.write.addVault([vaultA.address])
      ).to.be.rejectedWith("OwnableUnauthorizedAccount");
    });

    it("non-owner cannot remove vault", async function () {
      const { rebalancer, vaultA, other } = await loadFixture(deployFixture);
      await rebalancer.write.addVault([vaultA.address]);
      const rebalancerAsOther = await hre.viem.getContractAt(
        "YieldRebalancer",
        rebalancer.address,
        { client: { wallet: other } }
      );
      await expect(
        rebalancerAsOther.write.removeVault([vaultA.address])
      ).to.be.rejectedWith("OwnableUnauthorizedAccount");
    });
  });

  describe("Deposit", function () {
    it("should deposit USDC into vault on behalf of user", async function () {
      const { rebalancer, usdc, vaultA, user } =
        await loadFixture(deployFixture);

      // Setup: add vault, user approves rebalancer
      await rebalancer.write.addVault([vaultA.address]);
      const depositAmount = parseUnits("1000", 6);

      // User approves rebalancer to spend USDC
      const usdcAsUser = await hre.viem.getContractAt(
        "MockERC20",
        usdc.address,
        { client: { wallet: user } }
      );
      await usdcAsUser.write.approve([rebalancer.address, depositAmount]);

      // Owner calls deposit on behalf of user
      await rebalancer.write.deposit([
        user.account.address,
        vaultA.address,
        depositAmount,
      ]);

      // Shares should be in user's wallet (not rebalancer)
      const userShares = await vaultA.read.balanceOf([user.account.address]);
      expect(userShares > 0n).to.be.true;

      // Rebalancer should hold zero shares
      const rebalancerShares = await vaultA.read.balanceOf([
        rebalancer.address,
      ]);
      expect(rebalancerShares).to.equal(0n);

      // USDC should be in the vault
      const vaultBalance = await usdc.read.balanceOf([vaultA.address]);
      expect(vaultBalance).to.equal(depositAmount);
    });

    it("should revert on non-whitelisted vault", async function () {
      const { rebalancer, usdc, vaultA, user } =
        await loadFixture(deployFixture);
      const depositAmount = parseUnits("1000", 6);

      // User approves but vault not whitelisted
      const usdcAsUser = await hre.viem.getContractAt(
        "MockERC20",
        usdc.address,
        { client: { wallet: user } }
      );
      await usdcAsUser.write.approve([rebalancer.address, depositAmount]);

      await expect(
        rebalancer.write.deposit([
          user.account.address,
          vaultA.address,
          depositAmount,
        ])
      ).to.be.rejectedWith("VaultNotApproved");
    });

    it("should revert on zero amount", async function () {
      const { rebalancer, vaultA, user } = await loadFixture(deployFixture);
      await rebalancer.write.addVault([vaultA.address]);

      await expect(
        rebalancer.write.deposit([user.account.address, vaultA.address, 0n])
      ).to.be.rejectedWith("ZeroAmount");
    });

    it("should revert on zero user address", async function () {
      const { rebalancer, vaultA } = await loadFixture(deployFixture);
      await rebalancer.write.addVault([vaultA.address]);

      await expect(
        rebalancer.write.deposit([
          "0x0000000000000000000000000000000000000000",
          vaultA.address,
          parseUnits("100", 6),
        ])
      ).to.be.rejectedWith("ZeroAddress");
    });

    it("non-owner cannot call deposit", async function () {
      const { rebalancer, usdc, vaultA, user, other } =
        await loadFixture(deployFixture);
      await rebalancer.write.addVault([vaultA.address]);
      const depositAmount = parseUnits("1000", 6);

      const usdcAsUser = await hre.viem.getContractAt(
        "MockERC20",
        usdc.address,
        { client: { wallet: user } }
      );
      await usdcAsUser.write.approve([rebalancer.address, depositAmount]);

      const rebalancerAsOther = await hre.viem.getContractAt(
        "YieldRebalancer",
        rebalancer.address,
        { client: { wallet: other } }
      );
      await expect(
        rebalancerAsOther.write.deposit([
          user.account.address,
          vaultA.address,
          depositAmount,
        ])
      ).to.be.rejectedWith("OwnableUnauthorizedAccount");
    });
  });

  describe("Rebalance", function () {
    async function depositedFixture() {
      const base = await deployFixture();
      const { rebalancer, usdc, vaultA, vaultB, user } = base;

      // Add both vaults
      await rebalancer.write.addVault([vaultA.address]);
      await rebalancer.write.addVault([vaultB.address]);

      // User approves rebalancer for USDC
      const depositAmount = parseUnits("1000", 6);
      const usdcAsUser = await hre.viem.getContractAt(
        "MockERC20",
        usdc.address,
        { client: { wallet: user } }
      );
      await usdcAsUser.write.approve([rebalancer.address, depositAmount]);

      // Deposit into vaultA
      await rebalancer.write.deposit([
        user.account.address,
        vaultA.address,
        depositAmount,
      ]);

      // User approves rebalancer to spend vaultA shares
      const vaultAAsUser = await hre.viem.getContractAt(
        "MockERC4626",
        vaultA.address,
        { client: { wallet: user } }
      );
      const userShares = await vaultA.read.balanceOf([user.account.address]);
      await vaultAAsUser.write.approve([rebalancer.address, userShares]);

      return { ...base, depositAmount, userShares };
    }

    it("should rebalance from vaultA to vaultB (feeBps=0, no fee)", async function () {
      const { rebalancer, usdc, vaultA, vaultB, user, userShares } =
        await loadFixture(depositedFixture);

      // Rebalance all shares from vaultA to vaultB with zero fee
      await rebalancer.write.rebalance([
        user.account.address,
        vaultA.address,
        vaultB.address,
        userShares,
        0,  // feeBps
      ]);

      // User should have zero vaultA shares
      const remainingA = await vaultA.read.balanceOf([user.account.address]);
      expect(remainingA).to.equal(0n);

      // User should have vaultB shares
      const sharesB = await vaultB.read.balanceOf([user.account.address]);
      expect(sharesB > 0n).to.be.true;

      // Rebalancer should hold nothing (no fee charged)
      const rebalancerUsdc = await usdc.read.balanceOf([rebalancer.address]);
      expect(rebalancerUsdc).to.equal(0n);
      const rebalancerA = await vaultA.read.balanceOf([rebalancer.address]);
      expect(rebalancerA).to.equal(0n);
      const rebalancerB = await vaultB.read.balanceOf([rebalancer.address]);
      expect(rebalancerB).to.equal(0n);
    });

    it("should collect fee USDC in contract when feeBps > 0", async function () {
      const { rebalancer, usdc, vaultA, vaultB, user, userShares, depositAmount } =
        await loadFixture(depositedFixture);

      // Rebalance with feeBps=5 (0.05%)
      await rebalancer.write.rebalance([
        user.account.address,
        vaultA.address,
        vaultB.address,
        userShares,
        5,  // feeBps
      ]);

      // Expected fee: 1000 USDC * 5 / 10000 = 0.5 USDC = 500000 raw
      const expectedFee = depositAmount * 5n / 10000n;

      // Contract should hold the fee
      const contractUsdc = await usdc.read.balanceOf([rebalancer.address]);
      expect(contractUsdc).to.equal(expectedFee);

      // User should have received reduced amount in vaultB
      const sharesB = await vaultB.read.balanceOf([user.account.address]);
      expect(sharesB > 0n).to.be.true;

      // User should have zero vaultA shares
      const remainingA = await vaultA.read.balanceOf([user.account.address]);
      expect(remainingA).to.equal(0n);
    });

    it("should deposit reduced amount into toVault after fee deduction", async function () {
      const { rebalancer, usdc, vaultA, vaultB, user, userShares, depositAmount } =
        await loadFixture(depositedFixture);

      const feeBps = 10; // 0.10%
      await rebalancer.write.rebalance([
        user.account.address,
        vaultA.address,
        vaultB.address,
        userShares,
        feeBps,
      ]);

      // vaultB should hold: depositAmount - feeAmount
      const feeAmount = depositAmount * BigInt(feeBps) / 10000n;
      const expectedInVaultB = depositAmount - feeAmount;
      const vaultBUsdcBalance = await usdc.read.balanceOf([vaultB.address]);
      expect(vaultBUsdcBalance).to.equal(expectedInVaultB);
    });

    it("should revert if feeBps exceeds maxFeeBps", async function () {
      const { rebalancer, vaultA, vaultB, user, userShares } =
        await loadFixture(depositedFixture);

      // maxFeeBps is 50; try 51
      await expect(
        rebalancer.write.rebalance([
          user.account.address,
          vaultA.address,
          vaultB.address,
          userShares,
          51,
        ])
      ).to.be.rejectedWith("FeeTooHigh");
    });

    it("should revert if fromVault not approved", async function () {
      const { rebalancer, vaultA, vaultB, user, userShares } =
        await loadFixture(depositedFixture);

      // Remove vaultA from whitelist
      await rebalancer.write.removeVault([vaultA.address]);

      await expect(
        rebalancer.write.rebalance([
          user.account.address,
          vaultA.address,
          vaultB.address,
          userShares,
          0,
        ])
      ).to.be.rejectedWith("VaultNotApproved");
    });

    it("should revert if toVault not approved", async function () {
      const { rebalancer, vaultA, vaultB, user, userShares } =
        await loadFixture(depositedFixture);

      // Remove vaultB from whitelist
      await rebalancer.write.removeVault([vaultB.address]);

      await expect(
        rebalancer.write.rebalance([
          user.account.address,
          vaultA.address,
          vaultB.address,
          userShares,
          0,
        ])
      ).to.be.rejectedWith("VaultNotApproved");
    });

    it("should revert on zero shares", async function () {
      const { rebalancer, vaultA, vaultB, user } =
        await loadFixture(depositedFixture);

      await expect(
        rebalancer.write.rebalance([
          user.account.address,
          vaultA.address,
          vaultB.address,
          0n,
          0,
        ])
      ).to.be.rejectedWith("ZeroAmount");
    });

    it("should revert on zero user address", async function () {
      const { rebalancer, vaultA, vaultB, userShares } =
        await loadFixture(depositedFixture);

      await expect(
        rebalancer.write.rebalance([
          "0x0000000000000000000000000000000000000000",
          vaultA.address,
          vaultB.address,
          userShares,
          0,
        ])
      ).to.be.rejectedWith("ZeroAddress");
    });

    it("non-owner cannot call rebalance", async function () {
      const { rebalancer, vaultA, vaultB, user, other, userShares } =
        await loadFixture(depositedFixture);

      const rebalancerAsOther = await hre.viem.getContractAt(
        "YieldRebalancer",
        rebalancer.address,
        { client: { wallet: other } }
      );
      await expect(
        rebalancerAsOther.write.rebalance([
          user.account.address,
          vaultA.address,
          vaultB.address,
          userShares,
          0,
        ])
      ).to.be.rejectedWith("OwnableUnauthorizedAccount");
    });

    it("removeVault prevents rebalancing to that vault", async function () {
      const { rebalancer, vaultA, vaultB, user, userShares } =
        await loadFixture(depositedFixture);

      // Remove vaultB, try to rebalance into it
      await rebalancer.write.removeVault([vaultB.address]);

      await expect(
        rebalancer.write.rebalance([
          user.account.address,
          vaultA.address,
          vaultB.address,
          userShares,
          0,
        ])
      ).to.be.rejectedWith("VaultNotApproved");
    });

    it("tiny rebalance where fee rounds to zero should not revert", async function () {
      const { rebalancer, usdc, vaultA, vaultB, user } =
        await loadFixture(depositedFixture);

      // Deposit 1 wei-equivalent (1 raw USDC unit = $0.000001)
      const tinyUsdc = 1n;
      const usdcAsUser = await hre.viem.getContractAt(
        "MockERC20",
        usdc.address,
        { client: { wallet: user } }
      );
      await usdc.write.mint([user.account.address, tinyUsdc]);
      await usdcAsUser.write.approve([rebalancer.address, tinyUsdc]);
      await rebalancer.write.deposit([user.account.address, vaultA.address, tinyUsdc]);

      const vaultAAsUser = await hre.viem.getContractAt(
        "MockERC4626",
        vaultA.address,
        { client: { wallet: user } }
      );
      const tinyShares = await vaultA.read.balanceOf([user.account.address]);
      await vaultAAsUser.write.approve([rebalancer.address, tinyShares]);

      // feeBps=5, amount=1 → fee = 1 * 5 / 10000 = 0 (rounds to zero in solidity)
      await expect(
        rebalancer.write.rebalance([
          user.account.address,
          vaultA.address,
          vaultB.address,
          tinyShares,
          5,
        ])
      ).to.not.be.rejected;

      // Contract holds zero fee (dust rounds to 0)
      const contractUsdc = await usdc.read.balanceOf([rebalancer.address]);
      expect(contractUsdc).to.equal(0n);
    });
  });

  describe("Fee Sweep", function () {
    async function feeAccruedFixture() {
      const base = await deployFixture();
      const { rebalancer, usdc, vaultA, vaultB, user } = base;

      await rebalancer.write.addVault([vaultA.address]);
      await rebalancer.write.addVault([vaultB.address]);

      const depositAmount = parseUnits("1000", 6);
      const usdcAsUser = await hre.viem.getContractAt(
        "MockERC20",
        usdc.address,
        { client: { wallet: user } }
      );
      await usdcAsUser.write.approve([rebalancer.address, depositAmount]);
      await rebalancer.write.deposit([user.account.address, vaultA.address, depositAmount]);

      const vaultAAsUser = await hre.viem.getContractAt(
        "MockERC4626",
        vaultA.address,
        { client: { wallet: user } }
      );
      const userShares = await vaultA.read.balanceOf([user.account.address]);
      await vaultAAsUser.write.approve([rebalancer.address, userShares]);

      // Rebalance with feeBps=5 to accrue fee
      await rebalancer.write.rebalance([
        user.account.address,
        vaultA.address,
        vaultB.address,
        userShares,
        5,
      ]);

      const feeAccrued = depositAmount * 5n / 10000n; // 500000 raw = 0.5 USDC
      return { ...base, depositAmount, userShares, feeAccrued };
    }

    it("owner can sweep fee USDC to a specified address", async function () {
      const { rebalancer, usdc, other, feeAccrued } =
        await loadFixture(feeAccruedFixture);

      const beforeBalance = await usdc.read.balanceOf([other.account.address]);
      await rebalancer.write.sweep([usdc.address, other.account.address]);
      const afterBalance = await usdc.read.balanceOf([other.account.address]);

      expect(afterBalance - beforeBalance).to.equal(feeAccrued);
      expect(await usdc.read.balanceOf([rebalancer.address])).to.equal(0n);
    });

    it("sweep with zero address sends to feeRecipient", async function () {
      const { rebalancer, usdc, owner, feeAccrued } =
        await loadFixture(feeAccruedFixture);

      const beforeBalance = await usdc.read.balanceOf([owner.account.address]);
      await rebalancer.write.sweep([
        usdc.address,
        "0x0000000000000000000000000000000000000000",
      ]);
      const afterBalance = await usdc.read.balanceOf([owner.account.address]);

      expect(afterBalance - beforeBalance).to.equal(feeAccrued);
    });

    it("non-owner cannot sweep", async function () {
      const { rebalancer, usdc, other } = await loadFixture(feeAccruedFixture);
      const rebalancerAsOther = await hre.viem.getContractAt(
        "YieldRebalancer",
        rebalancer.address,
        { client: { wallet: other } }
      );
      await expect(
        rebalancerAsOther.write.sweep([usdc.address, other.account.address])
      ).to.be.rejectedWith("OwnableUnauthorizedAccount");
    });
  });

  describe("Fee Admin", function () {
    it("setMaxFeeBps updates the cap", async function () {
      const { rebalancer } = await loadFixture(deployFixture);
      await rebalancer.write.setMaxFeeBps([100]);
      expect(await rebalancer.read.maxFeeBps()).to.equal(100);
    });

    it("setMaxFeeBps reverts above 500", async function () {
      const { rebalancer } = await loadFixture(deployFixture);
      await expect(
        rebalancer.write.setMaxFeeBps([501])
      ).to.be.rejectedWith("MaxFeeBpsTooHigh");
    });

    it("setMaxFeeBps allows exactly 500", async function () {
      const { rebalancer } = await loadFixture(deployFixture);
      await rebalancer.write.setMaxFeeBps([500]);
      expect(await rebalancer.read.maxFeeBps()).to.equal(500);
    });

    it("setFeeRecipient updates the recipient", async function () {
      const { rebalancer, other } = await loadFixture(deployFixture);
      await rebalancer.write.setFeeRecipient([other.account.address]);
      expect(getAddress(await rebalancer.read.feeRecipient())).to.equal(
        getAddress(other.account.address)
      );
    });

    it("setFeeRecipient reverts on zero address", async function () {
      const { rebalancer } = await loadFixture(deployFixture);
      await expect(
        rebalancer.write.setFeeRecipient([
          "0x0000000000000000000000000000000000000000",
        ])
      ).to.be.rejectedWith("ZeroAddress");
    });

    it("non-owner cannot call setMaxFeeBps", async function () {
      const { rebalancer, other } = await loadFixture(deployFixture);
      const rebalancerAsOther = await hre.viem.getContractAt(
        "YieldRebalancer",
        rebalancer.address,
        { client: { wallet: other } }
      );
      await expect(
        rebalancerAsOther.write.setMaxFeeBps([10])
      ).to.be.rejectedWith("OwnableUnauthorizedAccount");
    });

    it("non-owner cannot call setFeeRecipient", async function () {
      const { rebalancer, other } = await loadFixture(deployFixture);
      const rebalancerAsOther = await hre.viem.getContractAt(
        "YieldRebalancer",
        rebalancer.address,
        { client: { wallet: other } }
      );
      await expect(
        rebalancerAsOther.write.setFeeRecipient([other.account.address])
      ).to.be.rejectedWith("OwnableUnauthorizedAccount");
    });
  });

  describe("Exit Position", function () {
    it("user can exit without rebalancer", async function () {
      const { rebalancer, usdc, vaultA, user } =
        await loadFixture(deployFixture);

      // Setup: add vault, deposit
      await rebalancer.write.addVault([vaultA.address]);
      const depositAmount = parseUnits("1000", 6);

      const usdcAsUser = await hre.viem.getContractAt(
        "MockERC20",
        usdc.address,
        { client: { wallet: user } }
      );
      await usdcAsUser.write.approve([rebalancer.address, depositAmount]);

      await rebalancer.write.deposit([
        user.account.address,
        vaultA.address,
        depositAmount,
      ]);

      // User approves rebalancer for vault shares
      const vaultAAsUser = await hre.viem.getContractAt(
        "MockERC4626",
        vaultA.address,
        { client: { wallet: user } }
      );
      const shares = await vaultA.read.balanceOf([user.account.address]);
      await vaultAAsUser.write.approve([rebalancer.address, shares]);

      // Record USDC balance before
      const usdcBefore = await usdc.read.balanceOf([user.account.address]);

      // User calls exitPosition directly
      const rebalancerAsUser = await hre.viem.getContractAt(
        "YieldRebalancer",
        rebalancer.address,
        { client: { wallet: user } }
      );
      await rebalancerAsUser.write.exitPosition([vaultA.address]);

      // User should have USDC back
      const usdcAfter = await usdc.read.balanceOf([user.account.address]);
      expect(usdcAfter - usdcBefore).to.equal(depositAmount);

      // User should have zero vault shares
      const remainingShares = await vaultA.read.balanceOf([
        user.account.address,
      ]);
      expect(remainingShares).to.equal(0n);
    });

    it("should revert on non-approved vault", async function () {
      const { rebalancer, vaultA, user } = await loadFixture(deployFixture);

      const rebalancerAsUser = await hre.viem.getContractAt(
        "YieldRebalancer",
        rebalancer.address,
        { client: { wallet: user } }
      );
      await expect(
        rebalancerAsUser.write.exitPosition([vaultA.address])
      ).to.be.rejectedWith("VaultNotApproved");
    });

    it("should revert if user has zero shares", async function () {
      const { rebalancer, vaultA, other } = await loadFixture(deployFixture);
      await rebalancer.write.addVault([vaultA.address]);

      // other has no shares
      const rebalancerAsOther = await hre.viem.getContractAt(
        "YieldRebalancer",
        rebalancer.address,
        { client: { wallet: other } }
      );
      await expect(
        rebalancerAsOther.write.exitPosition([vaultA.address])
      ).to.be.rejectedWith("ZeroAmount");
    });
  });

  describe("View Functions", function () {
    it("getApprovedVaults returns all vaults", async function () {
      const { rebalancer, vaultA, vaultB } = await loadFixture(deployFixture);
      await rebalancer.write.addVault([vaultA.address]);
      await rebalancer.write.addVault([vaultB.address]);

      const vaults = await rebalancer.read.getApprovedVaults();
      expect(vaults.length).to.equal(2);
    });

    it("isVaultApproved returns correct status", async function () {
      const { rebalancer, vaultA, vaultB } = await loadFixture(deployFixture);
      await rebalancer.write.addVault([vaultA.address]);

      expect(await rebalancer.read.isVaultApproved([vaultA.address])).to.be
        .true;
      expect(await rebalancer.read.isVaultApproved([vaultB.address])).to.be
        .false;
    });

    it("vaultList is enumerable", async function () {
      const { rebalancer, vaultA, vaultB } = await loadFixture(deployFixture);
      await rebalancer.write.addVault([vaultA.address]);
      await rebalancer.write.addVault([vaultB.address]);

      const v0 = await rebalancer.read.vaultList([0n]);
      const v1 = await rebalancer.read.vaultList([1n]);
      expect(getAddress(v0)).to.equal(getAddress(vaultA.address));
      expect(getAddress(v1)).to.equal(getAddress(vaultB.address));
    });
  });

  describe("Ownership", function () {
    it("uses 2-step ownership transfer", async function () {
      const { rebalancer, other, owner } = await loadFixture(deployFixture);

      // Step 1: owner initiates transfer
      await rebalancer.write.transferOwnership([other.account.address]);

      // Still owned by original owner
      expect(getAddress(await rebalancer.read.owner())).to.equal(
        getAddress(owner.account.address)
      );

      // Step 2: new owner accepts
      const rebalancerAsOther = await hre.viem.getContractAt(
        "YieldRebalancer",
        rebalancer.address,
        { client: { wallet: other } }
      );
      await rebalancerAsOther.write.acceptOwnership();

      expect(getAddress(await rebalancer.read.owner())).to.equal(
        getAddress(other.account.address)
      );
    });
  });
});
