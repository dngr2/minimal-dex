# Minimal DEX — Pitch

A lean, audited-style constant-product AMM you can drop in and run. Three contracts, no
external dependencies beyond OpenZeppelin, and a fee switch the protocol controls.

- **Familiar and safe.** Uniswap-V2 mechanics — the most battle-tested AMM design — written
  clean-room with custom errors, CEI ordering, and reentrancy guards throughout.
- **Earns fees.** Every swap charges 0.30%. LPs keep the bulk; a governance-set, hard-capped
  protocol cut (≤ 50% of the swap fee) can be switched on to fund the protocol.
- **Hard to grief.** First-deposit inflation is neutralized by the `MINIMUM_LIQUIDITY` lock;
  swap accounting uses realized balance deltas, so fee-on-transfer tokens can't desync reserves.
- **Proven, not promised.** Full Foundry suite: unit tests for every path plus a stateful
  invariant run asserting k never decreases on swaps, supply always equals the sum of LP
  balances, and balances always cover reserves. A mutation check confirms the fee math is
  load-bearing.

MIT licensed. `forge test` is green.
