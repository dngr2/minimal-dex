# Minimal DEX — Pitch

A self-contained constant-product AMM you deploy and control end to end — a `Factory`, `Pair`
pools, and a `Router`, plus an optional TWAP oracle. For teams that want their own auditable AMM,
not a hook riding on someone else's shared pool manager. Depends only on OpenZeppelin.

- **Safety enforced, not asserted.** The k-invariant is checked on fee-adjusted balances after
  every swap (and after any flash-swap callback), and a stateful invariant run asserts k never
  decreases across thousands of randomized operations. The `MINIMUM_LIQUIDITY` lock defeats the
  first-deposit share-inflation attack.
- **A manipulation-resistant price source built in.** The TWAP oracle integrates price over time,
  so a single-block swap that moves the spot price by over 50% shifts the reported TWAP by under
  2% (measured in the test suite).
- **Bounded, opt-in protocol fee.** Every swap charges 0.30%; LPs keep it all unless a
  governance-set protocol cut is switched on, and that cut is hard-capped at half the swap fee.
- **v2 extras.** Flash swaps and ERC-2612 permit-based liquidity removal, layered on without
  changing v1 behavior.
- **Proven.** 40 Foundry tests, all green: unit coverage per path, attack tests
  (inflation, reentrancy, fee-on-transfer), and three invariants — k non-decreasing, LP supply
  equals the sum of balances, balances cover reserves. Fee math is mutation-tested.

MIT licensed. `forge test` is green. No mainnet deployment, volume, or TVL is claimed.
