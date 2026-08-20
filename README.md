# DAO Governance Factory

A one-call deployer for a complete, self-sovereign on-chain DAO. A single
`createDao(...)` transaction deploys and wires three standard OpenZeppelin v5
contracts:

- **DaoToken** — an `ERC20Votes` governance token (ERC20 + ERC20Permit +
  checkpointed voting power). The full initial supply is minted to a holder you
  specify at deployment.
- **TimelockController** — holds the DAO's assets and authority; every executed
  proposal runs through it after a mandatory delay.
- **DaoGovernor** — an OZ v5 `Governor` composed of `GovernorSettings`
  (voting delay / period / proposal threshold), `GovernorCountingSimple`,
  `GovernorVotes` (bound to the token), `GovernorVotesQuorumFraction` (percentage
  quorum), and `GovernorTimelockControl` (bound to the timelock).

## Wiring

`createDao` sets the DAO up to be self-governing before it returns:

- Governor is granted `PROPOSER_ROLE` and `CANCELLER_ROLE` on the timelock.
- `EXECUTOR_ROLE` is granted to `address(0)` — anyone may execute a queued,
  ripe proposal.
- The factory renounces the timelock's `DEFAULT_ADMIN_ROLE`, leaving the
  timelock as its own sole administrator. No deployer backdoor remains.

## Governance lifecycle

1. Token holders **delegate** voting power (to themselves or others).
2. A holder above the proposal threshold **proposes** a batch of calls.
3. After `votingDelay` blocks, voting opens; holders **cast votes**.
4. After `votingPeriod` blocks, if quorum is met and For > Against, the proposal
   **succeeds**.
5. Anyone **queues** it into the timelock, waits out `timelockDelay` seconds,
   then **executes** it. The calls run with the timelock's authority.

The clock is block-number based (OZ default) for the token and governor; the
timelock delay is measured in seconds.

## Protocol fee

Each deployment charges a **bounded flat fee** (`msg.value`), forwarded to
`feeRecipient`. The fee is capped at `MAX_FEE` (0.1 ETH) and can never be set
above it. The owner can update the fee and the recipient.

## Test

```
forge test
```

The suite covers deployment and role wiring, the full
propose → vote → queue → execute lifecycle (both a governed external call and a
treasury transfer), quorum-not-met defeat, below-threshold proposal revert,
direct-call authorization, and the full fee surface.

## License

MIT
