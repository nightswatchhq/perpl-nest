# Perpl nest

An installable Nuthatch nest for **Perpl**, the perpetual futures exchange on Monad. Perpl's
exchange contract emits about seventy percent of Monad's logs, and until this nest nothing indexed
it publicly: the only source of its history was Perpl's own API.

**Status, 2026-09-04: building.** The nest decodes every event the contract emits and is
backfilling 47 million blocks from Perpl's first log on 2026-02-11; parity against Perpl's public
API has not yet been run, and nothing here should be read as verified until it has. The tracking
issue is [nightswatchhq/nuthatch#1148](https://github.com/nightswatchhq/nuthatch/issues/1148) and
it carries every measurement as it lands.

```sh
nuthatch init --from https://github.com/nightswatchhq/perpl-nest
nuthatch dev --dir perpl-nest --rpc https://your-monad-endpoint --window 320 --seal-direct
nuthatch sql --dir perpl-nest "SELECT * FROM perpl_volume_daily ORDER BY day DESC, notional_usd DESC"
```

Monad is a built-in chain since Nuthatch 3.3.0, so `--chain monad` needs no configuration. The
shipped public endpoints serve Monad's logs from block 1, so a backfill from deployment works on
them, but slowly: `rpc.monad.xyz` caps `eth_getLogs` at 100 blocks and 50 requests a second, and
this contract carries about 77 logs a block. A keyed endpoint answers 640 blocks address-filtered
(`nuthatch doctor --rpc <url> --address 0x34B6552d57a35a1D042CcAe1951BD1C370112a6F`), and
`--window 320` is what that measurement recommends. No Monad endpoint we have found keeps
historic state, so `init` cannot detect the deployment block; `start_block = 54773010` is set by
hand, and pinned calls are not used.

## Where the ABI comes from, and why that matters

The exchange is an EIP-1967 proxy over an unverified implementation, Perpl publishes no ABI, and
its six busiest event signatures are in no public signature database, all with zero indexed fields
and up to nineteen words of packed data. Nuthatch decodes deterministically from an ABI and will not
guess a layout. The ABI in `abis/` is `crates/sdk/abi/dex/Exchange.json` from
[PerplFoundation/dex-sdk](https://github.com/PerplFoundation/dex-sdk) (MIT), commit `65e0e897da`,
revision `rc_v1.1.7-178-g2273779`: 368 ABI items, 202 events. Every event signature the live
contract emits hashes to one of them, six of six on the busiest, and a first run decoded every
observed signature with nothing skipped. If Perpl verifies the implementation on Sourcify or
MonadScan, `init` from the address works keyless and this file becomes a convenience.

Two of Monad's busiest contracts were upgraded within one day of this being written; Perpl's
proxy has moved at least once (the `V2` events beside their predecessors say so). A nest keyed to
the proxy survives an upgrade; its ABI does not necessarily. A decode that stops matching is the
signal, and this README will say what to do about it once that has happened once.

## Query surface

All 202 events are indexed as tables named `perpl__<event>`; the views in `views/10-perpl.sql`
put the ones people ask for into real units.

- **`perpl_markets`** - one row per market with its price and size decimals, from the on-chain
  `ContractAddedV2` / `ContractAdded` definitions. Cross-checked against Perpl's public context:
  BTC 1 / 5, ETH 2 / 3, SOL 3 / 3, MON 6 / 0, HYPE 4 / 2, ZEC 2 / 4, LIT 5 / 1, PUMP 6 / 0.
- **`perpl_fills`** - maker-side fills in price, size and AUSD notional, with maker and builder
  fees. Volume is counted from the maker side because `TakerOrderFilledV2` carries no market or
  account and every match has exactly one maker.
- **`perpl_volume_daily`** - fills, size and notional by market and UTC day.
- **`perpl_funding`** - one row per completed funding event: applied and specified rate in
  percent, funding price. Keyed by the same funding block Perpl's API reports.
- **`perpl_liquidations`** - mark and liquidation price, size liquidated out of the position, PnL,
  funding and deposit in AUSD.

Deliberately absent: open interest and per-account PnL. They need the position state machine the
SDK replays, and they belong in an authored incremental entity once the fills have proved parity.

## Scales

Every amount is a fixed-point integer. `CNS` is collateral, AUSD at 6 decimals; `PNS` price and
`LNS` size use the market's own decimals from `perpl_markets`; fee rates and funding rates are
scaled by 10^5; `Hdths` is hundredths and `Per100K` parts per hundred thousand. The reference is
`crates/sdk/src/num.rs` and `state/perpetual.rs` in the SDK.

## Parity

`scripts/perpl-parity.py` compares the nest with Perpl's public API over the blocks the nest has
sealed: funding events row for row by funding block against
`GET /api/v1/market-data/{market}/funding/{from}-{to}`, and maker-side fills per hour and market
against the `n` and `v` of `GET /api/v1/market-data/{market}/candles/3600/{from}-{to}`. It fails
closed: a truncated answer, an hour the API has fills for and the nest has no sealed rows for, or a
funding block on one side only, is a failure. Results go on the tracking issue as they arrive.

## Files

`nuthatch.toml` is the nest; `abis/` the vendored ABI; `views/` the derivations; `scripts/` the
parity check; `schema.json`, `semantic.toml`, `llms.txt` and `.claude/skills/` are generated by
`nuthatch init` and describe the tables to people and to coding agents. Nothing here carries an
endpoint or a key: the config is pinned into the nest's content address, and `--rpc` is the whole
pool for a run.
