#!/usr/bin/env python3
"""Perpl nest against Perpl's own public API (nightswatchhq/nuthatch#1148, Phase 4).

Two comparisons, both against endpoints that need no key:

  funding  FundingEventCompleted rows, keyed by fundingEventBlock, against
           GET /api/v1/market-data/{market}/funding/{from_ms}-{to_ms}, whose entries carry the same
           block as `feb`. Row for row: rate, funding price, payment, sum.
  fills    trades per hour and market (count, taker notional in micro-AUSD) against
           GET /api/v1/market-data/{market}/candles/3600/{from_ms}-{to_ms}, whose `n` is the number
           of trades (taker fills, each matching one or more maker fills) and `v` the sum of taker
           lot x entry price, in AUSD at 6 dp. Measured, not assumed: see the comment at the query.

Fails closed: a window the nest has not sealed or the API does not answer is a FAIL, never an
implicit match. Prints one line per comparison and exits non-zero on any mismatch.

usage: perpl-parity.py --nest http://127.0.0.1:8112 --hours 24 [--market 1] [--api https://app.perpl.xyz/api]
"""
import argparse, json, sys, time, urllib.parse, urllib.request

UA = {"user-agent": "nuthatch-perpl-parity"}


def get(url):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def nest_sql(nest, q):
    d = get(f"{nest}/sql?" + urllib.parse.urlencode({"q": q}))
    if d.get("truncated"):
        sys.exit(f"FAIL nest answer truncated for: {q[:80]}")
    return d["rows"], d.get("provenance", {})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--nest", required=True)
    ap.add_argument("--api", default="https://app.perpl.xyz/api")
    ap.add_argument("--hours", type=int, default=24)
    ap.add_argument("--market", type=int, default=None, help="perpetual_id; default: every market in the context")
    ap.add_argument("--from-ms", type=int, default=None, help="explicit window start (unix ms); with --to-ms overrides --hours")
    ap.add_argument("--to-ms", type=int, default=None, help="explicit window end (unix ms)")
    a = ap.parse_args()

    ctx = get(f"{a.api}/v1/pub/context")
    markets = {m["perpetual_id"]: m for m in ctx["markets"]}
    if a.market is not None:
        markets = {a.market: markets[a.market]}
    now_ms = a.to_ms if a.to_ms else int(time.time() * 1000)
    from_ms = a.from_ms if a.from_ms else now_ms - a.hours * 3600 * 1000
    # Compare only what the nest has sealed: hot rows can still move, sealed ones cannot.
    _, prov = nest_sql(a.nest, "select 1")
    sealed_through = prov.get("sealed_through") or 0
    print(f"nest sealed_through={sealed_through} as_of={prov.get('as_of')}; window {a.hours}h; markets {sorted(markets)}")

    failures = 0

    # ---- funding, row for row -------------------------------------------------------------------
    for pid, m in sorted(markets.items()):
        # The API answers a window that predates the market with its first event, outside the
        # window; only entries inside it are the claim being checked.
        api = [e for e in get(f"{a.api}/v1/market-data/{pid}/funding/{from_ms}-{now_ms}")["d"]
               if from_ms <= e["at"]["t"] < now_ms]
        api_by_block = {e["feb"]: e for e in api}
        rows, _ = nest_sql(a.nest, (
            'select cast("fundingEventBlock" as bigint) feb, cast("actualRatePct100k" as bigint) rate, '
            'cast("fundingPricePNS" as bigint) idx, cast("fundingPaymentPNS" as bigint) ppl, '
            'cast("fundingSumPNS" as bigint) sum from perpl__funding_event_completed '
            f'where cast("perpId" as bigint) = {pid} and block_number <= {sealed_through} '
            f'and block_timestamp * 1000 >= {from_ms} and block_timestamp * 1000 < {now_ms} order by feb'))
        nest_by_block = {r["feb"]: r for r in rows}
        common = sorted(set(api_by_block) & set(nest_by_block))
        only_api = sorted(set(api_by_block) - set(nest_by_block))
        only_nest = sorted(set(nest_by_block) - set(api_by_block))
        bad = 0
        for b in common:
            x, y = api_by_block[b], nest_by_block[b]
            # The API's rate is in millionths; the chain's is parts per hundred thousand.
            if (x["rate"], x["idx"], x["ppl"], x["sum"]) != (y["rate"] * 10, y["idx"], y["ppl"], y["sum"]):
                bad += 1
                print(f"  funding {m['name']} block {b}: api rate={x['rate']} idx={x['idx']} ppl={x['ppl']} sum={x['sum']} | nest rate={y['rate']} idx={y['idx']} ppl={y['ppl']} sum={y['sum']}")
        if not api and not rows:
            status = "n/a"  # no funding events in this window on either side
        else:
            status = "ok" if not bad and not only_api and not only_nest and common else "FAIL"
        if status == "FAIL":
            failures += 1
        print(f"funding {m['name']:<5} {status}: {len(common)} events compared, {bad} differ, {len(only_api)} only in api, {len(only_nest)} only in nest")

    # ---- fills per hour against candles ----------------------------------------------------------
    for pid, m in sorted(markets.items()):
        candles = get(f"{a.api}/v1/market-data/{pid}/candles/3600/{from_ms}-{now_ms}")["d"]
        # The candle's `n` is trades and its `v` is the taker's lot times the volume-weighted maker
        # price **rounded up** to the market's price unit, summed over trades. Measured, not assumed,
        # on three BTC hours (2026-03-01 20:00 and 22:00, 2026-03-20 19:00 UTC, 311 trades): that
        # formula reproduces the API's `v` to the unit in all three, while the exact maker-side
        # notional (sum of price x lot) sits a few units under, the taker's `entryPricePNS` matches
        # only when every trade opened a fresh position, and round-to-nearest or round-down match
        # none. A trade is one `TakerOrderFilled` (V1 or V2) preceded in its transaction by the
        # `MakerOrderFilled` rows it matched; the taker row carries no perpId, so its market and its
        # price come from those maker rows - the ones between the previous taker fill in the
        # transaction and itself. Scaled to micro-AUSD with the market's decimals; every market has
        # price + lot decimals of six or fewer, so the scale factor is an integer.
        rows, _ = nest_sql(a.nest, (
            'with tk as ('
            '  select tx_hash, log_index as tl, block_number, block_timestamp, cast("lotLNS" as hugeint) as lot '
            '  from perpl__taker_order_filled_v2 '
            '  union all '
            '  select tx_hash, log_index, block_number, block_timestamp, cast("lotLNS" as hugeint) '
            '  from perpl__taker_order_filled), '
            'mk as ('
            '  select tx_hash, log_index as ml, cast("pricePNS" as hugeint) as px, cast("lotLNS" as hugeint) as lot '
            f'  from perpl__maker_order_filled_v2 where cast("perpId" as integer) = {pid} '
            '  union all '
            '  select tx_hash, log_index, cast("pricePNS" as hugeint), cast("lotLNS" as hugeint) '
            f'  from perpl__maker_order_filled where cast("perpId" as integer) = {pid}), '
            'trades as ('
            '  select t.tx_hash, t.tl, t.block_timestamp, t.lot as tlot, '
            '         sum(m.px * m.lot) as pxl, sum(m.lot) as mlot '
            f'  from tk t join mk m on m.tx_hash = t.tx_hash and m.ml < t.tl '
            '    and m.ml > coalesce((select max(x.tl) from tk x where x.tx_hash = t.tx_hash and x.tl < t.tl), -1) '
            f'  where t.block_number <= {sealed_through} '
            f'    and t.block_timestamp * 1000 >= {from_ms} and t.block_timestamp * 1000 < {now_ms} '
            '  group by 1, 2, 3, 4), '
            'scale as (select cast(power(10, 6 - price_decimals - lot_decimals) as hugeint) as f '
            f'          from perpl_markets where perp_id = {pid}) '
            'select (block_timestamp // 3600) * 3600 * 1000 as t, count(*) as n, '
            '       cast(sum(tlot * cast(ceil(pxl * 1.0 / mlot) as hugeint)) * (select f from scale) as bigint) as v '
            'from trades group by 1 order by 1'))
        nest_by_hour = {int(r["t"]): r for r in rows}
        bad = compared = 0
        for c in candles:
            t = c["t"]
            if t + 3600 * 1000 > now_ms:
                continue  # the open hour is not final on either side
            y = nest_by_hour.get(t)
            if y is None:
                if c["n"]:
                    bad += 1
                    print(f"  fills {m['name']} hour {t}: api n={c['n']} v={c['v']} | nest has no sealed rows")
                continue
            compared += 1
            if int(c["n"]) != int(y["n"]) or int(c["v"]) != int(y["v"]):
                bad += 1
                print(f"  fills {m['name']} hour {t}: api n={c['n']} v={c['v']} | nest n={y['n']} v={y['v']}")
        if not compared and not bad and not any(int(c["n"]) for c in candles):
            status = "n/a"  # no fills in this window on either side
        else:
            status = "ok" if compared and not bad else "FAIL"
        if status == "FAIL":
            failures += 1
        print(f"fills   {m['name']:<5} {status}: {compared} hours compared, {bad} differ")

    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
