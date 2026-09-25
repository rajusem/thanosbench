#!/usr/bin/env bash
# Demo-data ops script (see demo-data/README.md).
#
# Generate ~180 days of leveled right-sizing blocks that tile CLEANLY (no overlaps)
# so the Thanos compactor never halts. Uses custom-continous-1-week-full (span =
# exactly 168h/7d), stepped back one week at a time from a single PINNED,
# day-aligned base time, for each demo cluster. Output is FLAT (all ULID dirs in
# one dir; cluster identity lives in each block's meta.json).
#
# Writes a run-manifest (default ./gen-180day.manifest.json) that preflight/upload/
# validate read as the single source of truth (base epoch, weeks, clusters,
# cardinality, expected block count) so the stages can't silently drift.
#
# Safety:
#   * refuses to write into a non-empty OUT unless FORCE=1 (a re-run must not APPEND
#     a second batch with a new anchor -> that produces overlapping windows -> halt)
#   * BASE_EPOCH is pinned and floored to a day boundary (stable, compaction-aligned)
#   * pre-flight local-disk check before writing tens of GB
#   * asserts each week produced exactly BLOCKS_PER_WEEK blocks, and the grand total
#
# Usage:
#   DRY_RUN=1 ./generate_180day.sh                       # print plan + disk check only
#   ./generate_180day.sh                                 # small (validated) config
#   NUM_NAMESPACES=40 NUM_WORKLOADS=10 NUM_PODS=20 ./generate_180day.sh   # full config
set -euo pipefail

PROFILE="${PROFILE:-custom-continous-1-week-full}"   # 168h span
BLOCKS_PER_WEEK="${BLOCKS_PER_WEEK:-9}"              # len(duration list) of the -full profile
WEEKS="${WEEKS:-26}"                                 # 26*7 = 182 days
CLUSTERS="${CLUSTERS:-ac-test-man-1 ac-test-man-2 ac-test-man-3}"
OUT="${OUT:-./gen-180day-flat}"
MANIFEST="${MANIFEST:-./gen-180day.manifest.json}"
WORKERS="${WORKERS:-20}"
EXPECTED_SERVER_SUBSTR="${EXPECTED_SERVER_SUBSTR:-}"
FORCE="${FORCE:-0}"
BYTES_PER_SAMPLE="${BYTES_PER_SAMPLE:-9.9}"                # right-sizing (measured on the 3-day set)
FILLER_BYTES_PER_SAMPLE="${FILLER_BYTES_PER_SAMPLE:-4.6}"  # filler compresses ~2x better (measured, per-pod filler)
# The hub's compactor later adds downsampled copies next to the raw blocks; with
# samples every 5-15m the 5m copy is ~3.8x the raw size (measured with Thanos
# v0.42.4 on this data) and the 1h copy ~0.85-1.1x.
DS_5M_RATIO="${DS_5M_RATIO:-3.8}"
DS_1H_RATIO="${DS_1H_RATIO:-1.1}"
DISK_MARGIN="${DISK_MARGIN:-1.15}"

NUM_NAMESPACES="${NUM_NAMESPACES:-20}"
NUM_WORKLOADS="${NUM_WORKLOADS:-5}"
NUM_PODS="${NUM_PODS:-10}"
NUM_EXTRA_METRICS="${NUM_EXTRA_METRICS:-0}"   # filler: one series per namespace per metric
NUM_POD_METRICS="${NUM_POD_METRICS:-0}"       # filler: one series per pod per metric

# Pin the anchor and floor to a UTC day boundary (stable across re-runs; aligns
# block boundaries with the compactor's epoch-aligned planning windows).
BASE_EPOCH="${BASE_EPOCH:-$(( ( $(date -u +%s) / 86400 ) * 86400 ))}"
DRY_RUN="${DRY_RUN:-0}"

# every sizing knob must be a plain non-negative integer (no sign, no leading zero)
for v in WEEKS NUM_NAMESPACES NUM_WORKLOADS NUM_PODS NUM_EXTRA_METRICS NUM_POD_METRICS; do
  [[ "${!v}" =~ ^(0|[1-9][0-9]{0,8})$ ]] || { echo "ABORT: ${v}='${!v}' must be a non-negative integer." >&2; exit 1; }
done

fmt() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
rs_series_per_block() { python3 -c "N=$NUM_NAMESPACES;W=$NUM_WORKLOADS;P=$NUM_PODS;print(3*(6*(1+N+N*W+N*W*P)+2*N))"; }
filler_series_per_block() { python3 -c "N=$NUM_NAMESPACES;W=$NUM_WORKLOADS;P=$NUM_PODS;print($NUM_EXTRA_METRICS*N+$NUM_POD_METRICS*N*W*P)"; }

NCL=$(printf '%s\n' $CLUSTERS | grep -c .)
RS_SPB=$(rs_series_per_block)
FILLER_SPB=$(filler_series_per_block)
SPB=$(python3 -c "print($RS_SPB+$FILLER_SPB)")
BLOCKS=$(( WEEKS * BLOCKS_PER_WEEK * NCL ))
PER_CLUSTER=$(( WEEKS * BLOCKS_PER_WEEK ))
# right-sizing series sample every 15m (96/day), filler every 5m (288/day)
PROJ_BYTES=$(python3 -c "print(int(($RS_SPB*96*$BYTES_PER_SAMPLE+$FILLER_SPB*288*$FILLER_BYTES_PER_SAMPLE)*($WEEKS*7)*$NCL))")
PROJ_GB=$(python3 -c "print('%.1f'%($PROJ_BYTES/1e9))")
HUB_GB=$(python3 -c "print('%.1f'%($PROJ_BYTES*(1+$DS_5M_RATIO+$DS_1H_RATIO)/1e9))")

echo "== plan =="
echo "  profile:      ${PROFILE} (168h, ${BLOCKS_PER_WEEK} blocks/week)"
echo "  clusters:     ${NCL} (${CLUSTERS})"
echo "  weeks:        ${WEEKS} (~$(( WEEKS*7 )) days)"
echo "  cardinality:  N=${NUM_NAMESPACES} W=${NUM_WORKLOADS} P=${NUM_PODS} -> ${RS_SPB} right-sizing series/block"
echo "  filler:       NUM_EXTRA_METRICS=${NUM_EXTRA_METRICS} NUM_POD_METRICS=${NUM_POD_METRICS} -> ${FILLER_SPB} series/block (total ${SPB})"
echo "  total blocks: ${BLOCKS} (${PER_CLUSTER}/cluster)"
echo "  window:       $(fmt "$(( BASE_EPOCH - (WEEKS)*7*86400 ))") .. $(fmt "$BASE_EPOCH") (pinned, day-aligned)"
echo "  projected:    ~${PROJ_GB} GB on disk and to upload; ~${HUB_GB} GB on the hub after downsampling (raw + 5m + 1h)"
echo "  output:       ${OUT}   manifest: ${MANIFEST}"

if python3 -c "import sys; sys.exit(0 if $SPB > 5000000 else 1)"; then echo "ABORT: ${SPB} series/block > maxSeriesPerBlock=5,000,000." >&2; exit 1; fi

# local disk precheck (df -Pk on OUT's parent)
OUT_PARENT="$(dirname "$OUT")"; mkdir -p "$OUT_PARENT"
AVAIL_BYTES=$(df -Pk "$OUT_PARENT" | awk 'NR==2{print $4*1024}')
NEED_BYTES=$(python3 -c "print(int($PROJ_BYTES*$DISK_MARGIN))")
echo "  disk free at ${OUT_PARENT}: $(python3 -c "print('%.1f'%($AVAIL_BYTES/1e9))") GB; need ~$(python3 -c "print('%.1f'%($NEED_BYTES/1e9))") GB"
if ! python3 -c "import sys; sys.exit(0 if ${AVAIL_BYTES} >= ${NEED_BYTES} else 1)"; then echo "ABORT: not enough local disk for ~${PROJ_GB} GB." >&2; exit 1; fi

if [[ "$DRY_RUN" == "1" ]]; then echo "== DRY_RUN: not generating. =="; exit 0; fi

# idempotency: never append into a non-empty OUT (would create a second, differently
# anchored batch -> overlapping windows for the same cluster labels -> compactor halt)
if [[ -d "$OUT" ]] && [[ -n "$(ls -A "$OUT" 2>/dev/null)" ]]; then
  if [[ "$FORCE" == "1" ]]; then
    echo "== FORCE=1: clearing non-empty ${OUT} =="; rm -rf "${OUT:?}/"*
  else
    echo "ABORT: ${OUT} is not empty. Re-running would APPEND a mis-tiled batch." >&2
    echo "       Use FORCE=1 to wipe and regenerate, or set a different OUT." >&2
    exit 1
  fi
fi

if [[ ! -x ./thanosbench ]]; then echo "== building thanosbench =="; make build; fi
mkdir -p "$OUT"
START=$(date -u +%s)

for cluster in $CLUSTERS; do
  for (( w=0; w<WEEKS; w++ )); do
    MAX_TIME=$(fmt "$(( BASE_EPOCH - w*7*86400 ))")
    # decorrelated jitter (distinct seeds so MIN/MAX aren't locked together per second)
    read -r MIN_GAUGE MAX_GAUGE < <(awk -v s="${RANDOM}${w}" 'BEGIN{srand(s);printf "%.3f %.3f\n",2.1+rand()*2.5,10.6+rand()*9.2}')
    BEFORE=$(find "$OUT" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')
    echo "  [${cluster}] week ${w}/${WEEKS} max-time=${MAX_TIME} gauge=[${MIN_GAUGE},${MAX_GAUGE}]"
    NUM_NAMESPACES=$NUM_NAMESPACES NUM_WORKLOADS=$NUM_WORKLOADS NUM_PODS=$NUM_PODS \
      NUM_EXTRA_METRICS=$NUM_EXTRA_METRICS NUM_POD_METRICS=$NUM_POD_METRICS MIN_GAUGE=$MIN_GAUGE MAX_GAUGE=$MAX_GAUGE \
      ./thanosbench block plan -p "$PROFILE" \
        --labels "cluster=\"${cluster}\"" --labels "aggregation=\"1d\"" \
        --max-time "$MAX_TIME" \
      | ./thanosbench block gen --output.dir "$OUT" --workers "$WORKERS"
    AFTER=$(find "$OUT" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')
    ADDED=$(( AFTER - BEFORE ))
    [[ "$ADDED" -eq "$BLOCKS_PER_WEEK" ]] || { echo "ABORT: week produced ${ADDED} blocks, expected ${BLOCKS_PER_WEEK} (partial run?)." >&2; exit 1; }
  done
done

ACTUAL=$(find "$OUT" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')
[[ "$ACTUAL" -eq "$BLOCKS" ]] || { echo "ABORT: generated ${ACTUAL} blocks, expected ${BLOCKS}." >&2; exit 1; }

# write the run-manifest (single source of truth for later stages)
python3 - "$MANIFEST" <<PY
import json,sys
json.dump({
  "base_epoch": $BASE_EPOCH,
  "weeks": $WEEKS, "blocks_per_week": $BLOCKS_PER_WEEK,
  "clusters": "$CLUSTERS".split(),
  "num_namespaces": $NUM_NAMESPACES, "num_workloads": $NUM_WORKLOADS, "num_pods": $NUM_PODS,
  "series_per_block": $SPB,
  "rs_series_per_block": $RS_SPB, "filler_series_per_block": $FILLER_SPB,
  "num_extra_metrics": $NUM_EXTRA_METRICS, "num_pod_metrics": $NUM_POD_METRICS,
  "blocks_per_cluster": $PER_CLUSTER, "expected_blocks": $BLOCKS,
  "profile": "$PROFILE",
  "expected_server_substr": "$EXPECTED_SERVER_SUBSTR",
  "min_data_epoch": $BASE_EPOCH - $WEEKS*7*86400, "max_data_epoch": $BASE_EPOCH,
  "out": "$OUT",
}, open(sys.argv[1],"w"), indent=2)
print("wrote", sys.argv[1])
PY

ELAPSED=$(( $(date -u +%s) - START ))
SIZE=$(du -sh "$OUT" | awk '{print $1}')
echo "== done in ${ELAPSED}s =="
echo "  blocks: ${ACTUAL} (expected ${BLOCKS})   size: ${SIZE}"
echo "  next:   ! bash preflight_180day.sh   then   ! bash upload_180day_batched.sh"
