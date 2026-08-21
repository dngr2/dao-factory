# DAO Governance Factory

Launch a complete, self-governing on-chain DAO in a single transaction. For teams,
DAOs, and communities that need a votes-token, a timelock, and a Governor wired
together correctly — without hand-assembling the role plumbing that usually gets it
wrong.

## Why this factory

Standing up a DAO by hand means deploying three contracts and then wiring a maze of
timelock roles: grant the Governor the proposer and canceller roles, open execution,
and renounce every admin backdoor. Miss one step and the DAO is either bricked or
still centrally controlled by whoever deployed it.

**One `createDao(...)` call produces a DAO that is self-sovereign at birth.** The
factory grants the Governor `PROPOSER_ROLE` and `CANCELLER_ROLE` on the timelock,
opens `EXECUTOR_ROLE` to `address(0)` (anyone may execute a ripe, queued proposal),
and — in the same transaction — renounces its own `DEFAULT_ADMIN_ROLE`. The timelock
ends up as its own sole administrator. The deployer keeps **no** role, and there is
no residual factory backdoor over a DAO once `createDao` returns.

That "no backdoor remains" property is not a claim on faith. The deep-dive audit
pass reviewed the role wiring line by line and confirmed it directly in a test:
`test_Deploy_RolesWiredAndAdminRenounced` asserts the factory does **not** hold
`DEFAULT_ADMIN_ROLE` after deployment and that the timelock self-administers. The
audit found the wiring textbook-correct — no exploitable path for the deployer or a
third party to retain proposer/canceller/executor/admin power over a fresh DAO.

The full governance lifecycle — propose, vote, queue, execute — is tested end to
end, including adversarial cases: quorum boundaries (exactly met vs. one vote
short), timelock-delay enforcement (execute-before-delay reverts), and
execution authority (only queued-and-ripe proposals run, though any address may
trigger them). Everything is built on standard, audited OpenZeppelin v5 modules —
no custom governance math.

## What it deploys

A single `createDao(...)` transaction deploys and wires three contracts:

- **DaoToken** — an `ERC20Votes` governance token (ERC20 + ERC20Permit +
  checkpointed voting power). The full initial supply is minted to a holder you
  specify. Holders must self-delegate to activate their voting power.
- **TimelockController** — the OpenZeppelin timelock that holds the DAO's assets and
  authority; every passed proposal executes through it after a mandatory delay.
- **DaoGovernor** — an OZ v5 `Governor` composed of `GovernorSettings` (voting
  delay / period / proposal threshold), `GovernorCountingSimple`, `GovernorVotes`
  (bound to the token), `GovernorVotesQuorumFraction` (percentage quorum), and
  `GovernorTimelockControl` (bound to the timelock).

The governor and token run on the OZ default block-number clock; the timelock delay
is measured in seconds.

**Per-DAO fee.** Each deployment charges a bounded flat protocol fee (`msg.value`),
forwarded to a configurable `feeRecipient`. The fee is capped at `MAX_FEE` (0.1 ETH)
and can never be set above it. Fee `0` is allowed and deploys for free. The factory
owner can update the fee and the recipient, but has no power over any DAO it creates.

## Security & testing

The repo went from thin deployment tests to full adversarial coverage: **48 tests,
all passing** (`forge test`), split across a base suite (16) and a governance
adversarial suite (32).

Coverage includes:

- **Role wiring & self-sovereignty** — `test_Deploy_RolesWiredAndAdminRenounced`
  (governor is proposer/canceller, executor open, factory admin renounced, timelock
  self-administers), `test_Deploy_GovernorBoundToTokenAndTimelock`,
  `test_Deploy_TokenSupplyAndHolder`.
- **Full lifecycle** — `test_FullLifecycle_ProposeVoteQueueExecute` and
  `test_FullLifecycle_TreasuryTransferByDao` run propose → vote → queue → execute
  for both a governed external call and a DAO-treasury transfer.
- **Quorum boundaries** — `test_Quorum_ExactlyMet_Succeeds` vs.
  `test_Quorum_OneVoteShort_Defeated`; against-outweighs-for and an exact tie both
  defeat despite quorum.
- **Timelock-delay enforcement** — `test_Execute_BeforeTimelockDelay_Reverts`,
  `test_Execute_JustBeforeDelay_Reverts` (one second short), and
  `test_Execute_AfterDelay_Succeeds`; defeated and unqueued proposals cannot be
  queued or executed.
- **Execution authority** — `test_Execute_ByStranger_Allowed_WhenReady` confirms the
  open executor role lets any address trigger a ready, queued proposal, while
  `test_GovernedAction_OnlyTimelockCanCall` confirms governed targets accept calls
  only from the timelock.
- **Voting & proposal integrity** — double-vote reverts, propose-at-threshold
  succeeds vs. one-below reverts, cancel-by-proposer-while-pending vs.
  non-proposer/post-active reverts.
- **Governance-only mutation** — `setVotingDelay` / `updateQuorumNumerator` revert on
  direct calls and take effect only through a passed proposal via the timelock.
- **Delegation & isolation** — no votes until delegated, re-delegation mid-proposal
  keeps the snapshot weight, and two DAOs from the same factory share no supply,
  votes, or records.
- **Fee surface** — exact-cap allowed, wrong `msg.value` (under/over) reverts,
  zero-address recipient guards, fee-transfer-failure reverts, ownership
  transfer/renounce.

The deep-dive also ran a one-off mutation **check** to confirm the tests bite:
forcing `quorum()` to return `0` broke a quorum test as expected, then the change was
reverted. This was a single sanity check, **not** a mutation-testing campaign — no
mutation tooling or score is claimed.

Reference gas (from `forge test --gas-report` on this repo, not a live deployment): a
full one-call DAO deployment via `createDao` costs roughly **6.16M gas** (median).

```
forge test
forge test --gas-report
```

## Usage

`createDao` takes ten arguments and returns the three deployed addresses. Send
exactly the current `fee` as `msg.value`.

```solidity
DaoFactory factory = new DaoFactory(0.01 ether, feeRecipient);

(address token, address timelock, address governor) = factory.createDao{value: 0.01 ether}(
    "Acme DAO",          // name          – governor name / EIP-712 domain
    "Acme Token",        // tokenName     – ERC20 name
    "ACME",              // tokenSymbol   – ERC20 symbol
    1_000_000e18,        // initialSupply – minted to initialHolder
    initialHolder,       // initialHolder – recipient of the initial supply
    uint48(7200),        // votingDelay   – blocks before voting opens
    uint32(50400),       // votingPeriod  – voting window, in blocks
    4,                   // quorumPercent – quorum as % of supply (0–100)
    2 days,              // timelockDelay – timelock minimum delay, in seconds
    0                    // proposalThreshold – min votes to submit a proposal
);
```

Argument order matters: `quorumPercent` precedes `timelockDelay`, and
`proposalThreshold` is last. `quorumPercent` must be `≤ 100` and `initialHolder`
must be non-zero, or the call reverts.

## License

MIT. This is clean-room code that assembles standard OpenZeppelin v5 modules; it has
**not** been through a third-party security audit. The "deep dive" referenced above
is this project's own review and test-hardening pass, not an external audit. Review
the parameters and the contracts before deploying to mainnet.
