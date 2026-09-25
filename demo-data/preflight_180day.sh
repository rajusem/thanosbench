#!/usr/bin/env bash
# LOCAL ANALYSIS SCRIPT (untracked, do NOT commit). Run it yourself:
#   ! bash preflight_180day.sh
#
# READ-ONLY go/no-go checks BEFORE generating/uploading 180 days of demo data to a
# SHARED ACM observability hub. Makes no changes. Verifies the preconditions that,
# if wrong, either waste the whole run or disrupt real tenants:
#   1. correct cluster context
#   2. MCO retention >= 182d for raw AND 5m AND 1h (else compactor deletes it by maxTime)
#   3. MinIO free capacity >= ~1.3x projected upload size (else ENOSPC on shared bucket)
#   4. compactor not already halted, and downsampling enabled
#   5. store-gateway shard memory headroom (best effort)
#   6. compactor scratch PVC size vs per-group working set (best effort)
#
# Reads the run manifest written by generate_180day.sh for sizing; falls back to
# env/defaults if absent. Credentials are never printed.
set -uo pipefail

NS="open-cluster-management-observability"
MANIFEST="${MANIFEST:-./gen-180day.manifest.json}"
EXPECTED_SERVER_SUBSTR="${EXPECTED_SERVER_SUBSTR:-}"
MIN_RETENTION_DAYS="${MIN_RETENTION_DAYS:-182}"
CAP_MARGIN="${CAP_MARGIN:-1.3}"
BYTES_PER_SAMPLE="${BYTES_PER_SAMPLE:-9.9}"   # measured on the 3-day set

# sizing inputs (manifest overrides these if present)
WEEKS="${WEEKS:-26}"
NUM_NAMESPACES="${NUM_NAMESPACES:-40}"
NUM_WORKLOADS="${NUM_WORKLOADS:-10}"
NUM_PODS="${NUM_PODS:-20}"
CLUSTER_COUNT="${CLUSTER_COUNT:-3}"

FAIL=0
warn() { echo "  ⚠️  $*"; }
bad()  { echo "  ❌ $*"; FAIL=1; }
ok()   { echo "  ✅ $*"; }

[[ -n "${EXPECTED_SERVER_SUBSTR}" ]] || { echo "ABORT: EXPECTED_SERVER_SUBSTR is empty (guard disabled)." >&2; exit 2; }

if [[ -f "${MANIFEST}" ]]; then
  echo "== reading sizing from ${MANIFEST} =="
  eval "$(python3 - "${MANIFEST}" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]))
print(f'WEEKS={m.get("weeks",26)}')
print(f'NUM_NAMESPACES={m.get("num_namespaces",40)}')
print(f'NUM_WORKLOADS={m.get("num_workloads",10)}')
print(f'NUM_PODS={m.get("num_pods",20)}')
print(f'CLUSTER_COUNT={len(m.get("clusters",[1,2,3]))}')
if m.get("expected_server_substr"): print(f'EXPECTED_SERVER_SUBSTR="{m["expected_server_substr"]}"')
PY
)"
fi

echo "== 1. cluster context =="
SERVER="$(oc whoami --show-server 2>/dev/null || true)"
echo "  user:   $(oc whoami 2>/dev/null || echo '?')"
echo "  server: ${SERVER:-<not logged in>}"
if [[ "${SERVER}" == *"${EXPECTED_SERVER_SUBSTR}"* ]]; then ok "on expected cluster"; else bad "server does not contain '${EXPECTED_SERVER_SUBSTR}'"; fi

# projected upload size (bytes)
PROJ_BYTES=$(python3 -c "
N=$NUM_NAMESPACES;W=$NUM_WORKLOADS;P=$NUM_PODS;C=$CLUSTER_COUNT;WK=$WEEKS
spb=3*(6*(1+N+N*W+N*W*P)+2*N)
samples=spb*(WK*7*96)*C
print(int(samples*$BYTES_PER_SAMPLE))")
PROJ_GB=$(python3 -c "print('%.1f'%($PROJ_BYTES/1e9))")
echo "== projected upload size: ~${PROJ_GB} GB (N=$NUM_NAMESPACES W=$NUM_WORKLOADS P=$NUM_PODS, ${WEEKS}w x ${CLUSTER_COUNT} clusters) =="

echo "== 2. MCO retention (need all tiers >= ${MIN_RETENTION_DAYS}d) =="
# MCO may bake retention directly into the compactor StatefulSet args rather than
# the MCO CR spec — check both sources; StatefulSet args take precedence if found.
COMPACT_ARGS="$(oc get statefulset observability-thanos-compact \
  -n open-cluster-management-observability \
  -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null | tr ',' '\n' | grep -i retention || true)"
MCO_YAML="$(oc get multiclusterobservability -A -o yaml 2>/dev/null || true)"

if [[ -n "${COMPACT_ARGS}" ]]; then
  echo "  (retention found in compactor StatefulSet args — authoritative source)"
  echo "${COMPACT_ARGS}" | sed 's/^/  /'
  RET_OUT="$(MIN_DAYS="${MIN_RETENTION_DAYS}" COMPACT_ARGS="${COMPACT_ARGS}" python3 - <<'PY'
import re,sys,os
min_days=int(os.environ["MIN_DAYS"])
args=os.environ["COMPACT_ARGS"]
def to_days(v):
    m=re.fullmatch(r'\s*(\d+)\s*([smhdwy])\s*',str(v).strip('"'))
    if not m: return None
    n=int(m.group(1)); u=m.group(2)
    return n*{'s':1/86400,'m':1/1440,'h':1/24,'d':1,'w':7,'y':365}[u]
keys={'raw':'retentionResolutionRaw','5m':'retentionResolution5m','1h':'retentionResolution1h'}
arg_map={'raw':'resolution-raw','5m':'resolution-5m','1h':'resolution-1h'}
bad=0
for tier,key in keys.items():
    m=re.search(r'retention\.'+arg_map[tier]+r'[=\s]([0-9]+[smhdwy])',args)
    if m:
        v=m.group(1); d=to_days(v)
        if d is None: print(f"UNPARSEABLE {key}={v}"); bad=1
        elif d < min_days: print(f"TOOLOW {key}={v} (~{d:.0f}d < {min_days}d)"); bad=1
        else: print(f"OK {key}={v} (~{d:.0f}d)")
    else:
        print(f"UNSET {key} in StatefulSet args (defaults to 0=forever — safe)"); # 0=forever is OK
sys.exit(1 if bad else 0)
PY
)"; RET_RC=$?
elif [[ -n "${MCO_YAML}" ]]; then
  echo "  (retention not in StatefulSet args — checking MCO CR spec)"
  RET_OUT="$(MIN_DAYS="${MIN_RETENTION_DAYS}" python3 - <<PY
import re,sys,os
y='''${MCO_YAML}'''
min_days=int(os.environ["MIN_DAYS"])
def to_days(v):
    if v is None: return None
    m=re.fullmatch(r'\s*(\d+)\s*([smhdwy])\s*',str(v))
    if not m: return None
    n=int(m.group(1)); u=m.group(2)
    mult={'s':1/86400,'m':1/1440,'h':1/24,'d':1,'w':7,'y':365}[u]
    return n*mult
# lightweight scan (avoid yaml dep): find retentionResolution* fields
fields={}
for key in ['retentionResolutionRaw','retentionResolution5m','retentionResolution1h']:
    m=re.search(key+r':\s*"?([0-9]+[smhdwy])"?',y)
    fields[key]=m.group(1) if m else None
bad=0
for key in ['retentionResolutionRaw','retentionResolution5m','retentionResolution1h']:
    v=fields[key]; d=to_days(v)
    if v is None:
        print(f"UNSET {key} in MCO CR (defaults to 0=forever — safe)"); # 0=forever is OK, not flagged
    elif d is None:
        print(f"UNPARSEABLE {key}={v}"); bad=1
    elif d < min_days:
        print(f"TOOLOW {key}={v} (~{d:.0f}d < {min_days}d)"); bad=1
    else:
        print(f"OK {key}={v} (~{d:.0f}d)")
sys.exit(1 if bad else 0)
PY
)"; RET_RC=$?
  echo "${RET_OUT}" | sed 's/^/  /'
  if [[ "${RET_RC}" -eq 0 ]]; then ok "all retention tiers >= ${MIN_RETENTION_DAYS}d (or 0=forever)"; else bad "retention too low — backfilled data would be deleted by maxTime"; fi
else
  bad "could not read compactor StatefulSet or MultiClusterObservability (retention UNVERIFIED)"
fi

echo "== 3. MinIO free capacity =="
MINIO_POD="$(oc get pods -n "${NS}" -o name 2>/dev/null | grep -iE 'minio' | grep -viE 'setup|job' | head -1 || true)"
if [[ -z "${MINIO_POD}" ]]; then
  warn "no minio pod found; cannot check capacity (verify manually)"
else
  DF="$(oc exec -n "${NS}" "${MINIO_POD}" -- df -Pk 2>/dev/null || true)"
  # pick the mount that looks like the data dir; fall back to the largest non-root mount
  FREEB=$(printf '%s\n' "${DF}" | awk 'NR>1 && $6 !~ /^\/(proc|sys|dev|etc|run|$)/ {print $4*1024" "$6}' | sort -rn | head -1)
  FREE_BYTES="${FREEB%% *}"; FREE_MNT="${FREEB#* }"
  if [[ -n "${FREE_BYTES:-}" ]]; then
    FREE_GB=$(python3 -c "print('%.1f'%(${FREE_BYTES}/1e9))")
    NEED_BYTES=$(python3 -c "print(int(${PROJ_BYTES}*${CAP_MARGIN}))")
    echo "  free on ${FREE_MNT}: ${FREE_GB} GB; need ~$(python3 -c "print('%.1f'%(${NEED_BYTES}/1e9))") GB (proj x ${CAP_MARGIN})"
    if [[ "${FREE_BYTES}" -ge "${NEED_BYTES}" ]]; then ok "enough MinIO capacity"; else bad "insufficient MinIO free space for a ${PROJ_GB} GB upload"; fi
  else
    warn "could not parse df from minio pod (verify manually)"
  fi
fi

echo "== 4. compactor health + downsampling =="
CPOD="$(oc get pods -n "${NS}" -o name 2>/dev/null | grep -iE 'thanos-compact' | head -1 || true)"
if [[ -z "${CPOD}" ]]; then
  warn "no thanos-compact pod found"
else
  HALT="$(oc logs -n "${NS}" "${CPOD}" --tail=800 2>/dev/null | grep -iE 'halt|compaction failed' | tail -3 || true)"
  if [[ -n "${HALT}" ]]; then bad "compactor shows halt/failure lines:"; printf '%s\n' "${HALT}" | sed 's/^/     /'; else ok "no recent compactor halt in logs"; fi
  DS="$(oc get statefulset -n "${NS}" -o yaml 2>/dev/null | grep -iE 'downsampling.disable' | head -1 || true)"
  if printf '%s' "${DS}" | grep -qiE 'downsampling.disable=?true|downsampling.disable$'; then
    bad "downsampling appears DISABLED (${DS// /}) — 5m/1h tiers will never appear"
  else
    ok "downsampling not disabled (5m/1h expected)"
  fi
fi

echo "== 5. store-gateway shard memory headroom (best effort) =="
oc adm top pods -n "${NS}" 2>/dev/null | grep -iE 'thanos-store-shard' | sed 's/^/  usage: /' || warn "metrics unavailable (oc adm top)"
oc get pods -n "${NS}" -o custom-columns='POD:.metadata.name,MEM_LIM:.spec.containers[*].resources.limits.memory' 2>/dev/null \
  | grep -iE 'thanos-store-shard' | sed 's/^/  limit: /' || true
warn "702 pre-compaction blocks x high cardinality inflate index-header RAM; watch shards for OOM after upload"

echo "== 6. compactor scratch PVC vs per-group working set (best effort) =="
PERGROUP_GB=$(python3 -c "print('%.1f'%(${PROJ_BYTES}/${CLUSTER_COUNT}/1e9))")
echo "  per-cluster group ~${PERGROUP_GB} GB (compactor downloads a group to its PVC to compact/downsample)"
oc get pvc -n "${NS}" 2>/dev/null | grep -iE 'compact' | sed 's/^/  pvc: /' || warn "no compactor PVC listed"

echo
if [[ "${FAIL}" -eq 0 ]]; then
  echo "== PREFLIGHT: GO (review the ⚠️ warnings; they are best-effort/manual-verify) =="
  exit 0
else
  echo "== PREFLIGHT: NO-GO — fix the ❌ items above before generating/uploading =="
  exit 1
fi
