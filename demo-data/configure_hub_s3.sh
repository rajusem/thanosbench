#!/usr/bin/env bash
# Point the hub's Thanos object storage at an S3 bucket/prefix (replacing whatever
# the `thanos-object-storage` Secret holds, e.g. the in-cluster MinIO), then
# restart the Thanos components that read or write the bucket.
#
#   EXPECTED_SERVER_SUBSTR=<part of the hub API URL> BUCKET=oia-rs PREFIX=jdj64-thanos \
#     bash configure_hub_s3.sh            # switch (REGION defaults to us-west-2, AWS_PROFILE_NAME to oia-rs)
#   EXPECTED_SERVER_SUBSTR=... bash configure_hub_s3.sh rollback   # restore the newest backup
#
# The S3 keys are read from the local AWS profile and never printed. The current
# Secret is backed up next to this script (mode 600) before anything changes, and
# the script refuses to continue if that backup is not a valid Secret. Rollback
# restores the newest backup. Receive keeps its local 24h of data across the
# restart; blocks already uploaded to the previous store stay there.
set -euo pipefail

RUN="$(cd "$(dirname "$0")" && pwd)"
NS="${NS:-open-cluster-management-observability}"
SECRET="thanos-object-storage"; KEY="thanos.yaml"
EXPECTED_SERVER_SUBSTR="${EXPECTED_SERVER_SUBSTR:-}"
BUCKET="${BUCKET:-}"; PREFIX="${PREFIX:-}"; REGION="${REGION:-us-west-2}"
AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-oia-rs}"
MODE="${1:-switch}"

[[ -n "$EXPECTED_SERVER_SUBSTR" ]] || { echo "ABORT: EXPECTED_SERVER_SUBSTR is empty (cluster guard disabled)." >&2; exit 2; }
SERVER="$(oc whoami --show-server)"   # reads kubeconfig only, no connection
[[ "$SERVER" == *"$EXPECTED_SERVER_SUBSTR"* ]] || { echo "ABORT: logged in to $SERVER, not $EXPECTED_SERVER_SUBSTR" >&2; exit 2; }
oc get --raw /healthz --request-timeout=15s >/dev/null 2>&1 || { echo "ABORT: cannot reach the cluster API at $SERVER" >&2; exit 2; }

wait_new_ready() { # $1=pod name $2=old uid : wait until a NEW pod with this name is Ready
  local uid ready=""
  for _ in $(seq 1 60); do
    uid="$(oc get -n "$NS" "$1" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
    ready="$(oc get -n "$NS" "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [[ -n "$uid" && "$uid" != "$2" && "$ready" == "True" ]] && { echo "  $1 Ready"; return 0; }
    sleep 5
  done
  echo "  ⚠️  $1 not Ready after 300s"; return 1
}

restart_objstore_users() {
  echo "== restarting Thanos components that use object storage =="
  # 1. store gateways and compactor together, then wait for the stores: while they
  #    resync, queries beyond Receive's local 24h return partial results, and rule
  #    pods restarted in that window could evaluate on partial data
  local p uids=""
  for p in $(oc get pods -n "$NS" -o name | grep -E 'thanos-store-shard|thanos-compact'); do
    uids="$uids $p=$(oc get -n "$NS" "$p" -o jsonpath='{.metadata.uid}')"; oc delete -n "$NS" "$p" --wait=false
  done
  for e in $uids; do case "$e" in pod/*thanos-store-shard*) wait_new_ready "${e%%=*}" "${e##*=}" || true;; esac; done
  # 2. receive and rule: one pod at a time, waiting for the NEW pod (new uid) to be Ready
  for p in $(oc get pods -n "$NS" -o name | grep -E 'thanos-receive-default|thanos-rule-[0-9]'); do
    old_uid="$(oc get -n "$NS" "$p" -o jsonpath='{.metadata.uid}')"
    oc delete -n "$NS" "$p"
    wait_new_ready "$p" "$old_uid" || true
  done
}

if [[ "$MODE" == "rollback" ]]; then
  # newest VALID backup (an empty or foreign file must not block the rollback)
  B=""; for f in $(find "$RUN" -maxdepth 1 -name 'thanos-object-storage.backup.*.yaml' | sort -r); do
    grep -q '^kind: Secret' "$f" && grep -q "$KEY:" "$f" && { B="$f"; break; }
  done
  [[ -n "$B" ]] || { echo "ABORT: no valid Secret backup found in $RUN" >&2; exit 1; }
  echo "== restoring $SECRET from $(basename "$B") =="
  oc replace -f "$B"
  restart_objstore_users
  exit 0
fi

[[ -n "$BUCKET" && -n "$PREFIX" ]] || { echo "ABORT: BUCKET and PREFIX are required." >&2; exit 2; }
[[ "$BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || { echo "ABORT: BUCKET='$BUCKET' is not a valid S3 bucket name." >&2; exit 2; }
[[ "$PREFIX" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] || { echo "ABORT: PREFIX='$PREFIX' must be a plain prefix like a/b." >&2; exit 2; }
[[ "$REGION" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] || { echo "ABORT: REGION='$REGION' is not a valid AWS region." >&2; exit 2; }

# 1. back up the current secret (may hold credentials: keep private, never print)
TS="$(date -u +%Y%m%dT%H%M%SZ)"; B="$RUN/thanos-object-storage.backup.$TS.yaml"
( umask 077; { oc get secret "$SECRET" -n "$NS" -o yaml || true; } \
    | python3 -c 'import sys,re; t=sys.stdin.read(); t=re.sub(r"\n  (resourceVersion|uid|creationTimestamp):.*","",t); print(t,end="")' > "$B" )
if ! grep -q '^kind: Secret' "$B" || ! grep -q "$KEY:" "$B"; then
  rm -f "$B"; echo "ABORT: could not read the current secret (backup would be empty); nothing changed" >&2; exit 1
fi
echo "== backed up current secret to $(basename "$B") =="

# 2. new objstore config
TMP="$(mktemp)"; chmod 600 "$TMP"; trap 'rm -f "$TMP"' EXIT
AK="$(aws configure get aws_access_key_id --profile "$AWS_PROFILE_NAME" 2>/dev/null || true)"
SK="$(aws configure get aws_secret_access_key --profile "$AWS_PROFILE_NAME" 2>/dev/null || true)"
[[ -n "$AK" && -n "$SK" ]] || { echo "ABORT: could not read keys for AWS profile $AWS_PROFILE_NAME" >&2; exit 1; }
cat > "$TMP" <<EOF
type: s3
config:
  bucket: $BUCKET
  endpoint: s3.$REGION.amazonaws.com
  region: $REGION
  access_key: $AK
  secret_key: $SK
  signature_version2: false
prefix: $PREFIX
EOF
unset AK SK
# replace only the data key, keeping the secret's labels/annotations
oc set data -n "$NS" "secret/$SECRET" --from-file="$KEY=$TMP"
echo "== $SECRET now points at s3://$BUCKET/$PREFIX/ =="

# 3. restart the components that read/write the bucket
restart_objstore_users
echo "== switch done; watch: oc get pods -n $NS | grep thanos =="
