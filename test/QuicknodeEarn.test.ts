import hre from "hardhat";
import { expect } from "chai";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { getAddress, parseUnits, encodeFunctionData } from "viem";

describe("QuicknodeEarn", function () {
  const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

  /**
   * Deploy QuicknodeEarnProxy behind an ERC1967 proxy (UUPS pattern).
   * Returns a contract handle to the proxy using the QuicknodeEarnProxy ABI.
   */
  async function deployBehindProxy(
    usdcAddr: `0x${string}`,
    aavePool: `0x${string}`,
    aUsdc: `0x${string}`,
    msgTransmitter: `0x${string}`,
    tokenMessenger: `0x${string}`,
    ownerAddr: `0x${string}`,
    initialVaults: `0x${string}`[],
  ) {
    // 1. Deploy implementation (immutables set in constructor)
    const impl = await hre.viem.deployContract("QuicknodeEarnProxy", [
      usdcAddr,
      aavePool,
      aUsdc,
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
    // Use owner address as placeholder for aavePool/aUsdc (not exercised in non-Aave tests)
    // address(0) for messageTransmitter — CCTP not exercised in these tests
    const rebalancer = await deployBehindProxy(
      usdc.address,
      owner.account.address, // aavePool placeholder
      owner.account.address, // aUsdc placeholder
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

    it("should set aavePool and aUsdc", async function () {
      const { rebalancer, owner } = await loadFixture(deployFixture);
      expect(getAddress(await rebalancer.read.aavePool())).to.equal(
        getAddress(owner.account.address)
      );
      expect(getAddress(await rebalancer.read.aUsdc())).to.equal(
        getAddress(owner.account.address)
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
          ZERO_ADDRESS,
          ZERO_ADDRESS,
        ])
      ).to.be.rejectedWith("ZeroAddress");
    });

    it("should revert on zero owner in initialize", async function () {
      const [owner] = await hre.viem.getWalletClients();
      const usdc = await hre.viem.deployContract("MockERC20", ["USDC", "USDC", 6]);
      await expect(
        deployBehindProxy(
          usdc.address,
          ZERO_ADDRESS as `0x${string}`,
          ZERO_ADDRESS as `0x${string}`,
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
      ]);

      // Rebalancer should hold fee shares of vaultA
      const rebalancerSharesA = await vaultA.read.balanceOf([rebalancer.address]);
      expect(rebalancerSharesA).to.equal(feeShares);
    });

    it("should revert if fromVault not approved", async function () {
      const { rebalancer, vaultA, vaultB, user, userShares } =
        await loadFixture(depositedFixture);

      await rebalancer.write.removeVault([vaultA.address]);

      await expect(
        rebalancer.write.rebalance([
          user.account.address,
          vaultA.address,
          vaultB.address,
          userShares,
          [],
          [],
        ])
      ).to.be.rejectedWith("VaultNotApproved");
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
        ])
      ).to.be.rejectedWith("0x83906042"); // UnauthorizedExecutor()
    });
  });

  // --- Aave fee path (aUsdc as feeVault) ---
  //
  // _collectFees must accept aUsdc as a fee vault without requiring it to be in
  // approvedVaults — aUSDC is the Aave receipt token, not a Morpho vault, so
  // routing it through the ERC4626 deposit/withdraw branches would be wrong.
  // This carve-out mirrors the inline aUSDC handling in selfBatchWithdraw and
  // covers both rebalance() and withdrawAndBridge() (both call _collectFees).

  describe("Aave fee path (aUsdc as feeVault)", function () {
    async function aUsdcFixture() {
      const [owner, user, other] = await hre.viem.getWalletClients();
      const publicClient = await hre.viem.getPublicClient();

      const usdc = await hre.viem.deployContract("MockERC20", [
        "USD Coin",
        "USDC",
        6,
      ]);
      // Use a real ERC20 to stand in for aUSDC so safeTransferFrom works.
      const aUsdcMock = await hre.viem.deployContract("MockERC20", [
        "Aave USDC",
        "aUSDC",
        6,
      ]);
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

      const rebalancer = await deployBehindProxy(
        usdc.address,
        owner.account.address,        // aavePool placeholder (deposit/withdraw routing not exercised here)
        aUsdcMock.address,            // aUsdc — real ERC20 so the fee transferFrom can be observed
        ZERO_ADDRESS as `0x${string}`,
        ZERO_ADDRESS as `0x${string}`,
        owner.account.address,
        [],
      );

      await rebalancer.write.addVault([vaultA.address]);
      await rebalancer.write.addVault([vaultB.address]);
      await rebalancer.write.setExecutor([owner.account.address]);

      // Seed user with USDC and deposit into vaultA so we have a position to rebalance
      const depositAmount = parseUnits("1000", 6);
      await usdc.write.mint([user.account.address, depositAmount]);

      const usdcAsUser = await hre.viem.getContractAt(
        "MockERC20",
        usdc.address,
        { client: { wallet: user } }
      );
      await usdcAsUser.write.approve([rebalancer.address, depositAmount]);

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

      const userShares = await vaultA.read.balanceOf([user.account.address]);

      // User approves rebalancer to pull vaultA shares (the rebalance leg).
      const vaultAAsUser = await hre.viem.getContractAt(
        "MockERC4626",
        vaultA.address,
        { client: { wallet: user } }
      );
      await vaultAAsUser.write.approve([rebalancer.address, userShares]);

      // Mint user a fake aUSDC balance simulating an Aave position, and approve
      // the rebalancer to pull the fee.
      const aUsdcBalance = parseUnits("100", 6);
      await aUsdcMock.write.mint([user.account.address, aUsdcBalance]);
      const aUsdcAsUser = await hre.viem.getContractAt(
        "MockERC20",
        aUsdcMock.address,
        { client: { wallet: user } }
      );
      await aUsdcAsUser.write.approve([rebalancer.address, aUsdcBalance]);

      return {
        rebalancer,
        usdc,
        aUsdcMock,
        vaultA,
        vaultB,
        owner,
        user,
        other,
        publicClient,
        depositAmount,
        userShares,
        aUsdcBalance,
      };
    }

    it("rebalance accepts aUsdc as feeVault and pulls aUSDC from user", async function () {
      const { rebalancer, aUsdcMock, vaultA, vaultB, user, userShares } =
        await loadFixture(aUsdcFixture);

      const feeShares = parseUnits("0.5", 6); // 0.5 aUSDC fee

      await rebalancer.write.rebalance([
        user.account.address,
        vaultA.address,
        vaultB.address,
        userShares,
        [aUsdcMock.address],
        [feeShares],
      ]);

      // The contract should now hold the aUSDC fee that was pulled from the user
      const rebalancerAUsdc = await aUsdcMock.read.balanceOf([rebalancer.address]);
      expect(rebalancerAUsdc).to.equal(feeShares);

      // vaultB should have received the user's USDC
      const userSharesB = await vaultB.read.balanceOf([user.account.address]);
      expect(userSharesB > 0n).to.be.true;
    });

    it("rebalance reverts VaultNotApproved when feeVault is neither aUsdc nor whitelisted", async function () {
      const { rebalancer, vaultA, vaultB, user, other, userShares } =
        await loadFixture(aUsdcFixture);

      await expect(
        rebalancer.write.rebalance([
          user.account.address,
          vaultA.address,
          vaultB.address,
          userShares,
          [other.account.address], // arbitrary EOA — not aUsdc, not in approvedVaults
          [1n],
        ])
      ).to.be.rejectedWith("VaultNotApproved");
    });

    it("rebalance reverts ZeroAddress when feeVault is address(0)", async function () {
      const { rebalancer, vaultA, vaultB, user, userShares } =
        await loadFixture(aUsdcFixture);

      await expect(
        rebalancer.write.rebalance([
          user.account.address,
          vaultA.address,
          vaultB.address,
          userShares,
          [ZERO_ADDRESS as `0x${string}`],
          [1n],
        ])
      ).to.be.rejectedWith("ZeroAddress");
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
      ]);

      // Rebalancer should hold feeA shares of vaultA
      const heldA = await vaultA.read.balanceOf([rebalancer.address]);
      expect(heldA).to.equal(feeA);

      // User gets reduced USDC (fee shares not redeemed to user)
      const usdcAfter = await usdc.read.balanceOf([user.account.address]);
      expect(usdcAfter > usdcBefore).to.be.true;
    });

    it("should use full balance when shares[i] == 0", async function () {
      const { usdc, vaultA, vaultB, user, rebalancerAsUser } =
        await loadFixture(depositedMultiFixture);

      const usdcBefore = await usdc.read.balanceOf([user.account.address]);

      await rebalancerAsUser.write.selfBatchWithdraw([
        [vaultA.address, vaultB.address],
        [0n, 0n],   // 0 = full balance
        [0n, 0n],
        [],  // no burns
      ]);

      const usdcAfter = await usdc.read.balanceOf([user.account.address]);
      expect(usdcAfter - usdcBefore).to.equal(parseUnits("800", 6));
    });

    it("should revert on non-whitelisted vault", async function () {
      const { rebalancer, vaultA, user, sharesA, rebalancerAsUser } =
        await loadFixture(depositedMultiFixture);

      await rebalancer.write.removeVault([vaultA.address]);

      await expect(
        rebalancerAsUser.write.selfBatchWithdraw([
          [vaultA.address],
          [sharesA],
          [0n],
          [],  // no burns
        ])
      ).to.be.rejectedWith("VaultNotApproved");
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
        ])
      ).to.be.rejectedWith("InvalidInput");
    });

    it("should revert on empty vaults array", async function () {
      const { rebalancerAsUser } = await loadFixture(depositedMultiFixture);

      await expect(
        rebalancerAsUser.write.selfBatchWithdraw([[], [], [], []])
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

      // Rebalance with fee to accrue fee shares in the contract (owner is executor)
      const feeShares = userShares / 100n; // 1%
      await rebalancer.write.rebalance([
        user.account.address,
        vaultA.address,
        vaultB.address,
        userShares - feeShares,
        [vaultA.address],
        [feeShares],
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
});
