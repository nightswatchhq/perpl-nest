#!/usr/bin/env python3
"""Perpl nest against Perpl's own public API (nightswatchhq/nuthatch#1148, Phase 4).

Two comparisons, both against endpoints that need no key:

  funding  FundingEventCompleted rows, keyed by fundingEventBlock, against
           GET /api/v1/market-data/{market}/funding/{from_ms}-{to_ms}, whose entries carry the same
           block as `feb`. Row for row: rate, funding price, payment, sum.
  fills    maker-side fills per hour and market (count, AUSD notional) against
           GET /api/v1/market-data/{market}/candles/3600/{from_ms}-{to_ms}, whose `n` is the number
           of fills in the hour and `v` the notional in AUSD (6 dp).

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
    a = ap.parse_args()

    ctx = get(f"{a.api}/v1/pub/context")
    markets = {m["perpetual_id"]: m for m in ctx["markets"]}
    if a.market is not None:
        markets = {a.market: markets[a.market]}
    now_ms = int(time.time() * 1000)
    from_ms = now_ms - a.hours * 3600 * 1000
    # Compare only what the nest has sealed: hot rows can still move, sealed ones cannot.
    _, prov = nest_sql(a.nest, "select 1")
    sealed_through = prov.get("sealed_through") or 0
    print(f"nest sealed_through={sealed_through} as_of={prov.get('as_of')}; window {a.hours}h; markets {sorted(markets)}")

    failures = 0

    # ---- funding, row for row -------------------------------------------------------------------
    for pid, m in sorted(markets.items()):
        api = get(f"{a.api}/v1/market-data/{pid}/funding/{from_ms}-{now_ms}")["d"]
        api_by_block = {e["feb"]: e for e in api}
        rows, _ = nest_sql(a.nest, (
            'select cast("fundingEventBlock" as bigint) feb, cast("actualRatePct100k" as bigint) rate, '
            'cast("fundingPricePNS" as bigint) idx, cast("fundingPaymentPNS" as bigint) ppl, '
            'cast("fundingSumPNS" as bigint) sum from perpl__funding_event_completed '
            f'where cast("perpId" as bigint) = {pid} and block_number <= {sealed_through} '
            f'and block_timestamp * 1000 >= {from_ms} order by feb'))
        nest_by_block = {r["feb"]: r for r in rows}
        common = sorted(set(api_by_block) & set(nest_by_block))
        only_api = sorted(set(api_by_block) - set(nest_by_block))
        only_nest = sorted(set(nest_by_block) - set(api_by_block))
        bad = 0
        for b in common:
            x, y = api_by_block[b], nest_by_block[b]
            if (x["rate"], x["idx"], x["ppl"], x["sum"]) != (y["rate"], y["idx"], y["ppl"], y["sum"]):
                bad += 1
                print(f"  funding {m['name']} block {b}: api rate={x['rate']} idx={x['idx']} ppl={x['ppl']} sum={x['sum']} | nest rate={y['rate']} idx={y['idx']} ppl={y['ppl']} sum={y['sum']}")
        status = "ok" if not bad and not only_api and not only_nest and common else "FAIL"
        if status == "FAIL":
            failures += 1
        print(f"funding {m['name']:<5} {status}: {len(common)} events compared, {bad} differ, {len(only_api)} only in api, {len(only_nest)} only in nest")

    # ---- fills per hour against candles ----------------------------------------------------------
    for pid, m in sorted(markets.items()):
        candles = get(f"{a.api}/v1/market-data/{pid}/candles/3600/{from_ms}-{now_ms}")["d"]
        rows, _ = nest_sql(a.nest, (
            'select (block_timestamp // 3600) * 3600 * 1000 as t, count(*) as n, '
            'cast(round(sum(notional_usd) * 1e6) as bigint) as v '
            f'from perpl_fills where perp_id = {pid} and block_number <= {sealed_through} '
            f'and block_timestamp * 1000 >= {from_ms} group by 1 order by 1'))
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
        status = "ok" if compared and not bad else "FAIL"
        if status == "FAIL":
            failures += 1
        print(f"fills   {m['name']:<5} {status}: {compared} hours compared, {bad} differ")

    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
