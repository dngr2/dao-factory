# Pitch

Standing up a real on-chain DAO means deploying a votes-token, a timelock, and a
Governor, then wiring a maze of timelock roles correctly — grant the right proposer
and canceller roles, open execution, and renounce every admin backdoor. Get one step
wrong and the DAO is either bricked or still centrally controlled by whoever deployed
it.

**DaoFactory does it in one call.** `createDao(...)` deploys the token, timelock, and
Governor and wires the roles so the DAO is self-sovereign the moment the transaction
returns: the Governor holds the proposer and canceller roles, execution is open to
anyone, and the factory renounces its own timelock admin in the same call. The
deployer keeps no role and no backdoor remains — a property this project's deep-dive
audit verified directly in a test (`test_Deploy_RolesWiredAndAdminRenounced`).

It is clean-room code assembling only standard, audited OpenZeppelin v5 modules, and
it ships with a Foundry suite of **48 passing tests** that exercises the full
propose → vote → queue → execute lifecycle plus adversarial cases — quorum
boundaries, timelock-delay enforcement, and execution authority — not just
deployment.

The factory earns a **bounded flat protocol fee per DAO** (capped at 0.1 ETH),
forwarded to a configurable recipient — a simple, transparent way to monetize DAO
tooling without holding any power over the DAOs it creates.
