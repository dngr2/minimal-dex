# Minimal DEX

A production-quality, standalone **constant-product (x·y=k) AMM** in the Uniswap-V2 style:
a `Factory`, per-pair `Pair` pools (each pool is its own ERC20 LP token), and a user-facing
`Router`. Clean-room implementation of the well-known constant-product design. Every swap
charges a **0.30% fee**, of which a **bounded protocol cut** can accrue to a fee recipient.

## Contracts

| Contract | Responsibility |
| --- | --- |
| `src/Pair.sol` | A single `x·y=k` pool that is itself the ERC20 LP token. `mint`/`burn` liquidity, `swap` with the k-invariant enforced *after* fees, `skim`/`sync` for donations. Reentrancy-guarded. |
| `src/Factory.sol` | Deploys pairs deterministically (CREATE2 over sorted tokens), tracks `getPair`/`allPairs`, and owns the protocol-fee config (`feeTo`, `feeToSetter`, `protocolFeeBps`, capped). |
| `src/Router.sol` | User entry point: `addLiquidity`/`removeLiquidity` and `swapExactTokensForTokens`/`swapTokensForExactTokens` with min/max amounts, path routing, and deadlines. Standard `getAmountOut`/`getAmountIn` pricing. |

Interfaces live in `src/interfaces/`. Test mocks (`MockERC20`, `FeeOnTransferERC20`,
`MaliciousToken`) live under `test/mocks/`.

## Fees

- **Swap fee — 0.30%.** Enforced directly in `Pair.swap`: the k-invariant is checked on
  fee-adjusted balances (`balance*1000 - amountIn*3`), so the reserve product never
  decreases net of fees. `Router.getAmountOut`/`getAmountIn` use the matching `997/1000`.
- **Protocol cut — bounded, opt-in.** When the factory's `feeTo` is set and
  `protocolFeeBps > 0`, a share of the accrued swap fees is minted to `feeTo` on the next
  liquidity event using the V2 `kLast` (sqrt-of-k growth) accounting. The share is
  `protocolFeeBps / 10_000` of the fee growth, **capped at `MAX_PROTOCOL_FEE_BPS = 5000`**
  (50% of the swap fee). With `protocolFeeBps ≈ 1666` this reproduces V2's canonical
  1/6-of-fee split. When `feeTo` is unset, LPs keep 100% of the fee.

## Security properties

- First mint permanently locks `MINIMUM_LIQUIDITY = 1000` shares, defeating the
  first-depositor share-inflation attack.
- `swap`/`mint`/`burn`/`skim`/`sync` are `nonReentrant`.
- Swap input is derived from realized balance deltas, so fee-on-transfer input tokens are
  accounted correctly. (The `Router` swap helpers assume non-fee-on-transfer tokens; such
  tokens should be swapped against the `Pair` directly.)

## Test

```bash
forge test
```

Covers liquidity math and the `MINIMUM_LIQUIDITY` lock, exact-in/exact-out swaps against
`getAmountOut`/`getAmountIn`, k-non-decreasing, slippage and deadline reverts, two-hop
routing, the exact protocol-fee split (on and off), the share-inflation and reentrancy
attacks, fee-on-transfer accounting, and a stateful invariant suite (k never decreases on
swaps, `Σ LP balances == totalSupply`, balances ≥ reserves).

## License

MIT
