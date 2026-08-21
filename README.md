# Minimal DEX

A self-contained constant-product (x·y=k) AMM in the Uniswap-V2 style: a `Factory`, per-pair
`Pair` pools (each pool is its own ERC20 LP token), and a user-facing `Router`. It is built for
teams that want their own AMM deployment they fully control and can audit end to end — not a
hook or plugin bolted onto someone else's shared `PoolManager`. The whole thing is three core
contracts plus one oracle, depends only on OpenZeppelin, and targets Solidity 0.8.26.

## Why this over a fork or a hook

The edge here is that the safety-critical properties are enforced in the contracts and pinned
down by tests, not asserted in prose:

- **The k-invariant is enforced, not assumed.** `Pair._swap` checks the constant-product
  invariant on fee-adjusted balances (`balance*1000 - amountIn*3`) *after* any callback returns,
  reverting `KInvariantViolated` if the reserve product would drop. A stateful invariant run
  (`invariant_swapsNeverDecreaseK`) drives thousands of randomized swaps and asserts k never
  decreases.
- **First-deposit inflation is defeated.** The first mint permanently locks
  `MINIMUM_LIQUIDITY = 1000` shares (sent to `0xdEaD`), so the classic share-inflation /
  first-depositor donation attack cannot round later LPs to zero. This is exercised directly in
  the attack tests.
- **The TWAP oracle is the manipulation-resistant price source.** Prices are integrated over
  time in the pair's cumulative accumulators, so a single-block spot manipulation is weighted by
  only `(1 block / window)`. In `test_Twap_ResistsSingleBlockManipulation` a swap that crashes
  the spot price by well over 50% moves the reported TWAP by under 2%.
- **The protocol fee is bounded.** The optional protocol cut is minted via the `kLast`
  (sqrt-of-k growth) model and hard-capped at `MAX_PROTOCOL_FEE_BPS = 5000` — at most half of
  the 0.30% swap fee. When `feeTo` is unset, LPs keep 100% of the fee.
- **The fee math is mutation-tested.** Mutating the fee constants (e.g. the `997/1000` or the
  `*3` fee adjustment) breaks the swap and protocol-fee tests, confirming those assertions are
  load-bearing rather than decorative.

## Contracts

| Contract | Responsibility |
| --- | --- |
| `src/Pair.sol` | A single `x·y=k` pool that is itself the ERC20 LP token. `mint`/`burn` liquidity, `swap` with the k-invariant enforced after fees, `skim`/`sync`. Maintains the TWAP cumulatives and supports flash swaps and ERC-2612 permit. Reentrancy-guarded throughout. |
| `src/Factory.sol` | Deploys pairs deterministically (CREATE2 over sorted tokens), tracks `getPair`/`allPairs`, and owns the protocol-fee config (`feeTo`, `feeToSetter`, `protocolFeeBps`, capped at `MAX_PROTOCOL_FEE_BPS`). |
| `src/Router.sol` | User entry point: `addLiquidity`/`removeLiquidity`(`WithPermit`) and `swapExactTokensForTokens`/`swapTokensForExactTokens` with min/max amounts, path routing, and deadlines. Standard `getAmountOut`/`getAmountIn` pricing. |
| `src/TwapOracle.sol` | Optional consumer bound to one pair; turns the pair's cumulatives into a time-weighted average price and a `consult` quote. |

Interfaces live in `src/interfaces/`; test mocks live under `test/mocks/`.

### v2 features

Three additive features layered on the v1 core, with all v1 behavior unchanged.

- **Cumulative-price TWAP oracle.** `Pair` maintains `price0CumulativeLast` and
  `price1CumulativeLast` (UQ112.112 fixed-point). In `_update` (called by `mint`/`burn`/`swap`/
  `sync`), when time has elapsed and the pre-update reserves are non-zero, each accumulator
  advances by the elapsed-time-weighted price computed from the reserves that held *before* the
  update. `src/TwapOracle.sol` samples these to report a window average.
- **Flash swaps.** `Pair.swap(amount0Out, amount1Out, to, bytes data)` sits alongside the plain
  `swap(amount0Out, amount1Out, to)`. When `data` is non-empty the outputs are sent
  optimistically and `IFlashSwapCallee(to).flashSwapCall(...)` is invoked before the k-invariant
  is checked on post-callback balances; the borrower must return the borrowed amount plus the
  0.30% fee (or supply the other side). See `test/mocks/ExampleFlashSwapper.sol`.
- **ERC-2612 permit liquidity removal.** The LP token extends `ERC20Permit`, and
  `Router.removeLiquidityWithPermit(...)` lets an LP authorize the router with an off-chain
  signature, removing liquidity without a separate `approve`.

### Reading the TWAP for downstream pricing

The pair exposes everything a consumer needs: `getReserves()` returns the current reserves and
`blockTimestampLast`, and `price0CumulativeLast()` / `price1CumulativeLast()` return the
running accumulators. To price token0 in token1 over a window, a consumer records
`(price0CumulativeLast, blockTimestampLast)` at the window start and end, then computes:

```
avgPrice0 = (cumulative_end - cumulative_start) / (time_end - time_start)   // UQ112x112
amountOut = (avgPrice0 * amountIn) >> 112
```

`TwapOracle` implements exactly this: `update()` checkpoints a window once `period` seconds have
elapsed (extrapolating the cumulatives to the current block via `currentCumulativePrices()`), and
`consult(token, amountIn)` returns the TWAP-quoted output amount. Pick a `period` long enough
that manipulating the average over a full window is prohibitively expensive.

## Security & testing

`forge test` runs **40 tests, all green** across 8 suites — unit coverage for liquidity math and
the `MINIMUM_LIQUIDITY` lock, exact-in / exact-out swaps checked against `getAmountOut` /
`getAmountIn`, slippage and deadline reverts, two-hop routing, the exact protocol-fee split (on
and off), the share-inflation and reentrancy attacks, fee-on-transfer accounting, the TWAP
oracle (including single-block manipulation resistance), flash swaps, and permit removal.

The stateful invariant suite (`test/invariant/`) drives randomized add/remove/swap sequences and
asserts three invariants:

- `invariant_swapsNeverDecreaseK` — no swap ever decreased the reserve product k.
- `invariant_supplyEqualsSumOfBalances` — total LP supply always equals the sum of all holder
  balances (conservation of shares).
- `invariant_balancesCoverReserves` — the pair's token balances are never below its recorded
  reserves.

The fee math is additionally mutation-tested: mutating the swap-fee or protocol-fee constants
causes the corresponding tests to fail.

### Gas

Representative medians from `forge test --gas-report` (your numbers will vary with token and
call shape):

| Operation | Median gas |
| --- | --- |
| `Pair.swap` | ~59,000 |
| `Pair.mint` | ~126,000 |
| `Router.swapExactTokensForTokens` (single hop) | ~105,000 |

## Usage

Deploy the factory and router, then add liquidity and swap through the router:

```solidity
// Deploy
Factory factory = new Factory(feeToSetter);       // feeToSetter controls the protocol-fee switch
Router  router  = new Router(address(factory));

// Approve the router to pull your tokens
IERC20(tokenA).approve(address(router), type(uint256).max);
IERC20(tokenB).approve(address(router), type(uint256).max);

// Add liquidity (creates the pair on first call). Returns (amountA, amountB, liquidity).
router.addLiquidity(
    tokenA,
    tokenB,
    1_000e18,          // amountADesired
    1_000e18,          // amountBDesired
    0,                 // amountAMin (set for slippage protection)
    0,                 // amountBMin
    msg.sender,        // LP-token recipient
    block.timestamp    // deadline
);

// Swap an exact input for as much output as possible, subject to amountOutMin.
address[] memory path = new address[](2);
path[0] = tokenA;
path[1] = tokenB;
router.swapExactTokensForTokens(
    100e18,            // amountIn
    0,                 // amountOutMin (set for slippage protection)
    path,
    msg.sender,        // output recipient
    block.timestamp    // deadline
);
```

Fee-on-transfer tokens should interact with the `Pair` directly — the pair derives swap inputs
from realized balance deltas, whereas the router's swap helpers assume non-fee-on-transfer
tokens.

## License

MIT. This is a clean-room implementation released for others to deploy and build on. No mainnet
deployment, volume, or TVL is claimed; run your own tests and get an independent audit before
production use.
