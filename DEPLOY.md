# Deployment

`script/Deploy.s.sol` deploys the `Factory` and then the `Router` (which takes the
factory address in its constructor). Both addresses are printed via `console2.log`.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed (`forge`).
- A funded **dedicated deployer key** — use a fresh key created only for deployments,
  never a personal wallet holding real funds.
- An RPC URL for the target chain.

## Environment variables

| Variable         | Required | Description                                                                 |
| ---------------- | -------- | --------------------------------------------------------------------------- |
| `FEE_TO_SETTER`  | No       | Address allowed to set `feeTo` / protocol fee. Defaults to the deployer.    |

Set them in your shell (or a `.env` file, which is gitignored):

```sh
export FEE_TO_SETTER=0xYourFeeToSetterAddress
```

## Deploy (testnet first)

Deploy to a **testnet first** and fund the deployer from a free faucet (e.g. a
Sepolia faucet) before ever touching mainnet:

```sh
forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$RPC_URL" \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --broadcast
```

The run logs the deployed `Factory` and `Router` addresses.

## After deploy

- **Pairs are created via `factory.createPair(tokenA, tokenB)`** — the deploy does not
  create any pairs. Call `createPair` for each token pair you want to support, then add
  liquidity through the Router.
- **Verify the deployed addresses on the block explorer** before interacting with them,
  and confirm the `Factory`/`Router` wiring matches the addresses from the deploy log.

## Note

This code is **unaudited**. Deploy at your own risk, review the source, and do not use
it with funds you cannot afford to lose.
