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

## Deep dive (v2): hardening + full lifecycle/adversarial coverage

A second pass audited the role wiring, the OZ v5 Governor override set, clock-mode
consistency, quorum arithmetic, and the factory fee surface line by line. The
wiring proved textbook-correct — the timelock self-administers, the factory
renounces its temporary admin inside the same `createDao` call, and neither the
deployer nor any third party retains proposer/canceller/executor power over a
fresh DAO — so no exploitable bug was found. The work therefore focused on
turning thin coverage into a deep adversarial suite (16 -> 48 tests):

- **Quorum boundary** — exactly met (succeeds) vs. one vote short (defeated);
  against-outweighs-for and an exact tie both defeat despite quorum.
- **Voting integrity** — double-vote / vote-change reverts; propose at threshold
  succeeds, one below reverts.
- **Cancel** — proposer-while-pending succeeds; non-proposer and post-Active revert.
- **Timelock delay** — execute before the delay (and one second short) reverts,
  after passes; unqueued/defeated proposals cannot be queued or executed; the open
  executor role lets any address trigger a ready, queued proposal.
- **Governance-only mutation** — `setVotingDelay` / `updateQuorumNumerator` revert
  on direct calls and only take effect through a passed proposal via the timelock.
- **Factory isolation** — two DAOs share no token supply, votes, or records.
- **Delegation** — no votes until delegated; a re-delegation mid-proposal keeps the
  original delegatee's snapshot weight and gives the new one none.
- **Fee surface** — rejecting recipient reverts the deploy, exact-cap allowed,
  under/over `msg.value` revert, zero-address guards, ownership transfer/renounce.

A mutation check (forcing `quorum()` to `0`) was confirmed to break a quorum test,
then reverted.

## License

MIT
