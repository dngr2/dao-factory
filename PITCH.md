# Pitch

Standing up a real on-chain DAO means deploying a votes-token, a timelock, and a
Governor, then wiring a maze of roles correctly — grant the right proposer and
canceller roles, open execution, and renounce every admin backdoor. Get one step
wrong and the DAO is either bricked or centrally controlled.

**DaoFactory does it in one call.** `createDao(...)` deploys the token, timelock,
and Governor, wires the roles, and hands back a DAO that governs itself — no
residual deployer control. It is clean-room code assembling only standard,
audited OpenZeppelin v5 modules, and it ships with a Foundry suite that exercises
a full propose → vote → queue → execute lifecycle, not just deployment.

The factory earns a **bounded flat protocol fee per DAO** (capped at 0.1 ETH),
forwarded to a configurable recipient — a simple, transparent way to monetize
DAO tooling without touching the DAOs it creates.
