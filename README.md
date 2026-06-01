# earn-smart-contracts

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Non-custodial yield optimiser for USDC. Routes user funds across whitelisted ERC4626 vaults (Morpho) on multiple chains, rebalanced by an off-chain executor for highest supply APY. Same UUPS proxy address on every supported chain.

The production implementation is [`contracts/QuicknodeEarnProxy.sol`](contracts/QuicknodeEarnProxy.sol). The non-upgradeable variant [`contracts/QuicknodeEarn.sol`](contracts/QuicknodeEarn.sol) is kept in-tree as an audit-parity reference.

## At a glance

- **Non-custodial** — users grant ERC20 approvals; vault shares are minted directly to the user's wallet. The contract holds no user principal at rest.
- **Three roles** — owner (multisig: vault whitelist, fee sweeps, role assignment, UUPS upgrade), executor (`rebalance`, `withdrawAndBridge`), relayer (`relayAndDeposit`).
- **Trustless exit** — `selfBatchWithdraw` works with no privileged-role involvement; `emergencyClaimBridge` covers stuck cross-chain deposits if the relayer is offline.
- **Vault-share performance fee** — fee amounts are computed off-chain (15% of yield), passed in as `feeVaults[]`/`feeAmounts[]`, transferred to the contract, and swept by the owner.
- **CCTP V2 cross-chain** — `withdrawAndBridge` (executor) and `relayAndDeposit` (relayer) move USDC between chains via Circle's CCTP V2.

A non-technical breakdown of the security model lives in [`docs/security-overview.md`](docs/security-overview.md).

## Audit

OpenZeppelin reviewed `QuicknodeEarnProxy.sol`. Full report: [`audits/OpenZeppelin_Audit.pdf`](audits/OpenZeppelin_Audit.pdf).

To report a vulnerability, see [`SECURITY.md`](SECURITY.md).

## Live deployments

The active proxy is deployed at the same address on every supported chain via CreateX CREATE3 (salt v12):

```
0x48b415841165304f7EfaA7D5dD5FC65cc7B4bd8e
```

Per-chain implementation addresses, vault whitelists, and the deploy/upgrade runbook live in the operator repo:

- [`docs-internal/contracts/multichain-deployments.md`](../docs-internal/contracts/multichain-deployments.md) — live state
- [`docs-internal/contracts/deployment-runbook.md`](../docs-internal/contracts/deployment-runbook.md) — deploy & UUPS upgrade workflow
- [`docs-internal/contracts/contract-verification.md`](../docs-internal/contracts/contract-verification.md) — Etherscan V2 verification

## Build & test

```bash
# Install dependencies
npm install                  # OpenZeppelin contracts (npm)
forge install                # forge-std

# Foundry — build (verifies compilation across all targets)
forge build

# Hardhat — TS test suite (uses viem)
npm test
```

The Foundry profile (`foundry.toml`) is what implementations are compiled with for production deployment: `solc 0.8.28`, `optimizer = true`, `optimizer_runs = 200`, `via_ir = true`, `evm_version = "cancun"`, `bytecode_hash = "none"` (for cross-explorer verification reproducibility).

## Layout

```
contracts/
  QuicknodeEarnProxy.sol        UUPS implementation — production
  QuicknodeEarn.sol             non-upgradeable reference
  interfaces/                   ICreateX (used by deploy script)
  test/                         mocks (MockERC20, MockERC4626, ERC1967ProxyImport)
script/
  Deploy.s.sol                  forge deploy script (CreateX CREATE3)
test/
  QuicknodeEarn.test.ts         Hardhat + viem integration tests
docs/
  security-overview.md          plain-English security model
audits/
  OpenZeppelin_Audit.pdf
.github/
  storage-snapshots/EarnStorage.struct  ERC-7201 layout snapshot for upgrade safety
```

## License

[MIT](LICENSE).
