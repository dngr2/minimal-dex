# Token lists

Per-chain lists of ERC-20 tokens to list on the DEX via `PairLister`. USDC is the
dollar quote; WETH the native quote. **Stablecoins other than USDC are excluded.**

Only tokens that exist as ERC-20s on the target chain can be listed — native L1
coins (BTC, SOL, XRP, ADA, DOGE, …) are not ERC-20s and would require a wrapped/
bridged representation (WBTC, etc.), which is a trusted bridge asset. So each list
is "top ERC-20 tokens by market cap on <chain>, minus stablecoins".

`<chain>.json` schema:
{
  "chainId": 1,
  "quoteUSDC": "0x...",   // USDC on this chain
  "quoteWETH": "0x...",   // WETH on this chain (or 0x0 to disable the WETH leg)
  "tokens": ["0x...", "0x..."]   // addresses to list against the quotes
}

To list: deploy Factory + PairLister(factory, quoteUSDC, quoteWETH), call
`listHub()` once, then `listTokens(tokens)` (batched if the list is large).
Each created pair still needs liquidity before it is tradable.
