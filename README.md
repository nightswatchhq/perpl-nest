# Perpl nest

A self-hosted SQL index of **[Perpl](https://app.perpl.xyz)**, the perpetual futures exchange on
Monad, built with [Nuthatch](https://github.com/nightswatchhq/nuthatch). One binary, one
directory, and every fill, order, funding event, liquidation and market definition the exchange
contract has ever emitted becomes a table you can query with SQL, on your own machine, with no
account and nothing phoning home.

Perpl's exchange contract `0x34B6552d57a35a1D042CcAe1951BD1C370112a6F` emits about seventy percent
of all logs on Monad. Until this nest, the only way to see its history was Perpl's own API, which
serves fills, positions and account history to the account that owns them. This nest gives anyone
the whole venue, verifiable against the chain, with Perpl's public API as the cross-check rather than
the only source.

**Status, 2026-09-04: building.** Every event the contract emits decodes, and the first backfill
from Perpl's deployment is running. Parity against Perpl's public API is scripted and not yet run,
so nothing below should be read as verified until the tracking issue says so:
[nightswatchhq/nuthatch#1148](https://github.com/nightswatchhq/nuthatch/issues/1148). The label
becomes *available* when the backfill has completed and parity has passed.

---

## What is in it

The exchange contract's ABI declares 202 events. All of them are indexed, as one table each named
`perpl__<event_in_snake_case>`, with every event parameter as a column plus `block_number`,
`block_hash`, `block_timestamp`, `tx_hash`, `log_index` and `address`. The ones people ask about:

| family | tables | what they carry |
|---|---|---|
| orders | `perpl__order_request_v2`, `perpl__order_placed`, `perpl__order_changed`, `perpl__order_cancelled`, `perpl__immediate_or_cancel_executed`, `perpl__order_batch_completed` | the order flow, about 85% of the venue's events |
| fills | `perpl__maker_order_filled_v2`, `perpl__taker_order_filled_v2`, and their V1 shapes `perpl__maker_order_filled`, `perpl__taker_order_filled` | one maker and one taker row per match, with price, size, fees, balances; V1 has no builder fields |
| positions | `perpl__position_opened_v2`, `perpl__position_increased_v2`, `perpl__position_decreased`, `perpl__position_closed`, `perpl__position_liquidated`, `perpl__position_deleveraged_v2`, `perpl__position_unwound_v2` | the position lifecycle, with realised PnL and funding at close |
| funding | `perpl__funding_event_completed`, `perpl__mark_updated`, `perpl__link_price_updated` | hourly funding per market, mark and index prices |
| accounts | `perpl__account_created`, `perpl__collateral_deposit`, `perpl__collateral_withdrawal`, `perpl__account_fee_tier_set` | who exists, what they moved in and out |
| markets | `perpl__contract_added_v2`, `perpl__contract_added`, `perpl__contract_paused`, `perpl__contract_removed` | market definitions, including each market's price and size decimals |
| protocol | `perpl__exchange_initialized`, `perpl__fee_schedule_set`, `perpl__insurance_payment_for_settlement`, the `buy_to_liquidate_*` and `unwind_*` families | exchange configuration, insurance fund, forced closes |

Older markets were defined before the `V2` events existed, which is why both `contract_added` and
`contract_added_v2` are indexed and unioned in the views. The same is true of fills: the venue's
first fills, from block 55,107,491 (2026-02-13), are `MakerOrderFilled` rows, and `perpl_fills`
unions both shapes with NULL builder fields for V1 - 126,765 V1 fills had sealed before the V2
table held a single row. Expect the same for `position_opened` and `order_request` early in the
history.

On top of the raw tables, `views/10-perpl.sql` defines five views in the units people use:

| view | one row per | columns |
|---|---|---|
| `perpl_markets` | market | `perp_id`, `name`, `symbol`, `price_decimals`, `lot_decimals`, `defined_at_block` |
| `perpl_fills` | maker-side fill (one per match) | `block_number`, `block_timestamp`, `tx_hash`, `log_index`, `perp_id`, `market`, `maker_account_id`, `order_id`, `price`, `size`, `notional_usd`, `maker_fee_ausd`, `builder_fee_ausd`, `builder_id` |
| `perpl_volume_daily` | market and UTC day | `day`, `perp_id`, `market`, `fills`, `size`, `notional_usd`, `maker_fees_ausd` |
| `perpl_funding` | completed funding event | `block_number`, `block_timestamp`, `perp_id`, `market`, `funding_block`, `specified_rate_pct`, `rate_pct`, `funding_price`, `overwrite` |
| `perpl_liquidations` | liquidation | `block_number`, `block_timestamp`, `tx_hash`, `log_index`, `perp_id`, `market`, `account_id`, `position_type`, `mark_price`, `liquidation_price`, `size_liquidated`, `position_size`, `pnl_ausd`, `funding_ausd`, `deposit_ausd`, `on_order_book` |

Volume is counted from the maker side because `TakerOrderFilledV2` carries no market or account of
its own, and every match has exactly one maker. Open interest and per-account PnL are deliberately
absent: they need the position state machine that Perpl's SDK replays, and they belong in a
[Nuthatch incremental entity](https://github.com/nightswatchhq/nuthatch/blob/main/docs/rfcs/0041-authored-incremental-entities.md)
once the fills have proved parity.

---

## Running it

You need the Nuthatch binary (3.3.1 or later, which has Monad built in) and a Monad RPC endpoint.

```sh
curl -fsSL https://nuthatch-indexer.com/install.sh | sh
nuthatch init --from https://github.com/nightswatchhq/perpl-nest
nuthatch dev --dir perpl-nest --rpc https://your-monad-endpoint --window 320 --seal-direct
```

`dev` backfills from `start_block = 54773010` (Perpl's first log, 2026-02-11) to the tip, then
follows the tip, and serves the HTTP API on `127.0.0.1:8288` from the first second. The first full
backfill covers about 47 million blocks of a contract that carries about 77 logs a block, so it is
a long run; on a keyed endpoint at four concurrent windows it indexes about 1,250 events a second
and takes on the order of two days. You can query the API throughout; the `provenance` block of
every answer tells you how far it has got.

**Endpoints.** Monad's public endpoints serve logs from block 1, so a backfill from deployment
works on them, but `rpc.monad.xyz` caps `eth_getLogs` at 100 blocks and 50 requests a second,
which makes this contract a matter of days at best. Bring a keyed endpoint. `--rpc` is the whole
pool for the run, nothing public is appended after it, and the endpoint never goes into
`nuthatch.toml`, which is pinned into the nest's content address. Measure before you trust it:

```sh
nuthatch doctor --rpc https://your-monad-endpoint --address 0x34B6552d57a35a1D042CcAe1951BD1C370112a6F
```

It prints the largest safe `--window`; 320 is what a keyed Alchemy endpoint recommended. No Monad
endpoint we have found keeps historic state, so `init` cannot detect the deployment block and
pinned `eth_call`s are not used here; `start_block` is set by hand in the config.

**Resources.** During the backfill the process sits around 400 MB resident and writes sealed
Parquet segments under `perpl-nest/segments/`; the hot tip lives in `perpl-nest/nuthatch.redb`.
Budget a few GB of disk for the full history. Nuthatch's per-cursor budget is 2 GB of RAM.

**Restarts and upgrades.** `dev` resumes from its checkpoint; sealed segments are never rewritten.
Upgrading Nuthatch is a binary swap and a restart, no migration. If Perpl upgrades its
implementation (it has at least once, and two of Monad's busiest contracts were upgraded within a
day of this being written) the nest keeps running because it is keyed to the proxy address; what
can change is the ABI, and the signal is events that stop decoding. Nuthatch logs a decode error per
undecodable log; watch for those after an upgrade, then refresh `abis/` from the SDK.

### Hosting it as a service

The unit that runs the reference instance, with the endpoint in an environment file rather than in
the unit or the config:

```ini
# /etc/systemd/system/perpl-nest.service
[Unit]
Description=nuthatch perpl-nest (Perpl exchange on Monad)
After=network-online.target
Wants=network-online.target

[Service]
User=nuthatch
WorkingDirectory=/opt/nuthatch/perpl-nest
Environment=RUST_LOG=info,dbsp=warn
Environment=NUTHATCH_HOT_STORE_CACHE_BYTES=268435456
EnvironmentFile=/etc/nuthatch/perpl-nest.env       # NEST_RPC=https://your-monad-endpoint  (mode 600)
ExecStart=/usr/local/bin/nuthatch dev --dir /opt/nuthatch/perpl-nest --listen 127.0.0.1:8112 --no-admin --seal-direct --concurrency 4 --window 320 --rpc ${NEST_RPC}
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
```

Put a reverse proxy with authentication in front of the port if it is to be reachable from outside;
`/sql` is read-only and guarded (row cap, timeout, a query allowlist you can enable), but it is
still your endpoint's traffic. `GET /ready` is the readiness probe; `GET /metrics` is Prometheus
text, and `nuthatch_tip_lag_blocks` is the number to alert on, in seconds rather than blocks, since
Monad produces a block every 300 ms.

---

## Querying it

Three ways to ask, all the same SQL, all read-only. The engine is DuckDB over the sealed Parquet
segments plus the hot tip, so anything DuckDB can express works: window functions, `QUALIFY`,
`date_trunc`, `to_timestamp`, `HUGEINT` arithmetic.

**Over HTTP**, the way a dashboard or a script would:

```sh
curl -s --get http://127.0.0.1:8288/sql \
  --data-urlencode "q=SELECT day, market, fills, round(notional_usd) AS usd FROM perpl_volume_daily ORDER BY day DESC, usd DESC LIMIT 20"
```

Every answer carries a `provenance` block: `as_of` (the last block the nest holds), `sealed_through`
(the last block in immutable Parquet), the registry hash, and `source` (`hot`, `sealed` or
`hot+sealed`). Answers are capped at **50,000 rows** and say so with `truncated: true`; page by
block number rather than reading a round number as the total.

**From the CLI**, against a running `dev` or straight from the directory:

```sh
nuthatch sql --dir perpl-nest "SELECT market, count(*) FROM perpl_fills GROUP BY 1 ORDER BY 2 DESC"
```

**From a coding agent**, over MCP, against a running `dev`:

```sh
claude mcp add perpl -- nuthatch mcp --url http://127.0.0.1:8288
```

exposes the schema, the views and `/sql` as tools, and `llms.txt` plus `.claude/skills/nuthatch/` in
this repository tell an agent the table names and the units so it does not guess them.

`GET /tables` lists every table with its columns, `GET /schema` documents them, and
`GET /queries` lists the views.

### Queries worth having

Daily volume and fees by market:

```sql
SELECT day, market, fills, round(notional_usd) AS notional_usd, round(maker_fees_ausd, 2) AS maker_fees
FROM perpl_volume_daily
ORDER BY day DESC, notional_usd DESC;
```

The largest fills of the last day:

```sql
SELECT to_timestamp(block_timestamp) AS at, market, price, size, round(notional_usd) AS usd, tx_hash
FROM perpl_fills
WHERE block_timestamp > epoch(now()) - 86400
ORDER BY notional_usd DESC
LIMIT 25;
```

Funding history for one market, newest first:

```sql
SELECT to_timestamp(block_timestamp) AS at, rate_pct, specified_rate_pct, funding_price
FROM perpl_funding
WHERE market = 'BTC'
ORDER BY block_number DESC
LIMIT 48;
```

Liquidations by day, count and total size, with the worst realised loss:

```sql
SELECT CAST(to_timestamp(block_timestamp) AS DATE) AS day, market,
       count(*) AS liquidations, sum(size_liquidated) AS size, min(pnl_ausd) AS worst_pnl_ausd
FROM perpl_liquidations
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;
```

Hourly VWAP from fills, which is what the parity script compares to Perpl's candles:

```sql
SELECT date_trunc('hour', to_timestamp(block_timestamp)) AS hour, market,
       count(*) AS fills, sum(notional_usd) / sum(size) AS vwap, sum(notional_usd) AS notional_usd
FROM perpl_fills
GROUP BY 1, 2
ORDER BY 1 DESC, 2;
```

New accounts per week and net collateral flow:

```sql
WITH a AS (
  SELECT date_trunc('week', to_timestamp(block_timestamp)) AS week, count(*) AS accounts
  FROM perpl__account_created GROUP BY 1),
d AS (
  SELECT date_trunc('week', to_timestamp(block_timestamp)) AS week,
         sum(CAST("amountCNS" AS HUGEINT)) / 1e6 AS deposited FROM perpl__collateral_deposit GROUP BY 1),
w AS (
  SELECT date_trunc('week', to_timestamp(block_timestamp)) AS week,
         sum(CAST("amountCNS" AS HUGEINT)) / 1e6 AS withdrawn FROM perpl__collateral_withdrawal GROUP BY 1)
SELECT a.week, a.accounts, d.deposited, w.withdrawn, d.deposited - w.withdrawn AS net_ausd
FROM a LEFT JOIN d USING (week) LEFT JOIN w USING (week)
ORDER BY 1 DESC;
```

A raw event, when the views do not cover it. Column names are the ABI's parameter names, so they are
quoted; integers arrive as decimal text and are cast:

```sql
SELECT block_number, CAST("perpId" AS HUGEINT) AS perp_id, CAST("accountId" AS HUGEINT) AS account,
       CAST("deltaPnlCNS" AS HUGEINT) / 1e6 AS pnl_ausd, CAST("fundingCNS" AS HUGEINT) / 1e6 AS funding_ausd
FROM perpl__position_closed
ORDER BY block_number DESC
LIMIT 10;
```

### Units

Every on-chain amount is a fixed-point integer, and the scale is in the column's suffix:

| suffix | meaning | scale |
|---|---|---|
| `CNS` | collateral, AUSD | 10^6 |
| `PNS` | price | 10^`price_decimals` of the market, from `perpl_markets` |
| `LNS` | lot, i.e. size | 10^`lot_decimals` of the market |
| `Hdths` | hundredths | 10^2 |
| `Per100K`, `Pct100k` | parts per hundred thousand of one: a fraction scaled by 10^5, so `-50` is -0.05% | 10^5 (divide by 1,000 for percent) |

The markets today: BTC price 1 / size 5 decimals, ETH 2 / 3, SOL 3 / 3, MON 6 / 0, HYPE 4 / 2,
ZEC 2 / 4, LIT 5 / 1, PUMP 6 / 0, cross-checked against Perpl's public context. The views apply
these; the raw tables do not. Perpl's API reports rates in millionths, ten times the on-chain
integer; parity confirmed it. The reference is `crates/sdk/src/num.rs` and `state/perpetual.rs` in
Perpl's SDK.

---

## Where the ABI comes from, and why that matters

The exchange is an EIP-1967 proxy over an unverified implementation, Perpl publishes no ABI beside
its API docs, and the six busiest event signatures are in no public signature database, all with
zero indexed fields and up to nineteen words of packed data. Nuthatch decodes deterministically
from an ABI and will not guess a layout. The ABI in `abis/` is `crates/sdk/abi/dex/Exchange.json`
from [PerplFoundation/dex-sdk](https://github.com/PerplFoundation/dex-sdk) (MIT), commit
`65e0e897da`, revision `rc_v1.1.7-178-g2273779`: 368 ABI items, 202 events. Every event signature
the live contract emits hashes to one of them, and the first run decoded every observed signature
with nothing skipped. If Perpl verifies the implementation on Sourcify or MonadScan, `init` from the
address works keyless and this file becomes a convenience.

## Parity

`scripts/perpl-parity.py` compares the nest with Perpl's public API over the blocks the nest has
sealed: funding events row for row by funding block against
`GET /api/v1/market-data/{market}/funding/{from}-{to}`, and maker-side fills per hour and market
against the `n` and `v` of `GET /api/v1/market-data/{market}/candles/3600/{from}-{to}`. It fails
closed. Results go on the tracking issue as they arrive.

```sh
python3 scripts/perpl-parity.py --nest http://127.0.0.1:8288 --hours 24
```

## Files

`nuthatch.toml` is the nest; `abis/` the vendored ABI; `views/` the derivations; `scripts/` the
parity check; `schema.json`, `semantic.toml`, `llms.txt` and `.claude/skills/` are generated by
`nuthatch init` and describe the tables to people and to coding agents. Nothing here carries an
endpoint or a key. The vendored ABI is MIT, from Perpl's SDK.
