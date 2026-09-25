#!/bin/bash

# Right-sizing block generation. Override any of these with environment variables:
#   NUM_CLUSTERS=10 NUM_NAMESPACES=100 NUM_WORKLOADS=10 NUM_PODS=3 ./run_thanosbench.sh
#
# Optional: pass a cluster index range as the first argument (used by run_parallel.sh):
#   ./run_thanosbench.sh 1,5
#
# Generates WEEKS (default 16) weekly blocks ending today (UTC); set END_EPOCH to pin
# the end date.

# Scale (defaults: 10 clusters, 100 namespaces, 10 workloads, 3 pods per workload)
NUM_CLUSTERS="${NUM_CLUSTERS:-10}"
NUM_NAMESPACES="${NUM_NAMESPACES:-100}"
NUM_WORKLOADS="${NUM_WORKLOADS:-10}"
NUM_PODS="${NUM_PODS:-3}"
NUM_NAMES="${NUM_NAMES:-0}"
CLUSTER_START="${CLUSTER_START:-1}"
PROFILE="${PROFILE:-custom-continous-1-week-workload-pod}"

range="$1"
if [ -n "$range" ]; then
  IFS=',' read -r start end <<< "$range"
  start=$(printf "%d" "$start")
  end=$(printf "%d" "$end")
else
  start=$CLUSTER_START
  end=$NUM_CLUSTERS
fi

# Weekly --max-time values: the WEEKS weeks ending at END_EPOCH (default: today
# 00:00 UTC), oldest first. Keeping the data recent keeps it inside the hub's
# retention (MCO default 365d); older blocks are deleted by the compactor.
WEEKS="${WEEKS:-16}"
END_EPOCH="${END_EPOCH:-$(( ( $(date -u +%s) / 86400 ) * 86400 ))}"
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
MAX_TIMES=()
for (( w = WEEKS - 1; w >= 0; w-- )); do MAX_TIMES+=("$(iso $(( END_EPOCH - w * 7 * 86400 )))"); done

# custom-continous-1-week-workload-pod has no per-series `profile` label, so its
# blocks get one as an external label for the dashboards' $profile filter. The
# other right-sizing profiles emit `profile` per series; an external `profile`
# would overwrite it and fold P95/P99 into "Max OverAll", so it is not set for them.
PROFILE_LABEL=()
if [ "$PROFILE" = "custom-continous-1-week-workload-pod" ]; then
  PROFILE_LABEL=(--labels "profile=\"Max OverAll\"")
fi

random_in_range() {
  local min=$1
  local max=$2
  echo $(awk -v min=$min -v max=$max 'BEGIN{srand(); print min + rand() * (max - min)}')
}

for ((cluster = start; cluster <= end; cluster++)); do
    for i in "${!MAX_TIMES[@]}"; do
      MAX_TIME=${MAX_TIMES[$i]}

      MIN_GAUGE=$(random_in_range 2.1 4.6)
      MAX_GAUGE=$(random_in_range 10.6 19.8)

      OUTPUT_DIR="./new-run/cluster-${cluster}"

      mkdir -p "$OUTPUT_DIR"

      NUM_NAMESPACES=$NUM_NAMESPACES \
      NUM_WORKLOADS=$NUM_WORKLOADS \
      NUM_PODS=$NUM_PODS \
      NUM_NAMES=$NUM_NAMES \
      MIN_GAUGE=$MIN_GAUGE \
      MAX_GAUGE=$MAX_GAUGE \
      ./thanosbench block plan -p "$PROFILE" \
        --labels "instance=\"bench\"" \
        --labels "cluster=\"ac-test-man-${cluster}\"" \
        --labels "container=\"bench\"" \
        --labels "resource=\"cpu\"" \
        --labels "clusterType=\"bench\"" \
        --labels "mode=\"idle\"" \
        ${PROFILE_LABEL[@]+"${PROFILE_LABEL[@]}"} \
        --max-time "$MAX_TIME" \
        | ./thanosbench block gen --output.dir "$OUTPUT_DIR" --workers 20
    done
done

echo "Block generation completed for clusters from $start to $end using profile $PROFILE ($NUM_NAMESPACES namespaces, $NUM_WORKLOADS workloads, $NUM_PODS pods)."
