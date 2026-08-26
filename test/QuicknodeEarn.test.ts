import hre from "hardhat";
import { expect } from "chai";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { getAddress, parseUnits, encodeFunctionData, padHex, decodeAbiParameters, maxUint256 } from "viem";

describe("QuicknodeEarn", function () {
  const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

  /**
   * Deploy QuicknodeEarnProxy behind an ERC1967 proxy (UUPS pattern).
   * Returns a contract handle to the proxy using the QuicknodeEarnProxy ABI.
   */
  async function deployBehindProxy(
    usdcAddr: `0x${string}`,
    msgTransmitter: `0x${string}`,
    tokenMessenger: `0x${string}`,
    ownerAddr: `0x${string}`,
    initialVaults: `0x${string}`[],
  ) {
    // 1. Deploy implementation (immutables set in constructor)
    const impl = await hre.viem.deployContract("QuicknodeEarnProxy", [
      usdcAddr,
      msgTransmitter,
      tokenMessenger,
    ]);

    // 2. Encode initialize() calldata
    const initData = encodeFunctionData({
      abi: impl.abi,
      functionName: "initialize",
      args: [ownerAddr, initialVaults],
    });

    // 3. Deploy ERC1967Proxy wrapping the implementation
    const proxy = await hre.viem.deployContract("ERC1967Proxy", [
      impl.address,
      initData,
    ]);

    // 4. Return a contract handle to the proxy using the QuicknodeEarnProxy ABI
    return await hre.viem.getContractAt("QuicknodeEarnProxy", proxy.address);
  }

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

    // Deploy QuicknodeEarn behind proxy
    // address(0) for messageTransmitter / tokenMessenger — CCTP not exercised in these tests
    const rebalancer = await deployBehindProxy(
      usdc.address,
      ZERO_ADDRESS as `0x${string}`, // messageTransmitter (disabled)
      ZERO_ADDRESS as `0x${string}`, // tokenMessenger (disabled)
      owner.account.address, // owner
      [],                    // initialVaults
    );

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

  // --- Deployment ---

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

    it("should set messageTransmitter to zero when disabled", async function () {
      const { rebalancer } = await loadFixture(deployFixture);
      expect(getAddress(await rebalancer.read.messageTransmitter())).to.equal(
        getAddress(ZERO_ADDRESS)
      );
    });

    it("should revert on zero USDC address", async function () {
      await expect(
        hre.viem.deployContract("QuicknodeEarnProxy", [
          ZERO_ADDRESS,
          ZERO_ADDRESS,
          ZERO_ADDRESS,
        ])
      ).to.be.rejectedWith("ZeroAddress");
    });

    it("should revert on zero owner in initialize", async function () {
      const usdc = await hre.viem.deployContract("MockERC20", ["USDC", "USDC", 6]);
      await expect(
        deployBehindProxy(
          usdc.address,
          ZERO_ADDRESS as `0x${string}`,
          ZERO_ADDRESS as `0x${string}`,
          ZERO_ADDRESS as `0x${string}`,
          [],
        )
      ).to.be.rejectedWith("ZeroAddress");
    });

    it("should seed initial vaults via initialize", async function () {
      const [owner] = await hre.viem.getWalletClients();
      const usdc = await hre.viem.deployContract("MockERC20", ["USDC", "USDC", 6]);
      const vault = await hre.viem.deployContract("MockERC4626", [usdc.address, "V", "V"]);
      const rebalancer = await deployBehindProxy(
        usdc.address,
        ZERO_ADDRESS as `0x${string}`,
        ZERO_ADDRESS as `0x${string}`,
        owner.account.address,
        [vault.address],
      );
      expect(await rebalancer.read.isVaultApproved([vault.address])).to.be.true;
      const vaults = await rebalancer.read.getApprovedVaults();
      expect(vaults.length).to.equal(1);
    });

    it("should skip zero addresses and duplicates in initial vaults", async function () {
      const [owner] = await hre.viem.getWalletClients();
      const usdc = await hre.viem.deployContract("MockERC20", ["USDC", "USDC", 6]);
      const vault = await hre.viem.deployContract("MockERC4626", [usdc.address, "V", "V"]);
      const rebalancer = await deployBehindProxy(
        usdc.address,
        ZERO_ADDRESS as `0x${string}`,
        ZERO_ADDRESS as `0x${string}`,
        owner.account.address,
        [vault.address, ZERO_ADDRESS as `0x${string}`, vault.address], // dup + zero
      );
      const vaults = await rebalancer.read.getApprovedVaults();
      expect(vaults.length).to.equal(1);
    });
  });

  // --- Vault Management ---

  describe("Vault Management", function () {
    it("should add vault to whitelist", async function () {
      const { rebalancer, vaultA } = await loadFixture(deployFixture);
      await rebalancer.write.addVault([vaultA.address]);

      expect(await rebalancer.read.isVaultApproved([vaultA.address])).to.be.true;
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

    it("should batch-add multiple vaults", async function () {
      const { rebalancer, vaultA, vaultB } = await loadFixture(deployFixture);
      await rebalancer.write.batchAddVaults([[vaultA.address, vaultB.address]]);

      expect(await rebalancer.read.isVaultApproved([vaultA.address])).to.be.true;
      expect(await rebalancer.read.isVaultApproved([vaultB.address])).to.be.true;
      const vaults = await rebalancer.read.getApprovedVaults();
      expect(vaults.length).to.equal(2);
    });

    it("batchAddVaults reverts on zero address", async function () {
      const { rebalancer, vaultA } = await loadFixture(deployFixture);
      await expect(
        rebalancer.write.batchAddVaults([[vaultA.address, ZERO_ADDRESS]])
      ).to.be.rejectedWith("ZeroAddress");
    });

    it("should remove vault from whitelist", async function () {
      const { rebalancer, vaultA } = await loadFixture(deployFixture);
      await rebalancer.write.addVault([vaultA.address]);
      await rebalancer.write.removeVault([vaultA.address]);

      expect(await rebalancer.read.isVaultApproved([vaultA.address])).to.be.false;
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
        rebalancer.write.addVault([ZERO_ADDRESS])
      ).to.be.rejectedWith("ZeroAddress");
    });

    it("non-owner cannot add vault", async function () {
      const { rebalancer, vaultA, other } = await loadFixture(deployFixture);
      const rebalancerAsOther = await hre.viem.getContractAt(
        "QuicknodeEarnProxy",
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
        "QuicknodeEarnProxy",
        rebalancer.address,
        { client: { wallet: other } }
      );
      await expect(
        rebalancerAsOther.write.removeVault([vaultA.address])
      ).to.be.rejectedWith("OwnableUnauthorizedAccount");
    });
  });

  // --- Role Management ---

  describe("Role Management", function () {
    it("owner can set executor", async function () {
      const { rebalancer, other } = await loadFixture(deployFixture);
      await rebalancer.write.setExecutor([other.account.address]);
      expect(getAddress(await rebalancer.read.executor())).to.equal(
        getAddress(other.account.address)
      );
    });

    it("owner can set relayer", async function () {
      const { rebalancer, other } = await loadFixture(deployFixture);
      await rebalancer.write.setRelayer([other.account.address]);
      expect(getAddress(await rebalancer.read.relayer())).to.equal(
        getAddress(other.account.address)
      );
    });

    it("non-owner cannot set executor", async function () {
      const { rebalancer, other } = await loadFixture(deployFixture);
      const rebalancerAsOther = await hre.viem.getContractAt(
        "QuicknodeEarnProxy",
        rebalancer.address,
        { client: { wallet: other } }
      );
      await expect(
        rebalancerAsOther.write.setExecutor([other.account.address])
      ).to.be.rejectedWith("OwnableUnauthorizedAccount");
    });

    it("non-owner cannot set relayer", async function () {
      const { rebalancer, other } = await loadFixture(deployFixture);
      const rebalancerAsOther = await hre.viem.getContractAt(
        "QuicknodeEarnProxy",
        rebalancer.address,
        { client: { wallet: other } }
      );
      await expect(
        rebalancerAsOther.write.setRelayer([other.account.address])
      ).to.be.rejectedWith("OwnableUnauthorizedAccount");
    });

    it("executor and relayer default to zero address", async function () {
      const { rebalancer } = await loadFixture(deployFixture);
      expect(getAddress(await rebalancer.read.executor())).to.equal(
        getAddress(ZERO_ADDRESS)
      );
      expect(getAddress(await rebalancer.read.relayer())).to.equal(
        getAddress(ZERO_ADDRESS)
      );
    });
  });

  // --- Rebalance ---

  describe("Rebalance", function () {
    async function depositedFixture() {
      const base = await deployFixture();
      const { rebalancer, usdc, vaultA, vaultB, user, owner } = base;

      await rebalancer.write.addVault([vaultA.address]);
      await rebalancer.write.addVault([vaultB.address]);

      // Set the owner as executor so it can call rebalance
      await rebalancer.write.setExecutor([owner.account.address]);

      const depositAmount = parseUnits("1000", 6);
      const usdcAsUser = await hre.viem.getContractAt(
        "MockERC20",
        usdc.address,
        { client: { wallet: user } }
      );
      await usdcAsUser.write.approve([rebalancer.address, depositAmount]);

      // Use selfBatchDeposit (user-callable) to set up position
      const rebalancerAsUser = await hre.viem.getContractAt(
        "QuicknodeEarnProxy",
        rebalancer.address,
        { client: { wallet: user } }
      );
      await rebalancerAsUser.write.selfBatchDeposit([
        [vaultA.address],
        [depositAmount],
        [],
      ]);

      // User approves rebalancer to spend vaultA shares
      const vaultAAsUser = await hre.viem.getContractAt(
        "MockERC4626",
        vaultA.address,
        { client: { wallet: user } }
      );
      const userShares = await vaultA.read.balanceOf([user.account.address]);
      await vaultAAsUser.write.approve([rebalancer.address, userShares * 2n]); // extra for fees

      // User approves rebalancer to spend vaultB shares (required by toVault allowance check)
      const vaultBAsUser = await hre.viem.getContractAt(
        "MockERC4626",
        vaultB.address,
        { client: { wallet: user } }
      );
      await vaultBAsUser.write.approve([rebalancer.address, userShares * 2n]);

      return { ...base, depositAmount, userShares };
    }

    it("should rebalance from vaultA to vaultB (no fee)", async function () {
      const { rebalancer, usdc, vaultA, vaultB, user, userShares } =
        await loadFixture(depositedFixture);

      // Rebalance with empty fee arrays
      await rebalancer.write.rebalance([
        user.account.address,
        vaultA.address,
        vaultB.address,
        userShares,
        [],  // feeVaults
        [],  // feeAmounts
        [],  // deallocs
        0n,  // maxPenaltyShares
      ]);

      // User should have zero vaultA shares
      const remainingA = await vaultA.read.balanceOf([user.account.address]);
      expect(remainingA).to.equal(0n);

      // User should have vaultB shares
      const sharesB = await vaultB.read.balanceOf([user.account.address]);
      expect(sharesB > 0n).to.be.true;

      // Rebalancer should hold nothing
      const rebalancerUsdc = await usdc.read.balanceOf([rebalancer.address]);
      expect(rebalancerUsdc).to.equal(0n);
    });

    it("should collect fee shares during rebalance", async function () {
      const { rebalancer, vaultA, vaultB, user, userShares } =
        await loadFixture(depositedFixture);

      // Fee: take 10 shares from vaultA as performance fee
      const feeShares = userShares / 100n; // 1% of shares

      await rebalancer.write.rebalance([
        user.account.address,
        vaultA.address,
        vaultB.address,
        userShares - feeShares, // net shares to move
        [vaultA.address],       // feeVaults
        [feeShares],            // feeAmounts
        [],                     // deallocs
        0n,                     // maxPenaltyShares
      ]);

      // Rebalancer should hold fee shares of vaultA
      const rebalancerSharesA = await vaultA.read.balanceOf([rebalancer.address]);
      expect(rebalancerSharesA).to.equal(feeShares);
    });

    it("should succeed when fromVault is delisted (source-side not checked)", async function () {
      const { rebalancer, vaultA, vaultB, user, userShares } =
        await loadFixture(depositedFixture);

      await rebalancer.write.removeVault([vaultA.address]);

      // Rebalance should succeed — only toVault must be whitelisted
      await rebalancer.write.rebalance([
        user.account.address,
        vaultA.address,
        vaultB.address,
        userShares,
        [],
        [],
        [],
        0n,
      ]);

      const remainingA = await vaultA.read.balanceOf([user.account.address]);
      expect(remainingA).to.equal(0n);
      const sharesB = await vaultB.read.balanceOf([user.account.address]);
      expect(sharesB > 0n).to.be.true;
    });

    it("should revert if toVault not approved", async function () {
      const { rebalancer, vaultA, vaultB, user, userShares } =
        await loadFixture(depositedFixture);

      await rebalancer.write.removeVault([vaultB.address]);

      await expect(
        rebalancer.write.rebalance([
          user.account.address,
          vaultA.address,
          vaultB.address,
          userShares,
          [],
          [],
          [],
          0n,
        ])
      ).to.be.rejectedWith("VaultNotApproved");
    });


    it("non-executor cannot call rebalance", async function () {
      const { rebalancer, vaultA, vaultB, user, other, userShares } =
        await loadFixture(depositedFixture);

      const rebalancerAsOther = await hre.viem.getContractAt(
        "QuicknodeEarnProxy",
        rebalancer.address,
        { client: { wallet: other } }
      );
      await expect(
        rebalancerAsOther.write.rebalance([
          user.account.address,
          vaultA.address,
          vaultB.address,
          userShares,
          [],
          [],
          [],
          0n,
        ])
      ).to.be.rejectedWith("0x83906042"); // UnauthorizedExecutor()
    });
  });

  // --- selfBatchDeposit ---

  describe("selfBatchDeposit", function () {
    it("should deposit into multiple vaults in one transaction", async function () {
      const { rebalancer, usdc, vaultA, vaultB, user } =
        await loadFixture(deployFixture);

      await rebalancer.write.addVault([vaultA.address]);
      await rebalancer.write.addVault([vaultB.address]);

      const amountA = parseUnits("500", 6);
      const amountB = parseUnits("300", 6);

      const usdcAsUser = await hre.viem.getContractAt(
        "MockERC20",
        usdc.address,
        { client: { wallet: user } }
      );
      await usdcAsUser.write.approve([rebalancer.address, amountA + amountB]);

      const rebalancerAsUser = await hre.viem.getContractAt(
        "QuicknodeEarnProxy",
        rebalancer.address,
        { client: { wallet: user } }
      );
      await rebalancerAsUser.write.selfBatchDeposit([
        [vaultA.address, vaultB.address],
        [amountA, amountB],
        [],
      ]);

      // User should have shares in both vaults
      const sharesA = await vaultA.read.balanceOf([user.account.address]);
      expect(sharesA > 0n).to.be.true;
      const sharesB = await vaultB.read.balanceOf([user.account.address]);
      expect(sharesB > 0n).to.be.true;

      // USDC should be in each vault
      expect(await usdc.read.balanceOf([vaultA.address])).to.equal(amountA);
      expect(await usdc.read.balanceOf([vaultB.address])).to.equal(amountB);
    });

    it("should revert on non-whitelisted vault", async function () {
      const { rebalancer, usdc, vaultA, user } =
        await loadFixture(deployFixture);

      const amount = parseUnits("100", 6);
      const usdcAsUser = await hre.viem.getContractAt(
        "MockERC20",
        usdc.address,
        { client: { wallet: user } }
      );
      await usdcAsUser.write.approve([rebalancer.address, amount]);

      const rebalancerAsUser = await hre.viem.getContractAt(
        "QuicknodeEarnProxy",
        rebalancer.address,
        { client: { wallet: user } }
      );
      await expect(
        rebalancerAsUser.write.selfBatchDeposit([
          [vaultA.address],
          [amount],
          [],
        ])
      ).to.be.rejectedWith("VaultNotApproved");
    });

    it("should revert on mismatched array lengths", async function () {
      const { rebalancer, vaultA, user } = await loadFixture(deployFixture);
      await rebalancer.write.addVault([vaultA.address]);

      const rebalancerAsUser = await hre.viem.getContractAt(
        "QuicknodeEarnProxy",
        rebalancer.address,
        { client: { wallet: user } }
      );
      await expect(
        rebalancerAsUser.write.selfBatchDeposit([
          [vaultA.address],
          [parseUnits("100", 6), parseUnits("200", 6)],
          [],
        ])
      ).to.be.rejectedWith("InvalidInput");
    });

    it("should revert on empty arrays", async function () {
      const { rebalancer, user } = await loadFixture(deployFixture);

      const rebalancerAsUser = await hre.viem.getContractAt(
        "QuicknodeEarnProxy",
        rebalancer.address,
        { client: { wallet: user } }
      );
      await expect(
        rebalancerAsUser.write.selfBatchDeposit([[], [], []])
      ).to.be.rejectedWith("InvalidInput");
    });

    it("should revert on zero amount", async function () {
      const { rebalancer, vaultA, user } = await loadFixture(deployFixture);
      await rebalancer.write.addVault([vaultA.address]);

      const rebalancerAsUser = await hre.viem.getContractAt(
        "QuicknodeEarnProxy",
        rebalancer.address,
        { client: { wallet: user } }
      );
      await expect(
        rebalancerAsUser.write.selfBatchDeposit([
          [vaultA.address],
          [0n],
          [],
        ])
      ).to.be.rejectedWith("ZeroAmount");
    });
  });

  // --- selfBatchWithdraw ---

  describe("selfBatchWithdraw", function () {
    async function depositedMultiFixture() {
      const base = await deployFixture();
      const { rebalancer, usdc, vaultA, vaultB, user } = base;

      await rebalancer.write.addVault([vaultA.address]);
      await rebalancer.write.addVault([vaultB.address]);

      const amountA = parseUnits("500", 6);
      const amountB = parseUnits("300", 6);

      const usdcAsUser = await hre.viem.getContractAt(
        "MockERC20",
        usdc.address,
        { client: { wallet: user } }
      );
      await usdcAsUser.write.approve([rebalancer.address, amountA + amountB]);

      const rebalancerAsUser = await hre.viem.getContractAt(
        "QuicknodeEarnProxy",
        rebalancer.address,
        { client: { wallet: user } }
      );
      await rebalancerAsUser.write.selfBatchDeposit([
        [vaultA.address, vaultB.address],
        [amountA, amountB],
        [],
      ]);

      const sharesA = await vaultA.read.balanceOf([user.account.address]);
      const sharesB = await vaultB.read.balanceOf([user.account.address]);

      // Approve rebalancer to spend vault shares
      const vaultAAsUser = await hre.viem.getContractAt(
        "MockERC4626",
        vaultA.address,
        { client: { wallet: user } }
      );
      const vaultBAsUser = await hre.viem.getContractAt(
        "MockERC4626",
        vaultB.address,
        { client: { wallet: user } }
      );
      await vaultAAsUser.write.approve([rebalancer.address, sharesA]);
      await vaultBAsUser.write.approve([rebalancer.address, sharesB]);

      return { ...base, amountA, amountB, sharesA, sharesB, rebalancerAsUser };
    }

    it("should withdraw from multiple vaults (no fees)", async function () {
      const { usdc, vaultA, vaultB, user, rebalancerAsUser, sharesA, sharesB } =
        await loadFixture(depositedMultiFixture);

      const usdcBefore = await usdc.read.balanceOf([user.account.address]);

      await rebalancerAsUser.write.selfBatchWithdraw([
        [vaultA.address, vaultB.address],
        [sharesA, sharesB],
        [0n, 0n],  // no fees
        [],        // no burns
        [],
        [],
      ]);

      // User should get USDC back
      const usdcAfter = await usdc.read.balanceOf([user.account.address]);
      expect(usdcAfter - usdcBefore).to.equal(parseUnits("800", 6));

      // User should have zero shares
      expect(await vaultA.read.balanceOf([user.account.address])).to.equal(0n);
      expect(await vaultB.read.balanceOf([user.account.address])).to.equal(0n);
    });

    it("should withdraw with fees deducted as vault shares", async function () {
      const { rebalancer, usdc, vaultA, vaultB, user, rebalancerAsUser, sharesA, sharesB } =
        await loadFixture(depositedMultiFixture);

      const feeA = sharesA / 100n; // 1% fee from vaultA

      const usdcBefore = await usdc.read.balanceOf([user.account.address]);

      await rebalancerAsUser.write.selfBatchWithdraw([
        [vaultA.address, vaultB.address],
        [sharesA, sharesB],
        [feeA, 0n],
        [],  // no burns
        [],
        [],
      ]);

      // Rebalancer should hold feeA shares of vaultA
      const heldA = await vaultA.read.balanceOf([rebalancer.address]);
      expect(heldA).to.equal(feeA);

      // User gets reduced USDC (fee shares not redeemed to user)
      const usdcAfter = await usdc.read.balanceOf([user.account.address]);
      expect(usdcAfter > usdcBefore).to.be.true;
    });

    it("should revert with ZeroAmount when shares[i] == 0 (L-06: sentinel removed)", async function () {
      const { vaultA, vaultB, rebalancerAsUser } =
        await loadFixture(depositedMultiFixture);

      // Per OZ audit L-06, the (shares[i] == 0 → full balance) sentinel was
      // removed to close the max-approval footgun. Callers must pass an
      // explicit gross share amount; a zero entry now reverts.
      await expect(
        rebalancerAsUser.write.selfBatchWithdraw([
          [vaultA.address, vaultB.address],
          [0n, 0n],
          [0n, 0n],
          [],
          [],
          [],
        ])
      ).to.be.rejectedWith("ZeroAmount");
    });

    it("should succeed when vault is delisted (source-side not checked on withdraw)", async function () {
      const { rebalancer, usdc, vaultA, user, sharesA, rebalancerAsUser } =
        await loadFixture(depositedMultiFixture);

      await rebalancer.write.removeVault([vaultA.address]);

      const usdcBefore = await usdc.read.balanceOf([user.account.address]);

      // Withdraw should succeed — whitelist only checked on deposits
      await rebalancerAsUser.write.selfBatchWithdraw([
        [vaultA.address],
        [sharesA],
        [0n],
        [],  // no burns
        [],
        [],
      ]);

      const usdcAfter = await usdc.read.balanceOf([user.account.address]);
      expect(usdcAfter > usdcBefore).to.be.true;
    });

    it("should revert on mismatched array lengths", async function () {
      const { rebalancerAsUser, vaultA, sharesA } =
        await loadFixture(depositedMultiFixture);

      await expect(
        rebalancerAsUser.write.selfBatchWithdraw([
          [vaultA.address],
          [sharesA],
          [0n, 0n],  // mismatched
          [],  // no burns
          [],
          [],
        ])
      ).to.be.rejectedWith("ArrayLengthMismatch");
    });

    it("should revert if fee >= shares", async function () {
      const { rebalancerAsUser, vaultA, sharesA } =
        await loadFixture(depositedMultiFixture);

      await expect(
        rebalancerAsUser.write.selfBatchWithdraw([
          [vaultA.address],
          [sharesA],
          [sharesA],  // fee == shares, should revert
          [],  // no burns
          [],
          [],
        ])
      ).to.be.rejectedWith("InvalidInput");
    });

    it("should revert on empty vaults array", async function () {
      const { rebalancerAsUser } = await loadFixture(depositedMultiFixture);

      await expect(
        rebalancerAsUser.write.selfBatchWithdraw([[], [], [], [], [], []])
      ).to.be.rejectedWith("InvalidInput");
    });
  });

  // --- Sweep ---

  describe("Sweep", function () {
    async function feeAccruedFixture() {
      const base = await deployFixture();
      const { rebalancer, usdc, vaultA, vaultB, user, owner } = base;

      await rebalancer.write.addVault([vaultA.address]);
      await rebalancer.write.addVault([vaultB.address]);

      // Set the owner as executor so it can call rebalance
      await rebalancer.write.setExecutor([owner.account.address]);

      const depositAmount = parseUnits("1000", 6);
      const usdcAsUser = await hre.viem.getContractAt(
        "MockERC20",
        usdc.address,
        { client: { wallet: user } }
      );
      await usdcAsUser.write.approve([rebalancer.address, depositAmount]);

      // Use selfBatchDeposit (user-callable) to set up position
      const rebalancerAsUser = await hre.viem.getContractAt(
        "QuicknodeEarnProxy",
        rebalancer.address,
        { client: { wallet: user } }
      );
      await rebalancerAsUser.write.selfBatchDeposit([
        [vaultA.address],
        [depositAmount],
        [],
      ]);

      // User approves rebalancer for vault shares (extra for fee)
      const vaultAAsUser = await hre.viem.getContractAt(
        "MockERC4626",
        vaultA.address,
        { client: { wallet: user } }
      );
      const userShares = await vaultA.read.balanceOf([user.account.address]);
      await vaultAAsUser.write.approve([rebalancer.address, userShares]);

      // User approves rebalancer to spend vaultB shares (required by toVault allowance check)
      const vaultBAsUser = await hre.viem.getContractAt(
        "MockERC4626",
        vaultB.address,
        { client: { wallet: user } }
      );
      await vaultBAsUser.write.approve([rebalancer.address, userShares]);

      // Rebalance with fee to accrue fee shares in the contract (owner is executor)
      const feeShares = userShares / 100n; // 1%
      await rebalancer.write.rebalance([
        user.account.address,
        vaultA.address,
        vaultB.address,
        userShares - feeShares,
        [vaultA.address],
        [feeShares],
        [],
        0n,
      ]);

      return { ...base, depositAmount, userShares, feeShares };
    }

    it("owner can sweep fee shares to owner address", async function () {
      const { rebalancer, vaultA, owner, feeShares } =
        await loadFixture(feeAccruedFixture);

      const beforeBalance = await vaultA.read.balanceOf([owner.account.address]);
      await rebalancer.write.sweep([vaultA.address, feeShares]);
      const afterBalance = await vaultA.read.balanceOf([owner.account.address]);

      expect(afterBalance - beforeBalance).to.equal(feeShares);
    });

    it("should revert on zero amount", async function () {
      const { rebalancer, vaultA } = await loadFixture(feeAccruedFixture);

      await expect(
        rebalancer.write.sweep([vaultA.address, 0n])
      ).to.be.rejectedWith("ZeroAmount");
    });

    it("non-owner cannot sweep", async function () {
      const { rebalancer, vaultA, other, feeShares } =
        await loadFixture(feeAccruedFixture);

      const rebalancerAsOther = await hre.viem.getContractAt(
        "QuicknodeEarnProxy",
        rebalancer.address,
        { client: { wallet: other } }
      );
      await expect(
        rebalancerAsOther.write.sweep([vaultA.address, feeShares])
      ).to.be.rejectedWith("OwnableUnauthorizedAccount");
    });

  });

  // --- View Functions ---

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

      expect(await rebalancer.read.isVaultApproved([vaultA.address])).to.be.true;
      expect(await rebalancer.read.isVaultApproved([vaultB.address])).to.be.false;
    });

    it("getApprovedVaults returns vaults in order", async function () {
      const { rebalancer, vaultA, vaultB } = await loadFixture(deployFixture);
      await rebalancer.write.addVault([vaultA.address]);
      await rebalancer.write.addVault([vaultB.address]);

      const vaults = await rebalancer.read.getApprovedVaults();
      expect(vaults.length).to.equal(2);
      expect(getAddress(vaults[0])).to.equal(getAddress(vaultA.address));
      expect(getAddress(vaults[1])).to.equal(getAddress(vaultB.address));
    });
  });

  // --- Ownership ---

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
        "QuicknodeEarnProxy",
        rebalancer.address,
        { client: { wallet: other } }
      );
      await rebalancerAsOther.write.acceptOwnership();

      expect(getAddress(await rebalancer.read.owner())).to.equal(
        getAddress(other.account.address)
      );
    });
  });

  // --- UUPS Upgrade ---

  describe("UUPS Upgrade", function () {
    it("owner can upgrade implementation", async function () {
      const { rebalancer, usdc, vaultA, owner } = await loadFixture(deployFixture);

      // Add a vault and set executor to verify state survives upgrade
      await rebalancer.write.addVault([vaultA.address]);
      await rebalancer.write.setExecutor([owner.account.address]);

      // Deploy a new implementation
      const newImpl = await hre.viem.deployContract("QuicknodeEarnProxy", [
        usdc.address,
        ZERO_ADDRESS,
        ZERO_ADDRESS,
      ]);

      // Upgrade
      await rebalancer.write.upgradeToAndCall([newImpl.address, "0x"]);

      // Verify state is preserved through the upgrade
      expect(await rebalancer.read.isVaultApproved([vaultA.address])).to.be.true;
      expect(getAddress(await rebalancer.read.executor())).to.equal(
        getAddress(owner.account.address)
      );
      expect(getAddress(await rebalancer.read.owner())).to.equal(
        getAddress(owner.account.address)
      );
    });

    it("non-owner cannot upgrade", async function () {
      const { rebalancer, usdc, other } = await loadFixture(deployFixture);

      const newImpl = await hre.viem.deployContract("QuicknodeEarnProxy", [
        usdc.address,
        ZERO_ADDRESS,
        ZERO_ADDRESS,
      ]);

      const rebalancerAsOther = await hre.viem.getContractAt(
        "QuicknodeEarnProxy",
        rebalancer.address,
        { client: { wallet: other } }
      );
      await expect(
        rebalancerAsOther.write.upgradeToAndCall([newImpl.address, "0x"])
      ).to.be.rejectedWith("OwnableUnauthorizedAccount");
    });

    it("implementation cannot be initialized directly", async function () {
      const { usdc, owner } = await loadFixture(deployFixture);

      const impl = await hre.viem.deployContract("QuicknodeEarnProxy", [
        usdc.address,
        ZERO_ADDRESS,
        ZERO_ADDRESS,
      ]);

      // InvalidInitialization() selector = 0xf92ee8a9
      await expect(
        impl.write.initialize([owner.account.address, []])
      ).to.be.rejectedWith("0xf92ee8a9");
    });
  });

  // --- ERC-7201 Storage Isolation ---

  describe("ERC-7201 Storage", function () {
    it("state persists across upgrades (namespaced storage)", async function () {
      const { rebalancer, usdc, vaultA, vaultB, owner, user } =
        await loadFixture(deployFixture);

      // Set up state: vaults, roles
      await rebalancer.write.addVault([vaultA.address]);
      await rebalancer.write.addVault([vaultB.address]);
      await rebalancer.write.setExecutor([user.account.address]);
      await rebalancer.write.setRelayer([owner.account.address]);

      // Deploy new impl and upgrade
      const newImpl = await hre.viem.deployContract("QuicknodeEarnProxy", [
        usdc.address,
        ZERO_ADDRESS,
        ZERO_ADDRESS,
      ]);
      await rebalancer.write.upgradeToAndCall([newImpl.address, "0x"]);

      // All ERC-7201 namespaced state must survive
      const vaults = await rebalancer.read.getApprovedVaults();
      expect(vaults.length).to.equal(2);
      expect(await rebalancer.read.isVaultApproved([vaultA.address])).to.be.true;
      expect(await rebalancer.read.isVaultApproved([vaultB.address])).to.be.true;
      expect(getAddress(await rebalancer.read.executor())).to.equal(
        getAddress(user.account.address)
      );
      expect(getAddress(await rebalancer.read.relayer())).to.equal(
        getAddress(owner.account.address)
      );
    });

    it("ownership state persists across upgrades (OZ namespaced storage)", async function () {
      const { rebalancer, usdc, owner } = await loadFixture(deployFixture);

      const newImpl = await hre.viem.deployContract("QuicknodeEarnProxy", [
        usdc.address,
        ZERO_ADDRESS,
        ZERO_ADDRESS,
      ]);
      await rebalancer.write.upgradeToAndCall([newImpl.address, "0x"]);

      expect(getAddress(await rebalancer.read.owner())).to.equal(
        getAddress(owner.account.address)
      );
    });

    it("functional operations work after upgrade", async function () {
      const { rebalancer, usdc, vaultA, vaultB, user, owner } =
        await loadFixture(deployFixture);

      await rebalancer.write.addVault([vaultA.address]);
      await rebalancer.write.addVault([vaultB.address]);
      await rebalancer.write.setExecutor([owner.account.address]);

      // Deposit as user
      const depositAmount = parseUnits("1000", 6);
      const usdcAsUser = await hre.viem.getContractAt(
        "MockERC20", usdc.address, { client: { wallet: user } }
      );
      await usdcAsUser.write.approve([rebalancer.address, depositAmount]);

      const rebalancerAsUser = await hre.viem.getContractAt(
        "QuicknodeEarnProxy", rebalancer.address, { client: { wallet: user } }
      );
      await rebalancerAsUser.write.selfBatchDeposit([
        [vaultA.address], [depositAmount], [],
      ]);

      // Upgrade
      const newImpl = await hre.viem.deployContract("QuicknodeEarnProxy", [
        usdc.address, ZERO_ADDRESS, ZERO_ADDRESS,
      ]);
      await rebalancer.write.upgradeToAndCall([newImpl.address, "0x"]);

      // Approve shares for rebalance after upgrade
      const vaultAAsUser = await hre.viem.getContractAt(
        "MockERC4626", vaultA.address, { client: { wallet: user } }
      );
      const vaultBAsUser = await hre.viem.getContractAt(
        "MockERC4626", vaultB.address, { client: { wallet: user } }
      );
      const userShares = await vaultA.read.balanceOf([user.account.address]);
      await vaultAAsUser.write.approve([rebalancer.address, userShares]);
      await vaultBAsUser.write.approve([rebalancer.address, userShares]);

      // Rebalance should work after upgrade
      await rebalancer.write.rebalance([
        user.account.address,
        vaultA.address,
        vaultB.address,
        userShares,
        [],
        [],
        [],
        0n,
      ]);

      expect(await vaultA.read.balanceOf([user.account.address])).to.equal(0n);
      const sharesB = await vaultB.read.balanceOf([user.account.address]);
      expect(sharesB > 0n).to.be.true;
    });
  });

  // --- Input Validation (Finding #6) ---

  describe("Input Validation", function () {
    it("rebalance reverts on zero shares", async function () {
      const { rebalancer, vaultA, vaultB, owner, user } =
        await loadFixture(deployFixture);

      await rebalancer.write.addVault([vaultA.address]);
      await rebalancer.write.addVault([vaultB.address]);
      await rebalancer.write.setExecutor([owner.account.address]);

      await expect(
        rebalancer.write.rebalance([
          user.account.address, vaultA.address, vaultB.address,
          0n, [], [], [], 0n,
        ])
      ).to.be.rejectedWith("ZeroAmount");
    });

    it("rebalance reverts when fromVault == toVault", async function () {
      const { rebalancer, vaultA, owner, user } =
        await loadFixture(deployFixture);

      await rebalancer.write.addVault([vaultA.address]);
      await rebalancer.write.setExecutor([owner.account.address]);

      await expect(
        rebalancer.write.rebalance([
          user.account.address, vaultA.address, vaultA.address,
          parseUnits("100", 6), [], [], [], 0n,
        ])
      ).to.be.rejectedWith("InvalidInput");
    });

    it("rebalance reverts on fee array length mismatch", async function () {
      const { rebalancer, vaultA, vaultB, owner, user } =
        await loadFixture(deployFixture);

      await rebalancer.write.addVault([vaultA.address]);
      await rebalancer.write.addVault([vaultB.address]);
      await rebalancer.write.setExecutor([owner.account.address]);

      await expect(
        rebalancer.write.rebalance([
          user.account.address, vaultA.address, vaultB.address,
          parseUnits("100", 6),
          [vaultA.address], // 1 fee vault
          [],               // 0 fee amounts — mismatch
          [], 0n,
        ])
      ).to.be.rejectedWith("ArrayLengthMismatch");
    });

    it("rebalance reverts when user has no toVault allowance", async function () {
      const { rebalancer, vaultA, vaultB, owner, user } =
        await loadFixture(deployFixture);

      await rebalancer.write.addVault([vaultA.address]);
      await rebalancer.write.addVault([vaultB.address]);
      await rebalancer.write.setExecutor([owner.account.address]);

      // User has NO vaultB share approval
      await expect(
        rebalancer.write.rebalance([
          user.account.address, vaultA.address, vaultB.address,
          parseUnits("100", 6), [], [], [], 0n,
        ])
      ).to.be.rejectedWith("InvalidInput");
    });
  });

  // --- Force-dealloc + CCTP fixtures ---

  const PERMIT2_ADDRESS = "0x000000000022D473030F116dDEE9F6B43aC78BA3";
  const B32_ZERO =
    "0x0000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`;
  const toBytes32 = (addr: string) => padHex(addr as `0x${string}`, { size: 32 });

  /**
   * Fixture with a MockTokenMessengerV2 wired as the CCTP TokenMessenger, a
   * MockVaultV2 (idle-capped, forceDeallocate-capable) and a plain MockERC4626.
   */
  async function cctpFixture() {
    const [owner, user, other] = await hre.viem.getWalletClients();
    const publicClient = await hre.viem.getPublicClient();

    const usdc = await hre.viem.deployContract("MockERC20", ["USD Coin", "USDC", 6]);
    const messenger = await hre.viem.deployContract("MockTokenMessengerV2", []);
    const vaultV2 = await hre.viem.deployContract("MockVaultV2", [usdc.address, "Vault V2", "v2"]);
    const vaultB = await hre.viem.deployContract("MockERC4626", [usdc.address, "Vault B Shares", "vB"]);

    const rebalancer = await deployBehindProxy(
      usdc.address,
      ZERO_ADDRESS as `0x${string}`, // messageTransmitter (relay not exercised)
      messenger.address,             // tokenMessenger (mock)
      owner.account.address,
      [],
    );

    const mintAmount = parseUnits("10000", 6);
    await usdc.write.mint([user.account.address, mintAmount]);

    const usdcAsUser = await hre.viem.getContractAt("MockERC20", usdc.address, {
      client: { wallet: user },
    });
    const rebalancerAsUser = await hre.viem.getContractAt(
      "QuicknodeEarnProxy",
      rebalancer.address,
      { client: { wallet: user } },
    );

    return {
      rebalancer, rebalancerAsUser, usdc, usdcAsUser, messenger,
      vaultV2, vaultB, owner, user, other, publicClient, mintAmount,
    };
  }

  /**
   * cctpFixture + user deposited 1000 USDC into the V2 vault (idle stays 0 —
   * deposits auto-allocate), executor set, share approvals in place.
   */
  async function v2DepositedFixture() {
    const base = await cctpFixture();
    const { rebalancer, rebalancerAsUser, usdcAsUser, vaultV2, vaultB, user, owner } = base;

    await rebalancer.write.addVault([vaultV2.address]);
    await rebalancer.write.addVault([vaultB.address]);
    await rebalancer.write.setExecutor([owner.account.address]);

    const depositAmount = parseUnits("1000", 6);
    await usdcAsUser.write.approve([rebalancer.address, depositAmount]);
    await rebalancerAsUser.write.selfBatchDeposit([[vaultV2.address], [depositAmount], []]);

    const userShares = await vaultV2.read.balanceOf([user.account.address]);
    const vaultV2AsUser = await hre.viem.getContractAt("MockVaultV2", vaultV2.address, {
      client: { wallet: user },
    });
    await vaultV2AsUser.write.approve([rebalancer.address, userShares * 2n]);
    const vaultBAsUser = await hre.viem.getContractAt("MockERC4626", vaultB.address, {
      client: { wallet: user },
    });
    await vaultBAsUser.write.approve([rebalancer.address, userShares * 2n]);

    return { ...base, depositAmount, userShares, vaultV2AsUser, vaultBAsUser };
  }

  // --- ForceDealloc Rebalance ---

  describe("ForceDealloc Rebalance", function () {
    it("plain rebalance reverts when V2 idle cannot cover the redeem", async function () {
      const { rebalancer, vaultV2, vaultB, user, userShares } =
        await loadFixture(v2DepositedFixture);

      await expect(
        rebalancer.write.rebalance([
          user.account.address, vaultV2.address, vaultB.address,
          userShares, [], [], [], 0n,
        ])
      ).to.be.rejectedWith("insufficient idle");
    });

    it("force-dealloc frees liquidity and completes the rebalance (zero penalty)", async function () {
      const { rebalancer, usdc, vaultV2, vaultB, user, other, userShares, depositAmount } =
        await loadFixture(v2DepositedFixture);

      await rebalancer.write.rebalance([
        user.account.address, vaultV2.address, vaultB.address, userShares,
        [], [],
        [{ adapter: other.account.address, data: "0x", assets: depositAmount }],
        0n, // zero-penalty vault: cap 0 must pass
      ]);

      expect(await vaultV2.read.balanceOf([user.account.address])).to.equal(0n);
      expect(await vaultV2.read.balanceOf([rebalancer.address])).to.equal(0n);
      expect(await vaultB.read.balanceOf([user.account.address])).to.equal(depositAmount);
      expect(await vaultB.read.totalAssets()).to.equal(depositAmount);
      expect(await usdc.read.balanceOf([rebalancer.address])).to.equal(0n);
      expect(getAddress(await vaultV2.read.lastAdapter())).to.equal(
        getAddress(other.account.address)
      );
    });

    it("penalty reduces the redeem and the event reports it exactly", async function () {
      const { rebalancer, vaultV2, vaultB, user, other, userShares, depositAmount, publicClient } =
        await loadFixture(v2DepositedFixture);

      await vaultV2.write.setPenalty([parseUnits("0.001", 18)]); // 0.1% (10 bp)

      await rebalancer.write.rebalance([
        user.account.address, vaultV2.address, vaultB.address, userShares,
        [], [],
        [{ adapter: other.account.address, data: "0x", assets: depositAmount }],
        parseUnits("1.1", 6), // quoted 1 USDC of penalty shares + headroom
      ]);

      const logs = await publicClient.getContractEvents({
        address: rebalancer.address,
        abi: rebalancer.abi,
        eventName: "ForceDeallocated",
        fromBlock: 0n,
      });
      expect(logs.length).to.equal(1);
      expect(logs[0].args.assetsDeallocated).to.equal(depositAmount);
      expect(logs[0].args.penaltyShares).to.equal(parseUnits("1", 6));

      expect(await vaultV2.read.balanceOf([user.account.address])).to.equal(0n);
      expect(await vaultV2.read.balanceOf([rebalancer.address])).to.equal(0n);

      // The penalty must actually cost the user. The mock models the real vault,
      // which drops totalAssets alongside totalSupply so the share price stays
      // flat; a mock that held assets flat would refund the penalty through a
      // rising share price and this assertion would be off by ~1 USDC.
      const moved = await vaultB.read.totalAssets();
      const expected = depositAmount - parseUnits("1", 6);
      expect(moved >= expected).to.be.true;
      expect(moved <= expected + 2n).to.be.true;
    });

    it("resting fee shares are never consumed", async function () {
      const { rebalancer, vaultV2, vaultB, user, other, userShares, depositAmount, vaultV2AsUser } =
        await loadFixture(v2DepositedFixture);

      // Simulate accrued-but-unswept fee shares resting in the contract.
      const resting = parseUnits("50", 6);
      await vaultV2AsUser.write.transfer([rebalancer.address, resting]);

      await vaultV2.write.setPenalty([parseUnits("0.001", 18)]);

      const fee = parseUnits("10", 6);
      const grossMove = userShares - resting - fee; // 940 USDC worth of shares

      await rebalancer.write.rebalance([
        user.account.address, vaultV2.address, vaultB.address, grossMove,
        [vaultV2.address], [fee],
        [{ adapter: other.account.address, data: "0x", assets: depositAmount }],
        parseUnits("1.1", 6),
      ]);

      // Contract ends with EXACTLY resting + fee shares — the penalty came out
      // of the moved amount, not the fee inventory.
      expect(await vaultV2.read.balanceOf([rebalancer.address])).to.equal(resting + fee);
    });

    it("reverts with PenaltyTooHigh when the penalty is repriced above the cap", async function () {
      const { rebalancer, vaultV2, vaultB, user, other, userShares, depositAmount } =
        await loadFixture(v2DepositedFixture);

      // Executor quoted at 0 penalty; curator reprices before inclusion.
      await vaultV2.write.setPenalty([parseUnits("0.001", 18)]);

      await expect(
        rebalancer.write.rebalance([
          user.account.address, vaultV2.address, vaultB.address, userShares,
          [], [],
          [{ adapter: other.account.address, data: "0x", assets: depositAmount }],
          parseUnits("0.5", 6), // stale quote below the 1 USDC actual penalty
        ])
      ).to.be.rejectedWith("PenaltyTooHigh");

      // Atomic revert: user still holds every share.
      expect(await vaultV2.read.balanceOf([user.account.address])).to.equal(userShares);
    });

    it("caps the penalty at MAX_FORCE_DEALLOC_PENALTY_BPS even when the caller's cap is unlimited", async function () {
      const { rebalancer, vaultV2, vaultB, user, other, userShares, depositAmount } =
        await loadFixture(v2DepositedFixture);

      // A compromised executor supplies both the deallocation size AND the cap,
      // so maxPenaltyShares protects nobody here. The contract's own constant
      // ceiling is what stops the position being burned.
      await vaultV2.write.setPenalty([parseUnits("0.02", 18)]); // Morpho's 2% max
      expect(await rebalancer.read.MAX_FORCE_DEALLOC_PENALTY_BPS()).to.equal(300n);

      await expect(
        rebalancer.write.rebalance([
          user.account.address, vaultV2.address, vaultB.address, userShares,
          [], [],
          // 10x the position deallocated → 2 USDC penalty per 100 → 20% of the position
          [{ adapter: other.account.address, data: "0x", assets: depositAmount * 10n }],
          maxUint256, // caller waives its own cap
        ])
      ).to.be.rejectedWith("PenaltyTooHigh");

      // Atomic revert: the user keeps every share.
      expect(await vaultV2.read.balanceOf([user.account.address])).to.equal(userShares);
    });

    it("allows a penalty at the honest ceiling", async function () {
      const { rebalancer, vaultV2, vaultB, user, other, userShares, depositAmount } =
        await loadFixture(v2DepositedFixture);

      // Deallocating exactly the position at Morpho's 2% max stays under 3%.
      await vaultV2.write.setPenalty([parseUnits("0.02", 18)]);

      await rebalancer.write.rebalance([
        user.account.address, vaultV2.address, vaultB.address, userShares,
        [], [],
        [{ adapter: other.account.address, data: "0x", assets: depositAmount }],
        maxUint256,
      ]);

      const moved = await vaultB.read.totalAssets();
      const expected = depositAmount - parseUnits("20", 6); // 2% of 1000
      expect(moved >= expected).to.be.true;
      expect(moved <= expected + 2n).to.be.true;
    });

    it("reverts when a zero-asset dealloc entry is passed", async function () {
      const { rebalancer, vaultV2, vaultB, user, other, userShares } =
        await loadFixture(v2DepositedFixture);

      await expect(
        rebalancer.write.rebalance([
          user.account.address, vaultV2.address, vaultB.address, userShares,
          [], [],
          [{ adapter: other.account.address, data: "0x", assets: 0n }],
          maxUint256,
        ])
      ).to.be.rejectedWith("ZeroAmount");
    });

    it("burns only USDC the vault actually delivered, never resting fees", async function () {
      const { rebalancer, rebalancerAsUser, usdc, usdcAsUser, messenger, vaultB, user, other } =
        await loadFixture(v2DepositedFixture);

      // Seed the contract with accumulated bridge-fee USDC. Without this the
      // test cannot fail, which is why the original suite missed the gap.
      const bridged = parseUnits("100", 6);
      const fee = parseUnits("2", 6);
      await usdcAsUser.write.approve([rebalancer.address, bridged]);
      await rebalancerAsUser.write.bridge([bridged, fee, 0, 6, other.account.address, 0n, 2000]);
      expect(await usdc.read.balanceOf([rebalancer.address])).to.equal(fee);

      // A vault that reports a large redeem while transferring nothing.
      const liar = await hre.viem.deployContract("MockLyingVault", []);
      await liar.write.setReportedAssets([fee]);

      // withdrawAndBridge derives the burn from the MEASURED balance increase,
      // which is zero here, so the burn amount is zero and the call reverts
      // rather than burning the resting fee.
      await expect(
        rebalancer.write.withdrawAndBridge([
          user.account.address, liar.address, parseUnits("1", 6),
          [], [],
          6, toBytes32(user.account.address), B32_ZERO, 0n, 2000,
          [], 0n,
        ])
      ).to.be.rejectedWith("ZeroAmount");

      // Fee pot intact.
      expect(await usdc.read.balanceOf([rebalancer.address])).to.equal(fee);

      // Same guarantee on the rebalance path. The measured delta is zero, so the
      // deposit leg gets nothing and reverts on its own zero-shares guard rather
      // than silently spending the fee pot.
      await expect(
        rebalancer.write.rebalance([
          user.account.address, liar.address, vaultB.address, parseUnits("1", 6),
          [], [], [], 0n,
        ])
      ).to.be.rejectedWith("ZeroAmount");
      expect(await usdc.read.balanceOf([rebalancer.address])).to.equal(fee);
    });

    it("lets a user exit an illiquid V2 vault without the executor", async function () {
      const { rebalancer, rebalancerAsUser, usdc, vaultV2, user, other, userShares, depositAmount } =
        await loadFixture(v2DepositedFixture);

      await vaultV2.write.setPenalty([parseUnits("0.001", 18)]);
      const usdcBefore = await usdc.read.balanceOf([user.account.address]);

      // No executor involvement: the user frees the liquidity themselves.
      await rebalancerAsUser.write.selfBatchWithdraw([
        [vaultV2.address],
        [userShares],
        [0n],
        [],
        [[{ adapter: other.account.address, data: "0x", assets: depositAmount }]],
        [parseUnits("1.1", 6)],
      ]);

      const received = (await usdc.read.balanceOf([user.account.address])) - usdcBefore;
      const expected = depositAmount - parseUnits("1", 6);
      expect(received >= expected).to.be.true;
      expect(received <= expected + 2n).to.be.true;
      expect(await vaultV2.read.balanceOf([user.account.address])).to.equal(0n);
    });

    it("selfBatchWithdraw rejects mismatched dealloc array lengths", async function () {
      const { rebalancerAsUser, vaultV2, userShares } =
        await loadFixture(v2DepositedFixture);

      await expect(
        rebalancerAsUser.write.selfBatchWithdraw([
          [vaultV2.address], [userShares], [0n], [],
          [[], []], // two entries for one vault
          [0n, 0n],
        ])
      ).to.be.rejectedWith("ArrayLengthMismatch");
    });

    it("empty deallocs behaves exactly like rebalance", async function () {
      const { rebalancer, vaultV2, vaultB, user, userShares, depositAmount } =
        await loadFixture(v2DepositedFixture);

      await vaultV2.write.setIdle([depositAmount]); // vault is liquid

      await rebalancer.write.rebalance([
        user.account.address, vaultV2.address, vaultB.address, userShares,
        [], [], [], 0n,
      ]);

      expect(await vaultV2.read.balanceOf([user.account.address])).to.equal(0n);
      expect(await vaultB.read.totalAssets()).to.equal(depositAmount);
    });

    it("reverts when the source vault lacks forceDeallocate", async function () {
      const { rebalancer, rebalancerAsUser, usdcAsUser, vaultV2, vaultB, user, other } =
        await loadFixture(v2DepositedFixture);

      // Position in the PLAIN ERC4626 vault (no forceDeallocate selector).
      const amount = parseUnits("500", 6);
      await usdcAsUser.write.approve([rebalancer.address, amount]);
      await rebalancerAsUser.write.selfBatchDeposit([[vaultB.address], [amount], []]);

      await expect(
        rebalancer.write.rebalance([
          user.account.address, vaultB.address, vaultV2.address, amount,
          [], [],
          [{ adapter: other.account.address, data: "0x", assets: 1n }],
          0n,
        ])
      ).to.be.rejected; // missing selector, no fallback — no revert data to match on

      // The revert reason is not assertable (a missing selector returns no data),
      // so assert atomicity instead: the position must be untouched.
      expect(await vaultB.read.balanceOf([user.account.address])).to.equal(amount);
    });

    it("non-executor cannot call rebalance", async function () {
      const { rebalancer, vaultV2, vaultB, user, other, userShares } =
        await loadFixture(v2DepositedFixture);

      const rebalancerAsOther = await hre.viem.getContractAt(
        "QuicknodeEarnProxy",
        rebalancer.address,
        { client: { wallet: other } }
      );
      await expect(
        rebalancerAsOther.write.rebalance([
          user.account.address, vaultV2.address, vaultB.address, userShares,
          [], [], [], 0n,
        ])
      ).to.be.rejectedWith("0x83906042"); // UnauthorizedExecutor()
    });

    it("reentrancy from a malicious vault is blocked", async function () {
      const { rebalancer, usdc, usdcAsUser, vaultB, user, other } =
        await loadFixture(v2DepositedFixture);

      const evil = await hre.viem.deployContract("MockReentrantVaultV2", [
        usdc.address,
        rebalancer.address,
      ]);
      const amount = parseUnits("100", 6);
      await usdcAsUser.write.approve([evil.address, amount]);
      const evilAsUser = await hre.viem.getContractAt("MockReentrantVaultV2", evil.address, {
        client: { wallet: user },
      });
      await evilAsUser.write.deposit([amount, user.account.address]);
      await evilAsUser.write.approve([rebalancer.address, amount]);

      await expect(
        rebalancer.write.rebalance([
          user.account.address, evil.address, vaultB.address, amount,
          [], [],
          [{ adapter: other.account.address, data: "0x", assets: 1n }],
          0n,
        ])
      ).to.be.rejectedWith("ReentrancyGuardReentrantCall");
    });
  });

  // --- ForceDealloc WithdrawAndBridge ---

  describe("ForceDealloc WithdrawAndBridge", function () {
    it("force-deallocs, redeems, and burns cross-chain (exit pairing)", async function () {
      const { rebalancer, usdc, messenger, vaultV2, user, other, userShares, depositAmount } =
        await loadFixture(v2DepositedFixture);

      await vaultV2.write.setPenalty([parseUnits("0.001", 18)]);

      await rebalancer.write.withdrawAndBridge([
        user.account.address, vaultV2.address, userShares,
        [], [],
        6, toBytes32(user.account.address), B32_ZERO, 0n, 2000,
        [{ adapter: other.account.address, data: "0x", assets: depositAmount }],
        parseUnits("1.1", 6),
      ]);

      const burned = await messenger.read.lastAmount();
      expect(burned >= parseUnits("999", 6)).to.be.true;
      expect(await usdc.read.balanceOf([messenger.address])).to.equal(burned);
      expect(await messenger.read.lastDestDomain()).to.equal(6);
      expect(await messenger.read.lastMinFinalityThreshold()).to.equal(2000);

      const [beneficiary] = decodeAbiParameters(
        [{ type: "address" }],
        await messenger.read.lastHookData()
      );
      expect(getAddress(beneficiary)).to.equal(getAddress(user.account.address));

      expect(await vaultV2.read.balanceOf([user.account.address])).to.equal(0n);
      expect(await vaultV2.read.balanceOf([rebalancer.address])).to.equal(0n);
      expect(await usdc.read.balanceOf([rebalancer.address])).to.equal(0n);
    });

    it("reverts on a non-allowed CCTP pairing", async function () {
      const { rebalancer, vaultV2, user, other, userShares, depositAmount } =
        await loadFixture(v2DepositedFixture);

      await expect(
        rebalancer.write.withdrawAndBridge([
          user.account.address, vaultV2.address, userShares,
          [], [],
          6, toBytes32(user.account.address), toBytes32(user.account.address), 0n, 2000,
          [{ adapter: other.account.address, data: "0x", assets: depositAmount }],
          0n,
        ])
      ).to.be.rejectedWith("InvalidInput");
    });

    it("non-executor cannot call withdrawAndBridge", async function () {
      const { rebalancer, vaultV2, user, other, userShares } =
        await loadFixture(v2DepositedFixture);

      const rebalancerAsOther = await hre.viem.getContractAt(
        "QuicknodeEarnProxy",
        rebalancer.address,
        { client: { wallet: other } }
      );
      await expect(
        rebalancerAsOther.write.withdrawAndBridge([
          user.account.address, vaultV2.address, userShares,
          [], [],
          6, toBytes32(user.account.address), B32_ZERO, 0n, 2000,
          [], 0n,
        ])
      ).to.be.rejectedWith("0x83906042"); // UnauthorizedExecutor()
    });
  });

  // --- Standalone Bridge (1 bp fee) ---

  describe("Standalone Bridge", function () {
    it("pulls USDC, retains the 1 bp fee, and burns the remainder", async function () {
      const { rebalancer, rebalancerAsUser, usdc, usdcAsUser, messenger, user, other, owner, publicClient } =
        await loadFixture(cctpFixture);

      const amount = parseUnits("100", 6);
      const fee = 10_000n;             // 1 bp of 100 USDC = 0.01 USDC
      const burn = amount - fee;

      await usdcAsUser.write.approve([rebalancer.address, amount]);
      await rebalancerAsUser.write.bridge([amount, fee, 0, 6, other.account.address, 0n, 2000]);

      expect(await messenger.read.lastAmount()).to.equal(burn);
      expect(await usdc.read.balanceOf([messenger.address])).to.equal(burn);
      expect(await usdc.read.balanceOf([rebalancer.address])).to.equal(fee);

      const [beneficiary] = decodeAbiParameters(
        [{ type: "address" }],
        await messenger.read.lastHookData()
      );
      expect(getAddress(beneficiary)).to.equal(getAddress(user.account.address));

      const logs = await publicClient.getContractEvents({
        address: rebalancer.address,
        abi: rebalancer.abi,
        eventName: "BridgeExecuted",
        fromBlock: 0n,
      });
      expect(logs.length).to.equal(1);
      expect(logs[0].args.fee).to.equal(fee);
      expect(logs[0].args.amount).to.equal(burn);

      // Owner sweeps the accumulated fee.
      const ownerBefore = await usdc.read.balanceOf([owner.account.address]);
      await rebalancer.write.sweep([usdc.address, fee]);
      expect(await usdc.read.balanceOf([owner.account.address])).to.equal(ownerBefore + fee);
    });

    it("a zero fee bridges the full amount and still emits the event", async function () {
      const { rebalancer, rebalancerAsUser, usdc, usdcAsUser, messenger, user, other, publicClient } =
        await loadFixture(cctpFixture);

      const amount = parseUnits("50", 6);
      await usdcAsUser.write.approve([rebalancer.address, amount]);
      await rebalancerAsUser.write.bridge([amount, 0n, 0, 6, other.account.address, 0n, 2000]);

      expect(await messenger.read.lastAmount()).to.equal(amount);
      expect(await usdc.read.balanceOf([rebalancer.address])).to.equal(0n);

      // The emit is deliberately NOT guarded by `fee > 0`. This event is the
      // ONLY on-chain marker of a standalone bridge, so suppressing it at a
      // zero fee would make a fee-free bridge invisible to the stream, the
      // event-processor, and any UI reading contract history.
      const logs = await publicClient.getContractEvents({
        address: rebalancer.address,
        abi: rebalancer.abi,
        eventName: "BridgeExecuted",
        fromBlock: 0n,
      });
      expect(logs.length).to.equal(1);
      expect(logs[0].args.fee).to.equal(0n);
      expect(logs[0].args.amount).to.equal(amount);
      expect(getAddress(logs[0].args.user as string)).to.equal(getAddress(user.account.address));
    });

    it("each service option is identifiable from the event alone", async function () {
      const { rebalancer, rebalancerAsUser, usdcAsUser, other, publicClient } =
        await loadFixture(cctpFixture);

      const amount = parseUnits("100", 6);
      await usdcAsUser.write.approve([rebalancer.address, amount * 3n]);

      const SELF = await rebalancer.read.BRIDGE_SELF_RELAY();
      const SPONSORED = await rebalancer.read.BRIDGE_SPONSORED_RELAY();
      expect(SELF).to.equal(0);
      expect(SPONSORED).to.equal(1);

      // Option 1 — free, user claims on the destination chain themselves.
      await rebalancerAsUser.write.bridge([amount, 0n, SELF, 6, other.account.address, 0n, 2000]);
      // Option 2 — we charge a quote and relay for them. Standard finality.
      await rebalancerAsUser.write.bridge([
        amount, parseUnits("1.5", 6), SPONSORED, 6, other.account.address, 0n, 2000,
      ]);
      // Option 3 — Circle Fast Transfer: maxFee > 0 and a fast finality threshold.
      // Speed is orthogonal to who relays, so it pairs with either service value.
      await rebalancerAsUser.write.bridge([
        amount, 0n, SELF, 6, other.account.address, parseUnits("0.4", 6), 1000,
      ]);

      const logs = await publicClient.getContractEvents({
        address: rebalancer.address,
        abi: rebalancer.abi,
        eventName: "BridgeExecuted",
        fromBlock: 0n,
      });
      expect(logs.length).to.equal(3);

      // Every field an indexer needs is on the event, so it never has to decode
      // calldata — which is unrecoverable for smart-account transactions.
      const [a, b, c] = logs.map((l) => l.args);

      expect(a.service).to.equal(SELF);
      expect(a.fee).to.equal(0n);
      expect(a.minFinalityThreshold).to.equal(2000);
      expect(a.maxFee).to.equal(0n);

      expect(b.service).to.equal(SPONSORED);
      expect(b.fee).to.equal(parseUnits("1.5", 6));
      expect(b.amount).to.equal(amount - parseUnits("1.5", 6));
      expect(b.minFinalityThreshold).to.equal(2000);

      expect(c.service).to.equal(SELF);
      expect(c.maxFee).to.equal(parseUnits("0.4", 6));
      expect(c.minFinalityThreshold).to.equal(1000);

      for (const args of [a, b, c]) {
        expect(args.destDomain).to.equal(6);
        expect(getAddress(args.mintRecipient as string)).to.equal(
          getAddress(other.account.address)
        );
      }
    });

    it("rejects an unknown service value", async function () {
      const { rebalancer, rebalancerAsUser, usdcAsUser, other } =
        await loadFixture(cctpFixture);

      const amount = parseUnits("10", 6);
      await usdcAsUser.write.approve([rebalancer.address, amount]);

      await expect(
        rebalancerAsUser.write.bridge([amount, 0n, 2, 6, other.account.address, 0n, 2000])
      ).to.be.rejectedWith("InvalidInput");
    });

    it("rejects a fee equal to or above the amount", async function () {
      const { rebalancer, rebalancerAsUser, usdcAsUser, other } =
        await loadFixture(cctpFixture);

      const amount = parseUnits("10", 6);
      await usdcAsUser.write.approve([rebalancer.address, amount]);

      await expect(
        rebalancerAsUser.write.bridge([amount, amount, 0, 6, other.account.address, 0n, 2000])
      ).to.be.rejectedWith("InvalidInput");
    });

    it("cannot mint into the contract, so no padded-recipient bypass exists", async function () {
      const { rebalancer, rebalancerAsUser, usdcAsUser, other } =
        await loadFixture(cctpFixture);

      const amount = parseUnits("10", 6);
      await usdcAsUser.write.approve([rebalancer.address, amount]);

      // mintRecipient is an `address`, so a caller cannot smuggle dirty upper
      // bytes past the self-check the way a bytes32 parameter would allow:
      // CCTP truncates bytes32 to its low 20 bytes without validating padding.
      await expect(
        rebalancerAsUser.write.bridge([amount, 0n, 0, 6, rebalancer.address, 0n, 2000])
      ).to.be.rejectedWith("InvalidInput");

    });

    it("always burns with a zero destinationCaller, so anyone can relay", async function () {
      const { rebalancer, rebalancerAsUser, usdcAsUser, messenger, other } =
        await loadFixture(cctpFixture);

      const amount = parseUnits("10", 6);
      await usdcAsUser.write.approve([rebalancer.address, amount]);
      await rebalancerAsUser.write.bridge([amount, 0n, 0, 6, other.account.address, 0n, 2000]);

      // A caller-chosen destinationCaller would let a user strand their own
      // funds: only that address could relay, and emergencyClaimBridge could
      // not reach it. The parameter does not exist.
      expect(await messenger.read.lastDestinationCaller()).to.equal(B32_ZERO);
      expect(getAddress(
        `0x${(await messenger.read.lastMintRecipient()).slice(26)}`
      )).to.equal(getAddress(other.account.address));
    });

    it("input guards: zero amount, self recipient, fee too high, zero recipient", async function () {
      const { rebalancer, rebalancerAsUser, usdcAsUser, other } =
        await loadFixture(cctpFixture);

      const amount = parseUnits("10", 6);
      await usdcAsUser.write.approve([rebalancer.address, amount]);

      await expect(
        rebalancerAsUser.write.bridge([0n, 0n, 0, 6, other.account.address, 0n, 2000])
      ).to.be.rejectedWith("ZeroAmount");

      await expect(
        rebalancerAsUser.write.bridge([amount, 0n, 0, 6, rebalancer.address, 0n, 2000])
      ).to.be.rejectedWith("InvalidInput");

      await expect(
        rebalancerAsUser.write.bridge([amount, amount, 0, 6, other.account.address, 0n, 2000])
      ).to.be.rejectedWith("InvalidInput");

      await expect(
        rebalancerAsUser.write.bridge([amount, 0n, 0, 6, ZERO_ADDRESS, 0n, 2000])
      ).to.be.rejectedWith("ZeroAddress");
    });

    it("reverts CctpBurnFailed when the messenger call fails", async function () {
      const { rebalancer, rebalancerAsUser, usdcAsUser, messenger, other } =
        await loadFixture(cctpFixture);

      const amount = parseUnits("10", 6);
      await usdcAsUser.write.approve([rebalancer.address, amount]);
      await messenger.write.setFailNext([true]);

      await expect(
        rebalancerAsUser.write.bridge([amount, 0n, 0, 6, other.account.address, 0n, 2000])
      ).to.be.rejectedWith("CctpBurnFailed");
    });

    it("reverts when CCTP is disabled on the chain", async function () {
      const { rebalancer, usdc, user, other } = await loadFixture(deployFixture);

      const amount = parseUnits("10", 6);
      const usdcAsUser = await hre.viem.getContractAt("MockERC20", usdc.address, {
        client: { wallet: user },
      });
      await usdcAsUser.write.approve([rebalancer.address, amount]);
      const rebalancerAsUser = await hre.viem.getContractAt(
        "QuicknodeEarnProxy",
        rebalancer.address,
        { client: { wallet: user } }
      );

      // tokenMessenger == address(0) is checked before any approval is issued,
      // so the failure is legible rather than a SafeERC20 approval error.
      await expect(
        rebalancerAsUser.write.bridge([amount, 0n, 0, 6, other.account.address, 0n, 2000])
      ).to.be.rejectedWith("ZeroAddress");
    });
  });

  // --- Permit2 variants ---

  describe("Permit2 variants", function () {
    async function permit2Fixture() {
      const base = await cctpFixture();
      const impl = await hre.viem.deployContract("MockPermit2", []);
      const code = await hre.network.provider.send("eth_getCode", [impl.address, "latest"]);
      await hre.network.provider.send("hardhat_setCode", [PERMIT2_ADDRESS, code]);
      // One-time USDC approval to the canonical Permit2 address.
      await base.usdcAsUser.write.approve([PERMIT2_ADDRESS, maxUint256]);
      return base;
    }

    const EOA_SIG = "0x01" as `0x${string}`;

    const mkPermit = (token: `0x${string}`, amount: bigint) => ({
      permitted: { token, amount },
      nonce: 0n,
      deadline: 0n,
    });

    it("bridgePermit2 pulls via Permit2 and burns with the 1 bp fee", async function () {
      const { rebalancer, rebalancerAsUser, usdc, messenger, other } =
        await loadFixture(permit2Fixture);

      const amount = parseUnits("100", 6);
      const fee = 10_000n;

      await rebalancerAsUser.write.bridgePermit2([
        amount, fee, 0, 6, other.account.address, 0n, 2000,
        mkPermit(usdc.address, amount), EOA_SIG,
      ]);

      expect(await messenger.read.lastAmount()).to.equal(amount - fee);
      expect(await usdc.read.balanceOf([rebalancer.address])).to.equal(fee);
    });

    it("bridgePermit2 rejects a permit for a non-USDC token", async function () {
      const { rebalancerAsUser, vaultB, other } = await loadFixture(permit2Fixture);

      await expect(
        rebalancerAsUser.write.bridgePermit2([
          parseUnits("100", 6), 0n, 0, 6, other.account.address, 0n, 2000,
          mkPermit(vaultB.address, parseUnits("100", 6)), EOA_SIG,
        ])
      ).to.be.rejectedWith("InvalidInput");
    });

    it("bridgePermit2 rejects when the requested amount exceeds the permit", async function () {
      const { rebalancerAsUser, usdc, messenger, user, other } = await loadFixture(permit2Fixture);

      const balanceBefore = await usdc.read.balanceOf([user.account.address]);

      // Hardhat cannot decode revert strings from hardhat_setCode-planted
      // contracts, so assert the rejection plus untouched state instead.
      await expect(
        rebalancerAsUser.write.bridgePermit2([
          parseUnits("100", 6), 0n, 0, 6, other.account.address, 0n, 2000,
          mkPermit(usdc.address, parseUnits("50", 6)), EOA_SIG,
        ])
      ).to.be.rejected;

      expect(await messenger.read.burnCount()).to.equal(0n);
      expect(await usdc.read.balanceOf([user.account.address])).to.equal(balanceBefore);
    });

    it("selfBatchDepositPermit2 deposits with a signature pull", async function () {
      const { rebalancer, rebalancerAsUser, usdc, vaultB, user } =
        await loadFixture(permit2Fixture);

      await rebalancer.write.addVault([vaultB.address]);
      const amount = parseUnits("500", 6);

      await rebalancerAsUser.write.selfBatchDepositPermit2([
        [vaultB.address], [amount], [],
        mkPermit(usdc.address, amount), EOA_SIG,
      ]);

      expect(await vaultB.read.balanceOf([user.account.address])).to.equal(amount);
      expect(await usdc.read.balanceOf([vaultB.address])).to.equal(amount);
      expect(await usdc.read.balanceOf([rebalancer.address])).to.equal(0n);
    });

    it("selfBatchDepositPermit2 rejects a permit for a non-USDC token", async function () {
      const { rebalancer, rebalancerAsUser, vaultB } = await loadFixture(permit2Fixture);

      await rebalancer.write.addVault([vaultB.address]);
      const amount = parseUnits("500", 6);

      await expect(
        rebalancerAsUser.write.selfBatchDepositPermit2([
          [vaultB.address], [amount], [],
          mkPermit(vaultB.address, amount), "0x",
        ])
      ).to.be.rejectedWith("InvalidInput");
    });

    it("selfBatchDepositPermit2 rejects a non-whitelisted vault", async function () {
      const { rebalancerAsUser, usdc, vaultB } = await loadFixture(permit2Fixture);

      const amount = parseUnits("500", 6);
      await expect(
        rebalancerAsUser.write.selfBatchDepositPermit2([
          [vaultB.address], [amount], [],
          mkPermit(usdc.address, amount), EOA_SIG,
        ])
      ).to.be.rejectedWith("VaultNotApproved");
    });
  });

  // --- Account abstraction / smart-contract wallets ---

  describe("Smart-contract wallets (ERC-4337 accounts and multi-sigs)", function () {
    const WALLET_SIG = "0xa11ce" as `0x${string}`;

    /**
     * The Earn contract never assumes the caller is an EOA: there is no tx.origin
     * check and no code-length check on any caller. A smart account calls it the
     * same way an EOA does, so msg.sender is the account itself. These tests drive
     * every new code path through a contract wallet that holds no private key.
     */
    async function walletFixture() {
      const base = await cctpFixture();
      const { rebalancer, usdc, vaultV2, vaultB, owner } = base;

      const wallet = await hre.viem.deployContract("MockSmartWallet", []);
      await wallet.write.setApprovedSignature([WALLET_SIG]);

      // Plant Permit2 so the signature path is exercised for real.
      const impl = await hre.viem.deployContract("MockPermit2", []);
      const code = await hre.network.provider.send("eth_getCode", [impl.address, "latest"]);
      await hre.network.provider.send("hardhat_setCode", [PERMIT2_ADDRESS, code]);

      await rebalancer.write.addVault([vaultV2.address]);
      await rebalancer.write.addVault([vaultB.address]);
      await rebalancer.write.setExecutor([owner.account.address]);
      await usdc.write.mint([wallet.address, parseUnits("10000", 6)]);

      const call = async (target: `0x${string}`, data: `0x${string}`) =>
        wallet.write.execute([target, data]);

      const erc20 = async (fn: string, args: unknown[]) =>
        encodeFunctionData({ abi: usdc.abi, functionName: fn, args } as never);

      // The wallet grants its own approvals, exactly like a Safe would.
      await call(usdc.address, await erc20("approve", [rebalancer.address, maxUint256]));
      await call(usdc.address, await erc20("approve", [PERMIT2_ADDRESS, maxUint256]));

      const earn = (fn: string, args: unknown[]) =>
        encodeFunctionData({ abi: rebalancer.abi, functionName: fn, args } as never);

      return { ...base, wallet, call, earn };
    }

    it("a contract wallet can deposit and hold vault shares", async function () {
      const { rebalancer, wallet, call, earn, vaultV2 } = await loadFixture(walletFixture);

      const amount = parseUnits("1000", 6);
      await call(rebalancer.address, earn("selfBatchDeposit", [[vaultV2.address], [amount], []]));

      // Shares are minted to the wallet, not to whoever relayed the call.
      expect(await vaultV2.read.balanceOf([wallet.address])).to.equal(amount);
    });

    it("a contract wallet can bridge, and chooses its own destination address", async function () {
      const { rebalancer, usdc, messenger, wallet, call, earn, other } =
        await loadFixture(walletFixture);

      const amount = parseUnits("100", 6);
      const fee = parseUnits("1", 6);

      // mintRecipient is an explicit parameter, so a wallet whose address differs
      // on the destination chain can name the correct one rather than being
      // forced to receive at its own address.
      await call(rebalancer.address, earn("bridge", [amount, fee, 0, 6, other.account.address, 0n, 2000]));

      expect(await messenger.read.lastAmount()).to.equal(amount - fee);
      expect(await usdc.read.balanceOf([rebalancer.address])).to.equal(fee);

      // hookData names the wallet as beneficiary.
      const [beneficiary] = decodeAbiParameters(
        [{ type: "address" }],
        await messenger.read.lastHookData()
      );
      expect(getAddress(beneficiary)).to.equal(getAddress(wallet.address));
    });

    it("a contract wallet can use the Permit2 paths via EIP-1271", async function () {
      const { rebalancer, usdc, messenger, wallet, call, earn, other } =
        await loadFixture(walletFixture);

      const amount = parseUnits("100", 6);
      const permit = { permitted: { token: usdc.address, amount }, nonce: 0n, deadline: 0n };

      // The wallet has no private key. Permit2 verifies the signature by calling
      // isValidSignature on the wallet and comparing the EIP-1271 magic value.
      await call(
        rebalancer.address,
        earn("bridgePermit2", [amount, 0n, 0, 6, other.account.address, 0n, 2000, permit, WALLET_SIG])
      );

      expect(await messenger.read.lastAmount()).to.equal(amount);
      expect(await usdc.read.balanceOf([wallet.address])).to.equal(parseUnits("9900", 6));
    });

    it("a contract-wallet signature the wallet does not authorise is rejected", async function () {
      const { rebalancer, usdc, call, earn, other } = await loadFixture(walletFixture);

      const amount = parseUnits("100", 6);
      const permit = { permitted: { token: usdc.address, amount }, nonce: 0n, deadline: 0n };

      await expect(
        call(
          rebalancer.address,
          earn("bridgePermit2", [amount, 0n, 0, 6, other.account.address, 0n, 2000, permit, "0xdead"])
        )
      ).to.be.rejected;
    });

    it("the executor can rebalance a contract wallet's position, including force-dealloc", async function () {
      const { rebalancer, wallet, call, earn, vaultV2, vaultB, other } =
        await loadFixture(walletFixture);

      const amount = parseUnits("1000", 6);
      await call(rebalancer.address, earn("selfBatchDeposit", [[vaultV2.address], [amount], []]));

      const shares = await vaultV2.read.balanceOf([wallet.address]);
      const approve = (token: `0x${string}`, abi: unknown) =>
        call(token, encodeFunctionData({
          abi: abi as never,
          functionName: "approve",
          args: [rebalancer.address, maxUint256],
        } as never));
      await approve(vaultV2.address, vaultV2.abi);
      await approve(vaultB.address, vaultB.abi);

      await vaultV2.write.setPenalty([parseUnits("0.001", 18)]);

      // user = the smart wallet. Shares land back in the wallet.
      await rebalancer.write.rebalance([
        wallet.address, vaultV2.address, vaultB.address, shares,
        [], [],
        [{ adapter: other.account.address, data: "0x", assets: amount }],
        parseUnits("1.1", 6),
      ]);

      expect(await vaultV2.read.balanceOf([wallet.address])).to.equal(0n);
      expect(await vaultB.read.balanceOf([wallet.address]) > 0n).to.be.true;
    });

    it("a contract wallet can self-exit an illiquid V2 vault", async function () {
      const { rebalancer, usdc, wallet, call, earn, vaultV2, other } =
        await loadFixture(walletFixture);

      const amount = parseUnits("1000", 6);
      await call(rebalancer.address, earn("selfBatchDeposit", [[vaultV2.address], [amount], []]));

      const shares = await vaultV2.read.balanceOf([wallet.address]);
      await call(vaultV2.address, encodeFunctionData({
        abi: vaultV2.abi,
        functionName: "approve",
        args: [rebalancer.address, maxUint256],
      } as never));

      await vaultV2.write.setPenalty([parseUnits("0.001", 18)]);
      const before = await usdc.read.balanceOf([wallet.address]);

      // No executor, no EOA: the wallet frees the liquidity and exits itself.
      await call(rebalancer.address, earn("selfBatchWithdraw", [
        [vaultV2.address], [shares], [0n], [],
        [[{ adapter: other.account.address, data: "0x", assets: amount }]],
        [parseUnits("1.1", 6)],
      ]));

      const received = (await usdc.read.balanceOf([wallet.address])) - before;
      const expected = amount - parseUnits("1", 6);
      expect(received >= expected).to.be.true;
      expect(received <= expected + 2n).to.be.true;
    });
  });

  // --- Legacy QuicknodeEarn parity (non-proxy twin) ---

  describe("Legacy QuicknodeEarn parity", function () {
    async function legacyFixture() {
      const [owner, user, other] = await hre.viem.getWalletClients();
      const publicClient = await hre.viem.getPublicClient();

      const usdc = await hre.viem.deployContract("MockERC20", ["USD Coin", "USDC", 6]);
      const messenger = await hre.viem.deployContract("MockTokenMessengerV2", []);
      const vaultV2 = await hre.viem.deployContract("MockVaultV2", [usdc.address, "Vault V2", "v2"]);
      const vaultB = await hre.viem.deployContract("MockERC4626", [usdc.address, "Vault B Shares", "vB"]);

      const rebalancer = await hre.viem.deployContract("QuicknodeEarn", [
        usdc.address,
        ZERO_ADDRESS as `0x${string}`,
        messenger.address,
        owner.account.address,
        [],
      ]);

      await usdc.write.mint([user.account.address, parseUnits("10000", 6)]);
      await rebalancer.write.addVault([vaultV2.address]);
      await rebalancer.write.addVault([vaultB.address]);
      await rebalancer.write.setExecutor([owner.account.address]);

      const depositAmount = parseUnits("1000", 6);
      const usdcAsUser = await hre.viem.getContractAt("MockERC20", usdc.address, {
        client: { wallet: user },
      });
      await usdcAsUser.write.approve([rebalancer.address, depositAmount]);
      const rebalancerAsUser = await hre.viem.getContractAt("QuicknodeEarn", rebalancer.address, {
        client: { wallet: user },
      });
      await rebalancerAsUser.write.selfBatchDeposit([[vaultV2.address], [depositAmount], []]);

      const userShares = await vaultV2.read.balanceOf([user.account.address]);
      const vaultV2AsUser = await hre.viem.getContractAt("MockVaultV2", vaultV2.address, {
        client: { wallet: user },
      });
      await vaultV2AsUser.write.approve([rebalancer.address, userShares * 2n]);
      const vaultBAsUser = await hre.viem.getContractAt("MockERC4626", vaultB.address, {
        client: { wallet: user },
      });
      await vaultBAsUser.write.approve([rebalancer.address, userShares * 2n]);

      return {
        rebalancer, rebalancerAsUser, usdc, usdcAsUser, messenger,
        vaultV2, vaultB, owner, user, other, publicClient, depositAmount, userShares,
      };
    }

    it("rebalance works on the non-proxy twin", async function () {
      const { rebalancer, vaultV2, vaultB, user, other, userShares, depositAmount } =
        await loadFixture(legacyFixture);

      await rebalancer.write.rebalance([
        user.account.address, vaultV2.address, vaultB.address, userShares,
        [], [],
        [{ adapter: other.account.address, data: "0x", assets: depositAmount }],
        0n,
      ]);

      expect(await vaultV2.read.balanceOf([user.account.address])).to.equal(0n);
      expect(await vaultB.read.totalAssets()).to.equal(depositAmount);
    });

    it("bridge works on the non-proxy twin", async function () {
      const { rebalancer, rebalancerAsUser, usdc, usdcAsUser, messenger, other } =
        await loadFixture(legacyFixture);

      const amount = parseUnits("100", 6);
      await usdcAsUser.write.approve([rebalancer.address, amount]);
      await rebalancerAsUser.write.bridge([amount, 10_000n, 0, 6, other.account.address, 0n, 2000]);

      expect(await messenger.read.lastAmount()).to.equal(amount - 10_000n);
      expect(await usdc.read.balanceOf([rebalancer.address])).to.equal(10_000n);
    });
  });
});
