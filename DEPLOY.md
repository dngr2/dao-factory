# Deploying DaoFactory

`script/Deploy.s.sol` deploys a single `DaoFactory`. The deployer address becomes
the factory `owner` (it can later call `setFee` / `setFeeRecipient`). Individual
DAOs are **not** created at deploy time — you create each one afterwards with
`factory.createDao(...)` (see below).

> **Status: unaudited.** These contracts have **not** been audited. Deploy to a
> testnet first, exercise the full flow, and do not put material funds at risk on
> mainnet without an independent security review.

## 1. Environment variables

| Var             | Required | Meaning                                                                 |
| --------------- | -------- | ----------------------------------------------------------------------- |
| `FEE_RECIPIENT` | yes      | Address that receives protocol fees. Must be non-zero.                  |
| `INITIAL_FEE`   | no       | Starting flat fee per DAO in **wei**. Must be `<= 0.1 ether` (MAX_FEE). Defaults to `0`. |
| `RPC_URL`       | yes      | RPC endpoint for the target network.                                    |

The broadcasting/deployer key is passed to `forge script` on the command line — it
is **not** read from an env var by the script.

Example `.env` (git-ignored):

```sh
export FEE_RECIPIENT=0xYourFeeRecipient
export INITIAL_FEE=0                      # wei; e.g. 10000000000000000 = 0.01 ether
export RPC_URL=https://sepolia.example-rpc
```

## 2. Use a dedicated deployer key

Use a fresh key created only for deployments — never a personal or treasury key.
Fund it with just enough gas. Prefer a hardware signer or an encrypted keystore
over a raw private key:

```sh
# One-time: import a key into an encrypted keystore named "daoDeployer"
cast wallet import daoDeployer --interactive
```

## 3. Deploy — testnet first

Load env and run the script. Start on a testnet (e.g. Sepolia):

```sh
source .env

forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$RPC_URL" \
  --account daoDeployer \
  --broadcast \
  -vvvv
```

Alternatives to `--account daoDeployer`: `--ledger` (hardware wallet) or, for
throwaway testnet keys only, `--private-key "$PRIVATE_KEY"`.

Add on-chain verification (optional) with `--verify --etherscan-api-key "$ETHERSCAN_API_KEY"`.
Verification is best-effort and network-dependent; if it fails you can re-run
`forge verify-contract` afterwards. The deployed factory address is printed by the
script (`DaoFactory deployed at: 0x...`) and recorded under `broadcast/`.

Only after a clean testnet run should you repeat against a mainnet `RPC_URL`.

## 4. Create a DAO after deploy

The factory is a launcher; each DAO is created by calling `createDao` on the
deployed factory. You must send exactly `factory.fee()` as `msg.value`. The
10-argument signature is:

```solidity
function createDao(
    string  name,             // Governor name (also EIP-712 domain)
    string  tokenName,        // ERC20 token name
    string  tokenSymbol,      // ERC20 token symbol
    uint256 initialSupply,    // tokens minted to initialHolder at deploy
    address initialHolder,    // recipient of the initial supply
    uint48  votingDelay,      // blocks before voting opens
    uint32  votingPeriod,     // voting window length, in blocks
    uint256 quorumPercent,    // quorum as percent of total supply (0-100)
    uint256 timelockDelay,    // timelock minimum delay, in seconds
    uint256 proposalThreshold // minimum votes to submit a proposal
) external payable returns (address token, address timelock, address governor);
```

Example with `cast` (sends `--value` equal to the current fee — here `0`):

```sh
cast send <FACTORY_ADDRESS> \
  "createDao(string,string,string,uint256,address,uint48,uint32,uint256,uint256,uint256)" \
  "My DAO" "My Token" "MYT" \
  1000000000000000000000 0xInitialHolder \
  7200 50400 4 172800 0 \
  --value 0 \
  --rpc-url "$RPC_URL" --account daoDeployer
```

The `DaoCreated` event and the return values give you the token, timelock, and
governor addresses. Repeat `createDao` for each additional DAO.
