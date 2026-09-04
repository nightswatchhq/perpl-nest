-- Perpl on Monad (nightswatchhq/nuthatch#1148): the venue's data in the units people use.
--
-- Every on-chain amount is a fixed-point integer with a per-market or per-exchange scale. The scales
-- are on chain too: `priceDecimals` and `lotDecimals` arrive with each market in `ContractAddedV2`
-- (`ContractAdded` for the earliest), and the collateral token AUSD has 6 decimals
-- (`ExchangeInitialized.collateralDecimals`, and the public context at app.perpl.xyz/api/v1/pub/context
-- agrees: BTC price 1 / size 5, ETH 2 / 3, SOL 3 / 3, MON 6 / 0, HYPE 4 / 2, ZEC 2 / 4, LIT 5 / 1,
-- PUMP 6 / 0, checked 2026-09-04). Fee rates are scaled by 10^5, funding rates by 10^5 as
-- "percent per 100k" (dex-sdk crates/sdk/src/num.rs and state/perpetual.rs at commit 65e0e897da).
--
-- Suffix key, from the ABI: CNS = collateral (AUSD, 6 dp), PNS = price (market decimals),
-- LNS = lot/size (market decimals), Hdths = hundredths, Per100K = parts per 100,000.

-- One row per market, the latest definition winning. Both event versions are unioned so the earliest
-- markets, defined before the V2 event existed, are not missing from every join below.
CREATE VIEW perpl_markets AS
WITH defs AS (
  SELECT CAST("perpId" AS HUGEINT) AS perp_id, name, symbol,
         CAST("priceDecimals" AS INTEGER) AS price_decimals,
         CAST("lotDecimals" AS INTEGER) AS lot_decimals,
         block_number, log_index
  FROM perpl__contract_added_v2
  UNION ALL
  SELECT CAST("perpId" AS HUGEINT), name, symbol,
         CAST("priceDecimals" AS INTEGER), CAST("lotDecimals" AS INTEGER),
         block_number, log_index
  FROM perpl__contract_added
)
SELECT perp_id, name, symbol, price_decimals, lot_decimals, block_number AS defined_at_block
FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY perp_id ORDER BY block_number DESC, log_index DESC) AS rn
      FROM defs)
WHERE rn = 1;

-- Maker-side fills, one per match, in real units. The taker side (`TakerOrderFilledV2`) carries no
-- perpId or accountId and is tied to its order only by transaction context, so volume is counted
-- from the maker side, which is complete and market-labelled: every match has exactly one maker.
CREATE VIEW perpl_fills AS
SELECT f.block_number, f.block_timestamp, f.tx_hash, f.log_index,
       m.perp_id, m.name AS market,
       CAST(f."accountId" AS HUGEINT) AS maker_account_id,
       CAST(f."orderId" AS HUGEINT) AS order_id,
       CAST(f."pricePNS" AS HUGEINT) / POWER(10, m.price_decimals) AS price,
       CAST(f."lotLNS" AS HUGEINT) / POWER(10, m.lot_decimals) AS size,
       (CAST(f."pricePNS" AS HUGEINT) / POWER(10, m.price_decimals))
         * (CAST(f."lotLNS" AS HUGEINT) / POWER(10, m.lot_decimals)) AS notional_usd,
       CAST(f."feeCNS" AS HUGEINT) / 1e6 AS maker_fee_ausd,
       CAST(f."builderFeeCNS" AS HUGEINT) / 1e6 AS builder_fee_ausd,
       CAST(f."builderId" AS HUGEINT) AS builder_id
FROM perpl__maker_order_filled_v2 f
JOIN perpl_markets m ON m.perp_id = CAST(f."perpId" AS HUGEINT);

-- Volume by market and UTC day, in AUSD notional, from maker-side fills.
CREATE VIEW perpl_volume_daily AS
SELECT CAST(to_timestamp(block_timestamp) AS DATE) AS day, perp_id, market,
       COUNT(*) AS fills, SUM(size) AS size, SUM(notional_usd) AS notional_usd,
       SUM(maker_fee_ausd) AS maker_fees_ausd
FROM perpl_fills
GROUP BY 1, 2, 3;

-- Funding, one row per completed funding event per market. `actualRatePct100k` is the rate applied,
-- in percent scaled by 10^5; the specified rate is what the oracle asked for before clamping.
CREATE VIEW perpl_funding AS
SELECT e.block_number, e.block_timestamp, m.perp_id, m.name AS market,
       CAST(e."fundingEventBlock" AS HUGEINT) AS funding_block,
       CAST(e."specifiedRatePct100k" AS HUGEINT) / 1e5 AS specified_rate_pct,
       CAST(e."actualRatePct100k" AS HUGEINT) / 1e5 AS rate_pct,
       CAST(e."fundingPricePNS" AS HUGEINT) / POWER(10, m.price_decimals) AS funding_price,
       e."allowOverwrite" AS overwrite
FROM perpl__funding_event_completed e
JOIN perpl_markets m ON m.perp_id = CAST(e."perpId" AS HUGEINT);

-- Liquidations in real units. `deltaPnlCNS` and `fundingCNS` are signed; `liqLotLNS` is the size
-- liquidated out of `posLotLNS`.
CREATE VIEW perpl_liquidations AS
SELECT l.block_number, l.block_timestamp, l.tx_hash, l.log_index,
       m.perp_id, m.name AS market,
       CAST(l."posAccountId" AS HUGEINT) AS account_id,
       CAST(l."positionType" AS INTEGER) AS position_type,
       CAST(l."markPricePNS" AS HUGEINT) / POWER(10, m.price_decimals) AS mark_price,
       CAST(l."liqPricePNS" AS HUGEINT) / POWER(10, m.price_decimals) AS liquidation_price,
       CAST(l."liqLotLNS" AS HUGEINT) / POWER(10, m.lot_decimals) AS size_liquidated,
       CAST(l."posLotLNS" AS HUGEINT) / POWER(10, m.lot_decimals) AS position_size,
       CAST(l."deltaPnlCNS" AS HUGEINT) / 1e6 AS pnl_ausd,
       CAST(l."fundingCNS" AS HUGEINT) / 1e6 AS funding_ausd,
       CAST(l."posDepositCNS" AS HUGEINT) / 1e6 AS deposit_ausd,
       l."onOrderBook" AS on_order_book
FROM perpl__position_liquidated l
JOIN perpl_markets m ON m.perp_id = CAST(l."perpId" AS HUGEINT);

-- Not derivable from events alone, and deliberately absent: open interest and per-account PnL
-- need the position state machine the SDK's `state/perpetual.rs` replays; they are a candidate for
-- an authored incremental entity (RFC-0041) once the fills and positions here have proved parity.
