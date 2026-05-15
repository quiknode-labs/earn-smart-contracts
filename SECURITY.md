# Security

## Reporting a vulnerability

Please report any security issue you find in the contracts under `contracts/` privately. **Do not file a public GitHub issue.**

Email: `security@quicknode.com`

Please include:

- A clear description of the issue and its impact.
- Steps to reproduce, ideally with a Foundry or Hardhat test case.
- Any suggested mitigations.

We aim to acknowledge reports within 48 hours.

## Audit

The production implementation `contracts/QuicknodeEarnProxy.sol` was reviewed by OpenZeppelin. The full report is committed at [`audits/OpenZeppelin_Audit.pdf`](audits/OpenZeppelin_Audit.pdf).

The non-upgradeable variant `contracts/QuicknodeEarn.sol` shares the same business logic.

## Scope

In scope:

- `contracts/QuicknodeEarnProxy.sol` (deployed UUPS implementation)
- `contracts/QuicknodeEarn.sol` (non-upgradeable reference variant)
- `contracts/interfaces/`
- `script/Deploy.s.sol`

Out of scope:

- `contracts/test/` — mocks used only by the test suite
- `lib/`, `node_modules/` — third-party dependencies (report upstream where applicable)
- Off-chain executor / relayer / frontend code (lives in the parent operator repo)

## Trust assumptions

The contract has three privileged roles. A non-technical security overview is at [`docs/security-overview.md`](docs/security-overview.md). In short:

- **Owner** (multisig) — vault whitelist, fee sweeps, role assignment, UUPS upgrade. A compromised owner key can drain users with active approvals.
- **Executor** — `rebalance`, `withdrawAndBridge`. Cannot redirect funds outside the user wallet or approved-vault set, but can claim inflated fee amounts (fee math is off-chain).
- **Relayer** — `relayAndDeposit`. Cannot redirect bridged shares (CCTP hookData binds the beneficiary).

Users have a fully trustless exit via `selfBatchWithdraw` and a permissionless cross-chain claim via `emergencyClaimBridge`.
