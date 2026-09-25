#!/usr/bin/env bash
# LOCAL ANALYSIS SCRIPT (untracked, do NOT commit). Run it yourself:
#   ! bash upload_180day_batched.sh              # generate first, and run preflight
#   ! RESUME=1   bash upload_180day_batched.sh   # resume a dropped upload (no delete)
#   ! TEARDOWN=1 bash upload_180day_batched.sh   # label-scoped delete of demo data only
#
# Uploads the flat 180-day right-sizing blocks to the hub's in-cluster MinIO, then
# rolls the store-gateway shards. Hardened for a SHARED cluster:
#   * reads the run-manifest (single source of truth) for counts/clusters
#   * MinIO free-capacity guard before writing tens of GB to a shared bucket
#   * per-block TWO-PHASE upload: data first, meta.json LAST (Thanos safe-upload
#     contract) so store-gw/compactor never see a partial block mid-run
#   * delete-scan RECONCILES listed-vs-fetched metas and ABORTS if it cannot prove
#     the demo set is clean (an undeleted demo block -> overlap -> compactor HALT)
#   * ROLLING store-gw restart (one shard at a time, wait Ready) -> no full outage
#   * resumable (per-block `aws s3 sync`), staged by cluster with progress
#   * no global side effects: uses a throwaway AWS_CONFIG_FILE and a random port
#   * only ever deletes blocks whose external `cluster` label is a demo cluster
set -euo pipefail

NS="open-cluster-management-observability"
SECRET="thanos-object-storage"; KEY="thanos.yaml"; MINIO_BUCKET="thanos"; SVC="minio"
MANIFEST="${MANIFEST:-./gen-180day.manifest.json}"
SRC="${SRC:-./gen-180day-flat}"
DEMO_CLUSTERS="${DEMO_CLUSTERS:-ac-test-man-1 ac-test-man-2 ac-test-man-3}"
EXPECTED_BLOCKS="${EXPECTED_BLOCKS:-702}"
EXPECTED_SERVER_SUBSTR="${EXPECTED_SERVER_SUBSTR:-}"
PARALLEL="${PARALLEL:-6}"
DELETE_CAP="${DELETE_CAP:-5000}"   # default raised from 1100 → 5000 to handle 20 clusters (4,680 blocks)
RESUME="${RESUME:-0}"
TEARDOWN="${TEARDOWN:-0}"
RESTART_STORE="${RESTART_STORE:-rolling}"     # rolling | all | none
STAGE_PAUSE_SEC="${STAGE_PAUSE_SEC:-0}"       # pause between per-cluster stages (let compaction catch up)
SKIP_CAPACITY_CHECK="${SKIP_CAPACITY_CHECK:-0}"
CAP_MARGIN="${CAP_MARGIN:-1.2}"
WATCH_COMPACTOR="${WATCH_COMPACTOR:-1}"
LOCAL_PORT="${LOCAL_PORT:-$(( 20000 + RANDOM % 20000 ))}"

trim() { sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'\''//; s/'\''$//'; }

# read manifest if present (overrides the defaults above)
# note: write to a temp file then source to avoid bash misparse of heredoc-in-eval-in-$()
if [[ -f "${MANIFEST}" ]]; then
  _mvars="$(mktemp)"
  MANIFEST_PATH="${MANIFEST}" python3 - >"${_mvars}" <<'PY'
import json,sys,os
m=json.load(open(os.environ["MANIFEST_PATH"]))
print("EXPECTED_BLOCKS=" + str(m.get("expected_blocks",702)))
print('DEMO_CLUSTERS="' + " ".join(m.get("clusters",["ac-test-man-1","ac-test-man-2","ac-test-man-3"])) + '"')
print('SRC="' + m.get("out","./gen-180day-flat") + '"')
if m.get("expected_server_substr"):
    print('EXPECTED_SERVER_SUBSTR="' + m["expected_server_substr"] + '"')
PY
  # shellcheck disable=SC1090
  source "${_mvars}"; rm -f "${_mvars}"
fi

[[ -n "${EXPECTED_SERVER_SUBSTR}" ]] || { echo "ABORT: EXPECTED_SERVER_SUBSTR empty (guard disabled)." >&2; exit 2; }

# sanity: warn early if DELETE_CAP < EXPECTED_BLOCKS (would abort the demo-block delete on a fresh run)
if [[ "${TEARDOWN}" != "1" && "${RESUME}" != "1" && "${EXPECTED_BLOCKS}" -gt "${DELETE_CAP}" ]]; then
  echo "ABORT: EXPECTED_BLOCKS=${EXPECTED_BLOCKS} > DELETE_CAP=${DELETE_CAP} — a fresh upload would fail" >&2
  echo "       Pass DELETE_CAP=$(( EXPECTED_BLOCKS + 500 )) or higher to proceed." >&2
  exit 2
fi

echo "== context =="
SERVER="$(oc whoami --show-server)"
echo "user: $(oc whoami)   server: ${SERVER}"
[[ "${SERVER}" == *"${EXPECTED_SERVER_SUBSTR}"* ]] || { echo "ABORT: wrong cluster (missing '${EXPECTED_SERVER_SUBSTR}')." >&2; exit 1; }

# throwaway aws config / temp files (no global side effects)
TMPD="$(mktemp -d)"
export AWS_CONFIG_FILE="${TMPD}/awsconfig"
export AWS_SHARED_CREDENTIALS_FILE="${TMPD}/awscreds"
aws configure set default.s3.max_concurrent_requests "${PARALLEL}" 2>/dev/null || true

echo "== reading MinIO creds from secret (not printed) =="
CFG="$(oc get secret "${SECRET}" -n "${NS}" -o jsonpath="{.data.${KEY//./\\.}}" | base64 -d)"
export AWS_ACCESS_KEY_ID="$(printf '%s\n' "${CFG}" | grep -E '^[[:space:]]*access_key:' | head -1 | sed -E 's/.*access_key:[[:space:]]*//' | trim)"
export AWS_SECRET_ACCESS_KEY="$(printf '%s\n' "${CFG}" | grep -E '^[[:space:]]*secret_key:' | head -1 | sed -E 's/.*secret_key:[[:space:]]*//' | trim)"
BKT="$(printf '%s\n' "${CFG}" | grep -E '^[[:space:]]*bucket:' | head -1 | sed -E 's/.*bucket:[[:space:]]*//' | trim)"
export AWS_REGION="us-east-1" AWS_EC2_METADATA_DISABLED="true"
[[ -n "${AWS_ACCESS_KEY_ID}" && -n "${AWS_SECRET_ACCESS_KEY}" ]] || { echo "ABORT: could not read MinIO creds." >&2; exit 2; }
[[ "${BKT}" == "${MINIO_BUCKET}" ]] || { echo "ABORT: secret bucket '${BKT}' != '${MINIO_BUCKET}'." >&2; exit 2; }

echo "== port-forward svc/${SVC} ${LOCAL_PORT}:9000 =="
oc port-forward "svc/${SVC}" "${LOCAL_PORT}:9000" -n "${NS}" >"${TMPD}/minio-pf.log" 2>&1 &
PF_PID=$!
cleanup() { kill "${PF_PID}" >/dev/null 2>&1 || true; rm -rf "${TMPD}"; }
trap cleanup EXIT
export AWS_ENDPOINT_URL="http://localhost:${LOCAL_PORT}"
export AWS_MAX_ATTEMPTS="${AWS_MAX_ATTEMPTS:-5}"
READY=0
for i in $(seq 1 30); do curl -s -o /dev/null "http://localhost:${LOCAL_PORT}/minio/health/live" && { READY=1; break; }; sleep 1; done
[[ "${READY}" == "1" ]] || { echo "ABORT: MinIO port-forward never became ready; see ${TMPD}/minio-pf.log" >&2; exit 3; }

# ---- shared: scan existing blocks, reconcile, filter to demo clusters ----------
scan_demo_blocks() {  # -> writes demo ULIDs to $1 ; aborts if meta fetch incomplete
  local outfile="$1"
  aws s3 ls "s3://${MINIO_BUCKET}/" | awk '/PRE /{print $2}' | sed 's#/$##' > "${TMPD}/existing.txt" || true
  local listed; listed="$(grep -c . "${TMPD}/existing.txt" || true)"
  echo "  existing top-level blocks: ${listed}"
  : > "${outfile}"
  [[ "${listed}" -eq 0 ]] && return 0
  local METAD="${TMPD}/meta"; mkdir -p "${METAD}"
  local attempt fetched
  for attempt in 1 2 3; do
    # fetch only the metas we don't already have
    while IFS= read -r u; do [[ -n "$u" && ! -f "${METAD}/${u}.json" ]] && echo "$u"; done < "${TMPD}/existing.txt" \
      | xargs -P "${PARALLEL}" -I{} bash -c \
        'aws s3 cp "s3://'"${MINIO_BUCKET}"'/{}/meta.json" "'"${METAD}"'/{}.json" --only-show-errors 2>/dev/null || true'
    fetched="$(ls -1 "${METAD}" 2>/dev/null | grep -c '\.json$' || true)"
    echo "  meta fetch attempt ${attempt}: ${fetched}/${listed}"
    [[ "${fetched}" -ge "${listed}" ]] && break
  done
  if [[ "${fetched}" -lt "${listed}" ]]; then
    echo "ABORT: only fetched ${fetched}/${listed} block metas — cannot prove the demo set is clean." >&2
    echo "       (an undeleted demo block would overlap the new set and HALT the compactor)" >&2
    exit 4
  fi
  DEMO_CLUSTERS="${DEMO_CLUSTERS}" python3 - "${METAD}" > "${outfile}" <<'PY'
import json,os,sys
metad, demo = sys.argv[1], set(os.environ["DEMO_CLUSTERS"].split())
for fn in os.listdir(metad):
    try: d=json.load(open(os.path.join(metad,fn)))
    except Exception: continue
    if d.get("thanos",{}).get("labels",{}).get("cluster","") in demo:
        print(fn[:-5])
PY
}

delete_demo_blocks() {  # deletes ULIDs listed in $1 (parallel), respecting the cap
  local delfile="$1" n
  n="$(grep -c . "${delfile}" || true)"
  [[ "${n}" -le "${DELETE_CAP}" ]] || { echo "ABORT: demo-delete count ${n} > cap ${DELETE_CAP}." >&2; exit 4; }
  if [[ "${n}" -gt 0 ]]; then
    echo "  deleting ${n} demo blocks (parallel x${PARALLEL})"
    xargs -P "${PARALLEL}" -I{} bash -c \
      'aws s3 rm "s3://'"${MINIO_BUCKET}"'/{}/" --recursive --only-show-errors && echo "    del {}"' < "${delfile}"
  else
    echo "  no demo blocks to delete."
  fi
}

# ---- TEARDOWN: delete demo data and exit --------------------------------------
if [[ "${TEARDOWN}" == "1" ]]; then
  echo "== TEARDOWN: removing demo-cluster blocks only =="
  scan_demo_blocks "${TMPD}/del.txt"
  delete_demo_blocks "${TMPD}/del.txt"
  echo "== teardown done =="; exit 0
fi

# ---- validate local blocks ----------------------------------------------------
[[ -d "${SRC}" ]] || { echo "ABORT: source '${SRC}' not found (generate first)." >&2; exit 1; }
echo "== validating local blocks in ${SRC} =="
NEW_ULIDS=$(SRC="${SRC}" DEMO_CLUSTERS="${DEMO_CLUSTERS}" EXPECTED_BLOCKS="${EXPECTED_BLOCKS}" python3 - <<'PY'
import collections,json,os,pathlib,re,sys
src=pathlib.Path(os.environ["SRC"]); demo=set(os.environ["DEMO_CLUSTERS"].split())
expected=int(os.environ["EXPECTED_BLOCKS"])
dirs=sorted(p for p in src.iterdir() if p.is_dir()); errs=[]; per=collections.Counter()
if len(dirs)!=expected: errs.append(f"expected {expected} dirs, found {len(dirs)}")
for d in dirs:
    u=d.name
    if not re.fullmatch(r"[0-9A-HJKMNP-TV-Z]{26}",u): errs.append(f"{u}: not a ULID"); continue
    try: m=json.loads((d/"meta.json").read_text())
    except Exception as e: errs.append(f"{u}: bad meta.json ({e})"); continue
    cl=m.get("thanos",{}).get("labels",{}).get("cluster"); per[cl]+=1
    if m.get("ulid")!=u: errs.append(f"{u}: ulid mismatch")
    if cl not in demo: errs.append(f"{u}: unexpected cluster {cl!r}")
    if m.get("thanos",{}).get("source")!="blockgen": errs.append(f"{u}: source!=blockgen")
    c=m.get("compaction",{})
    if c.get("level")!=1 or c.get("sources")!=[u]: errs.append(f"{u}: not uncompacted source")
    if not (isinstance(m.get("minTime"),int) and isinstance(m.get("maxTime"),int) and m["minTime"]<m["maxTime"]): errs.append(f"{u}: bad time range")
    idx,ch=d/"index",d/"chunks"
    ok=ch.is_dir() and any(p.is_file() and p.stat().st_size>0 for p in ch.iterdir())
    if not idx.is_file() or idx.stat().st_size==0 or not ok: errs.append(f"{u}: incomplete data")
pc=expected//max(len(demo),1)
for cl in sorted(demo):
    if per[cl]!=pc: errs.append(f"{cl}: expected {pc}, found {per[cl]}")
if errs:
    for e in errs[:40]: print(f"ABORT: {e}",file=sys.stderr)
    if len(errs)>40: print(f"...and {len(errs)-40} more",file=sys.stderr)
    sys.exit(1)
for d in dirs: print(d.name)
PY
)
NEW_COUNT=$(printf '%s\n' "${NEW_ULIDS}" | grep -c . || true)
echo "  validated ${NEW_COUNT} blocks"
[[ "${NEW_COUNT}" -eq "${EXPECTED_BLOCKS}" ]] || { echo "ABORT: expected ${EXPECTED_BLOCKS}, got ${NEW_COUNT}." >&2; exit 1; }

# ---- MinIO capacity guard -----------------------------------------------------
if [[ "${SKIP_CAPACITY_CHECK}" != "1" ]]; then
  echo "== MinIO free-capacity check =="
  LOCAL_BYTES=$(( $(du -sk "${SRC}" | awk '{print $1}') * 1024 ))
  NEED=$(python3 -c "print(int(${LOCAL_BYTES}*${CAP_MARGIN}))")
  MPOD="$(oc get pods -n "${NS}" -o name | grep -iE 'minio' | grep -viE 'setup|job' | head -1 || true)"
  if [[ -n "${MPOD}" ]]; then
    DF="$(oc exec -n "${NS}" "${MPOD}" -- df -Pk 2>/dev/null || true)"
    FREEB=$(printf '%s\n' "${DF}" | awk 'NR>1 && $6 !~ /^\/(proc|sys|dev|etc|run|$)/ {print $4*1024}' | sort -rn | head -1)
    if [[ -n "${FREEB:-}" ]]; then
      echo "  upload ~$(python3 -c "print('%.1f'%(${LOCAL_BYTES}/1e9))") GB; MinIO free ~$(python3 -c "print('%.1f'%(${FREEB}/1e9))") GB (need ~$(python3 -c "print('%.1f'%(${NEED}/1e9))") GB)"
      [[ "${FREEB}" -ge "${NEED}" ]] || { echo "ABORT: insufficient MinIO capacity (set SKIP_CAPACITY_CHECK=1 to override)." >&2; exit 5; }
    else
      echo "  ⚠️  could not parse MinIO df; skipping (verify manually or SKIP_CAPACITY_CHECK=1)"
    fi
  else
    echo "  ⚠️  no minio pod found; skipping capacity check"
  fi
fi

# ---- clear pre-existing demo blocks (unless resuming) --------------------------
if [[ "${RESUME}" == "1" ]]; then
  echo "== RESUME=1: skipping deletion; two-phase sync will fill only missing files =="
else
  echo "== clearing pre-existing demo blocks (clean, halt-safe state) =="
  scan_demo_blocks "${TMPD}/del.txt"
  delete_demo_blocks "${TMPD}/del.txt"
fi

# ---- group new blocks by cluster for staged upload ----------------------------
# note: pass NEW_ULIDS via env var — pipe + heredoc compete for stdin; heredoc wins
GRP="${TMPD}/groups"; mkdir -p "${GRP}"
NEW_ULIDS="${NEW_ULIDS}" SRC="${SRC}" GRP="${GRP}" python3 - <<'PY'
import json,os,sys,pathlib
src=pathlib.Path(os.environ["SRC"]); grp=os.environ["GRP"]; g={}
for u in os.environ["NEW_ULIDS"].split():
    try: m=json.load(open(src/u/"meta.json"))
    except Exception: continue
    cl=m.get("thanos",{}).get("labels",{}).get("cluster","_unknown"); g.setdefault(cl,[]).append(u)
for cl,us in g.items(): open(os.path.join(grp,cl),"w").write("\n".join(sorted(us))+"\n")
PY

echo "== uploading ${NEW_COUNT} blocks (per-block two-phase: data first, meta.json LAST) =="
DONE=0
for cf in "${GRP}"/*; do
  cl="$(basename "${cf}")"; cn="$(grep -c . "${cf}" || true)"
  echo "  -- stage ${cl}: ${cn} blocks --"
  xargs -P "${PARALLEL}" -I{} bash -c '
    set -e   # fix: propagate S3 failures — without this a failed aws cmd is masked by echo exit 0
    u="$1"; src="$2"; bkt="$3"
    aws s3 sync "${src}/${u}/" "s3://${bkt}/${u}/" --exclude "meta.json" --only-show-errors
    aws s3 cp   "${src}/${u}/meta.json" "s3://${bkt}/${u}/meta.json" --only-show-errors
    echo "    up ${u}"
  ' _ {} "${SRC}" "${MINIO_BUCKET}" < "${cf}"
  DONE=$(( DONE + cn ))
  echo "  stage ${cl} complete — cumulative ${DONE}/${NEW_COUNT}"
  [[ "${STAGE_PAUSE_SEC}" -gt 0 && "${DONE}" -lt "${NEW_COUNT}" ]] && { echo "  pausing ${STAGE_PAUSE_SEC}s (let compaction catch up)"; sleep "${STAGE_PAUSE_SEC}"; }
done
echo "upload complete: ${DONE} blocks."

# ---- restart store-gateway shards ---------------------------------------------
STORE_PODS="$(oc get pods -n "${NS}" -o name | grep -i 'thanos-store-shard' || true)"
case "${RESTART_STORE}" in
  none)
    echo "== RESTART_STORE=none: relying on store-gw auto-sync (up to --sync-block-duration, ~3m) ==" ;;
  all)
    echo "== restarting ALL store shards at once (query outage during resync) =="
    [[ -n "${STORE_PODS}" ]] && printf '%s\n' "${STORE_PODS}" | xargs oc delete -n "${NS}" --wait=false ;;
  rolling|*)
    echo "== rolling store-gw restart (one shard at a time, wait Ready) =="
    for pod in ${STORE_PODS}; do
      name="${pod##*/}"
      echo "  restart ${name}"
      oc delete "${pod}" -n "${NS}" --wait=false || true
      for i in $(seq 1 60); do
        sleep 5
        ready="$(oc get pod "${name}" -n "${NS}" -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null || true)"
        [[ -n "${ready}" && "${ready}" != *false* && "${ready}" == *true* ]] && { echo "  ${name} Ready"; break; }
      done
    done ;;
esac

# ---- post-upload compactor halt watch (best effort) ---------------------------
if [[ "${WATCH_COMPACTOR}" == "1" ]]; then
  CPOD="$(oc get pods -n "${NS}" -o name | grep -iE 'thanos-compact' | head -1 || true)"
  if [[ -n "${CPOD}" ]]; then
    HALT="$(oc logs -n "${NS}" "${CPOD}" --tail=200 2>/dev/null | grep -iE 'halt|compaction failed' | tail -3 || true)"
    [[ -n "${HALT}" ]] && { echo "  ⚠️  compactor shows halt/failure lines — investigate:"; printf '%s\n' "${HALT}" | sed 's/^/     /'; } || echo "  compactor: no halt lines in recent logs"
  fi
fi

echo
echo "== done =="
echo "Raw data queryable in ~2-15 min (store-gw resync)."
echo "Compaction/downsampling begin ~30 min after upload (consistency-delay keys off ULID mint time)"
echo "and settle over the next few hours. Verify with:"
echo "  ! bash validate_compaction_180day.sh    (compaction/downsampling state in MinIO)"
echo "     bash validate_load.sh                (query-side correctness, full range)"
