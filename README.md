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

## Expansion (v2): TWAP oracle, flash swaps, permit liquidity

Three additive features layered on the v1 core. All v1 behavior and tests are unchanged.

### Cumulative-price TWAP oracle

`Pair` now maintains Uniswap-V2-style cumulative-price accumulators, `price0CumulativeLast`
and `price1CumulativeLast` (UQ112.112 fixed-point). In `_update` (called by
`mint`/`burn`/`swap`/`sync`), when `timeElapsed > 0` and the pre-update reserves are non-zero,
each accumulator advances by the **elapsed-time-weighted price computed from the reserves that
held _before_ the update**:

```
price0CumulativeLast += encode(reserve1).uqdiv(reserve0) * timeElapsed  // price of token0 in token1
price1CumulativeLast += encode(reserve0).uqdiv(reserve1) * timeElapsed  // price of token1 in token0
```

`getReserves()` exposes `blockTimestampLast` for the elapsed-time delta. Timestamp truncation
to `uint32` and accumulator wrap-around are intentional (`unchecked`), matching V2 semantics.

`src/TwapOracle.sol` is a consumer bound to one pair. `update()` samples the pair's cumulatives
(extrapolated to the current block via `currentCumulativePrices()`) and, once at least `period`
seconds have elapsed, stores the average price over the window as
`(cumulativeNow - cumulativeLast) / timeElapsed`. `consult(token, amountIn) -> amountOut`
returns the TWAP-based quote. Because the average integrates price over the whole window, a
single-block spot manipulation moves the reported TWAP by only ~`(1 block / window)`.

### Flash swaps

`Pair.swap(amount0Out, amount1Out, to, bytes data)` is added alongside the original
`swap(amount0Out, amount1Out, to)` (which is preserved and simply forwards with empty data).
When `data.length > 0`, the outputs are transferred optimistically and
`IFlashSwapCallee(to).flashSwapCall(msg.sender, amount0Out, amount1Out, data)` is invoked before
the k-invariant is checked on the **post-callback** balances. The borrower must return the
borrowed tokens plus the 0.30% fee (or supply the other side); otherwise the invariant check
reverts `KInvariantViolated`. The whole call remains `nonReentrant`. See
`test/mocks/ExampleFlashSwapper.sol`.

### ERC-2612 permit liquidity removal

The `Pair` LP token now extends `ERC20Permit` (EIP-2612). `Router.removeLiquidityWithPermit(...)`
lets an LP authorize the router to pull LP tokens with an off-chain signature (`v, r, s`,
plus `approveMax`), removing liquidity without a separate `approve` transaction.

New tests: `test/TwapOracle.t.sol`, `test/FlashSwap.t.sol`, `test/Permit.t.sol`.

## License

MIT
