# Contract Verification

This project uses the **Etherscan V2 API** to verify contracts on all supported chains, including ones that Foundry doesn't natively recognise (e.g. Monad).

## Why Etherscan V2?

The V2 API unifies 60+ chains under a single account and API key. Instead of separate keys per explorer, one Etherscan/Basescan key works everywhere — you just change the `chainid` query parameter.

V2 chainlist: `https://api.etherscan.io/v2/chainlist`

Supported chains used in this project:

| Chain | Chain ID | API URL                                        |
| ----- | -------- | ---------------------------------------------- |
| Base  | 8453     | `https://api.etherscan.io/v2/api?chainid=8453` |
| Monad | 143      | `https://api.etherscan.io/v2/api?chainid=143`  |

## Prerequisites

Set `ETHERSCAN_API_KEY` in your `.env` (one key works for all chains via V2).

## Step 1 — Flatten the contract

```bash
forge flatten contracts/QuicknodeEarnProxy.sol > /tmp/QuicknodeEarnProxy_flat.sol
```

## Step 2 — Encode constructor args

Use `cast abi-encode` with the constructor signature and the exact args passed at deploy time. Output is hex with a `0x` prefix — strip the prefix before sending to the API.

**Monad example (no Aave):**

```bash
source .env

ARGS=$(cast abi-encode \
  "constructor(address,address,address,address,address)" \
  0x754704Bc059F8C67012fEd69BC8A327a5aafb603 `# usdc` \
  0x0000000000000000000000000000000000000000 `# aavePool (none)` \
  0x0000000000000000000000000000000000000000 `# aUsdc (none)` \
  0x81D40F21F12A8F0E3252Bccb954D722d4c464B64 `# messageTransmitter` \
  0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d) `# tokenMessenger`

ARGS_RAW="${ARGS#0x}"   # strip 0x prefix
```

**Base example (with Aave):**

```bash
ARGS=$(cast abi-encode \
  "constructor(address,address,address,address,address)" \
  0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 `# usdc` \
  0xA238Dd80C259a72e81d7e4664a9801593F98d1c5 `# aavePool` \
  0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB `# aUsdc` \
  0x81D40F21F12A8F0E3252Bccb954D722d4c464B64 `# messageTransmitter` \
  0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d) `# tokenMessenger`

ARGS_RAW="${ARGS#0x}"
```

> **Tip:** Get the exact vault list from the deployed contract:
>
> ```bash
> cast call --rpc-url "$MONAD_RPC_URL" <CONTRACT_ADDRESS> "getApprovedVaults()(address[])"
> ```

## Step 3 — Submit verification

```bash
curl -s -X POST "https://api.etherscan.io/v2/api?chainid=<CHAIN_ID>" \
  --data-urlencode "module=contract" \
  --data-urlencode "action=verifysourcecode" \
  --data-urlencode "apikey=$ETHERSCAN_API_KEY" \
  --data-urlencode "contractaddress=<CONTRACT_ADDRESS>" \
  --data-urlencode "sourceCode=$(cat /tmp/QuicknodeEarnProxy_flat.sol)" \
  --data-urlencode "codeformat=solidity-single-file" \
  --data-urlencode "contractname=QuicknodeEarnProxy" \
  --data-urlencode "compilerversion=v0.8.28+commit.7893614a" \
  --data-urlencode "optimizationUsed=1" \
  --data-urlencode "runs=200" \
  --data-urlencode "constructorArguements=$ARGS_RAW" \
  --data-urlencode "licenseType=3"
```

A successful response returns a GUID:

```json
{ "status": "1", "message": "OK", "result": "p8mqe6h4d8njzmbq4ug..." }
```

## Step 4 — Poll for result

```bash
curl -s "https://api.etherscan.io/v2/api?chainid=<CHAIN_ID>&module=contract&action=checkverifystatus&guid=<GUID>&apikey=$ETHERSCAN_API_KEY"
```

Success:

```json
{ "status": "1", "message": "OK", "result": "Pass - Verified" }
```

## License types

| Code | License    |
| ---- | ---------- |
| 1    | No License |
| 3    | MIT        |
| 5    | GPL-2.0    |

## Compiler version

Find the exact version from the build artifact:

```bash
cat out/QuicknodeEarnProxy.sol/QuicknodeEarnProxy.json \
  | python3 -c "import json,sys; m=json.load(sys.stdin)['metadata']; print(m['compiler']['version'])"
```

## Why not `forge verify-contract`?

Forge 1.5.x only accepts `--verifier etherscan` for chains in its built-in chain list. Monad mainnet (chain ID 143) is not yet in that list. Using the Etherscan V2 API directly bypasses this limitation and works for any chain Etherscan supports.

To check if a chain is supported:

```bash
curl -s "https://api.etherscan.io/v2/chainlist?apikey=$ETHERSCAN_API_KEY" \
  | python3 -c "import json,sys; [print(c['chainid'], c['chainname']) for c in json.load(sys.stdin)['result']]"
```
