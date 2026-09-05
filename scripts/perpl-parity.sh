#!/usr/bin/env bash
# Perpl nest against Perpl's own public API (nightswatchhq/nuthatch#1148, Phase 4).
#
# Two comparisons, both against endpoints that need no key:
#
#   funding  FundingEventCompleted rows, keyed by fundingEventBlock, against
#            GET /api/v1/market-data/{market}/funding/{from_ms}-{to_ms}, whose entries carry the same
#            block as `feb`. Row for row: rate, funding price, payment, sum.
#   fills    maker-side fills per hour and market (count, AUSD notional) against
#            GET /api/v1/market-data/{market}/candles/3600/{from_ms}-{to_ms}, whose `n` is the number
#            of fills in the hour and `v` the notional in AUSD (6 dp).
#
# Fails closed: a window the nest has not sealed or the API does not answer is a FAIL, never an
# implicit match. Prints one line per comparison and exits non-zero on any mismatch.
#
# usage: perpl-parity.sh --nest http://127.0.0.1:8112 [--hours 24] [--market 1] [--api https://app.perpl.xyz/api]
#                        [--from-ms X --to-ms Y]    explicit window (unix ms); together they override --hours
# needs: bash, curl, jq
set -euo pipefail

nest="" api="https://app.perpl.xyz/api" hours=24 market="" from_ms="" to_ms=""
while [ $# -gt 0 ]; do
  case "$1" in
    --nest)    nest=$2;    shift 2 ;;
    --api)     api=$2;     shift 2 ;;
    --hours)   hours=$2;   shift 2 ;;
    --market)  market=$2;  shift 2 ;;
    --from-ms) from_ms=$2; shift 2 ;;
    --to-ms)   to_ms=$2;   shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$nest" ] || { echo "usage: $0 --nest URL [--hours N] [--market ID] [--api URL] [--from-ms X --to-ms Y]" >&2; exit 2; }

# Any non-2xx or unreachable endpoint aborts the run: no answer is not a match.
get() {
  curl -fsS --max-time 30 -A nuthatch-perpl-parity "$1" || { echo "FAIL no answer from $1" >&2; return 1; }
}

nest_sql() {
  local answer
  answer=$(curl -fsS --max-time 30 -A nuthatch-perpl-parity --get --data-urlencode "q=$1" "$nest/sql") \
    || { echo "FAIL nest did not answer: ${1:0:80}" >&2; return 1; }
  if [ "$(printf '%s' "$answer" | jq -r '.truncated // false')" = "true" ]; then
    echo "FAIL nest answer truncated for: ${1:0:80}" >&2; exit 1
  fi
  printf '%s' "$answer"
}

context=$(get "$api/v1/pub/context") || exit 1
if [ -n "$market" ]; then
  markets=$(printf '%s' "$context" | jq -c --argjson id "$market" \
    '[.markets[] | select(.perpetual_id == $id)] | if length == 0 then error("market \($id) is not in the context") else . end')
else
  markets=$(printf '%s' "$context" | jq -c '.markets')
fi
now_ms=${to_ms:-$(( $(date +%s) * 1000 ))}
from_ms=${from_ms:-$(( now_ms - hours * 3600 * 1000 ))}

# Compare only what the nest has sealed: hot rows can still move, sealed ones cannot.
answer=$(nest_sql "select 1") || exit 1
prov=$(printf '%s' "$answer" | jq -c '.provenance // {}')
sealed_through=$(printf '%s' "$prov" | jq -r '.sealed_through // 0')
echo "nest sealed_through=$sealed_through as_of=$(printf '%s' "$prov" | jq -r '.as_of'); window ${hours}h; markets $(printf '%s' "$markets" | jq -c '[.[].perpetual_id] | sort')"

failures=0
pids=$(printf '%s' "$markets" | jq -r '.[].perpetual_id' | sort -n)
name_of() { printf '%s' "$markets" | jq -r --argjson id "$1" '.[] | select(.perpetual_id == $id) | .name'; }

# ---- funding, row for row -------------------------------------------------------------------
for pid in $pids; do
  name=$(name_of "$pid")
  funding=$(get "$api/v1/market-data/$pid/funding/$from_ms-$now_ms") || exit 1
  rows=$(nest_sql "select cast(\"fundingEventBlock\" as bigint) feb, cast(\"actualRatePct100k\" as bigint) rate, \
cast(\"fundingPricePNS\" as bigint) idx, cast(\"fundingPaymentPNS\" as bigint) ppl, \
cast(\"fundingSumPNS\" as bigint) sum from perpl__funding_event_completed \
where cast(\"perpId\" as bigint) = $pid and block_number <= $sealed_through \
and block_timestamp * 1000 >= $from_ms and block_timestamp * 1000 < $now_ms order by feb") || exit 1
  jq -rn --arg name "$name" --argjson from "$from_ms" --argjson to "$now_ms" \
     --argjson api "$funding" --argjson nest "$rows" '
    # The API answers a window that predates the market with its first event, outside the
    # window; only entries inside it are the claim being checked.
    ($api.d | map(select(.at.t >= $from and .at.t < $to))) as $api
    | ($nest.rows) as $rows
    | ($api | map({key: (.feb | tostring), value: .}) | from_entries) as $a
    | ($rows | map({key: (.feb | tostring), value: .}) | from_entries) as $n
    | ([$a, $n | keys[]] | unique | map(tonumber) | sort) as $all
    | ($all | map(select(($a[tostring]) and ($n[tostring])))) as $common
    | ($all | map(select(($a[tostring]) and ($n[tostring] | not)))) as $only_api
    | ($all | map(select(($a[tostring] | not) and ($n[tostring])))) as $only_nest
    # The API rate is in millionths; the chain rate is parts per hundred thousand.
    | ($common | map(. as $b | $a[tostring] as $x | $n[tostring] as $y
        | select([$x.rate, $x.idx, $x.ppl, $x.sum] | map(tonumber)
                 != ([($y.rate | tonumber) * 10, $y.idx, $y.ppl, $y.sum] | map(tonumber)))
        | "  funding \($name) block \($b): api rate=\($x.rate) idx=\($x.idx) ppl=\($x.ppl) sum=\($x.sum) | nest rate=\($y.rate) idx=\($y.idx) ppl=\($y.ppl) sum=\($y.sum)")) as $diffs
    | (if ($api | length) == 0 and ($rows | length) == 0 then "n/a"   # no funding events in this window on either side
       elif ($diffs | length) == 0 and ($only_api | length) == 0 and ($only_nest | length) == 0 and ($common | length) > 0 then "ok"
       else "FAIL" end) as $status
    | ($name | if length < 5 then . + (" " * (5 - length)) else . end) as $padded
    | $diffs[],
      "funding \($padded) \($status): \($common | length) events compared, \($diffs | length) differ, \($only_api | length) only in api, \($only_nest | length) only in nest",
      (if $status == "FAIL" then ("" | halt_error(1)) else empty end)
  ' || failures=$((failures + 1))
done

# ---- fills per hour against candles ----------------------------------------------------------
for pid in $pids; do
  name=$(name_of "$pid")
  candles=$(get "$api/v1/market-data/$pid/candles/3600/$from_ms-$now_ms") || exit 1
  rows=$(nest_sql "select (block_timestamp // 3600) * 3600 * 1000 as t, count(*) as n, \
cast(round(sum(notional_usd) * 1e6) as bigint) as v \
from perpl_fills where perp_id = $pid and block_number <= $sealed_through \
and block_timestamp * 1000 >= $from_ms and block_timestamp * 1000 < $now_ms group by 1 order by 1") || exit 1
  jq -rn --arg name "$name" --argjson to "$now_ms" --argjson api "$candles" --argjson nest "$rows" '
    ($nest.rows | map({key: (.t | tostring), value: .}) | from_entries) as $n
    | [ $api.d[]
        | select(.t + 3600 * 1000 <= $to)          # the open hour is not final on either side
        | . as $c | ($n[$c.t | tostring]) as $y
        | if $y == null then
            (if ($c.n | tonumber) != 0
             then {bad: 1, line: "  fills \($name) hour \($c.t): api n=\($c.n) v=\($c.v) | nest has no sealed rows"}
             else empty end)
          elif ($c.n | tonumber) != ($y.n | tonumber) or ($c.v | tonumber) != ($y.v | tonumber) then
            {compared: 1, bad: 1, line: "  fills \($name) hour \($c.t): api n=\($c.n) v=\($c.v) | nest n=\($y.n) v=\($y.v)"}
          else {compared: 1} end
      ] as $r
    | ($r | map(.compared // 0) | add // 0) as $compared
    | ($r | map(.bad // 0) | add // 0) as $bad
    | (if $compared == 0 and $bad == 0 and ([$api.d[] | (.n | tonumber) != 0] | any | not) then "n/a"   # no fills in this window on either side
       elif $compared > 0 and $bad == 0 then "ok"
       else "FAIL" end) as $status
    | ($name | if length < 5 then . + (" " * (5 - length)) else . end) as $padded
    | ($r[] | .line // empty),
      "fills   \($padded) \($status): \($compared) hours compared, \($bad) differ",
      (if $status == "FAIL" then ("" | halt_error(1)) else empty end)
  ' || failures=$((failures + 1))
done

[ "$failures" -eq 0 ]
