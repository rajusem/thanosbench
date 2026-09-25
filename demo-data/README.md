# 180-Day Right-Sizing Demo Data Pipeline

Scripts for generating, uploading, and validating synthetic ACM right-sizing metrics
(180 days) into a MultiClusterObservability (MCO) hub's Thanos/MinIO object store.

See `180DAY_DEMO_DATA_PIPELINE.md` for full architecture, timing expectations, and
multi-perspective review findings. See `SHARED_S3_PLAN.md` for the multi-team S3
distribution design.

---

## Prerequisites

| Tool | Version |
|---|---|
| `oc` | logged in to the target hub cluster |
| `aws` CLI | configured (creds are read from the MCO secret; no `~/.aws` needed) |
| `python3` | 3.8+ |
| `thanosbench` binary | built from this repo (`make build`; on recent macOS see the build note in `RIGHT_SIZING.md`) |

---

## Required environment variable

Every script in this folder enforces a **cluster safety guard** — it reads the current
`oc whoami --show-server` URL and aborts if it does not contain `EXPECTED_SERVER_SUBSTR`.
This prevents accidentally running demo-data operations against the wrong cluster.

**You must set this before running any script:**

```bash
export EXPECTED_SERVER_SUBSTR="<substring of your hub's API server URL>"

# Example — copy the unique part of your cluster URL:
#   oc whoami --show-server
#   https://api.obsint-sno-4xlarge-5-myhub.llc.devcluster.openshift.com:6443
#                              ^^^^^^^^^^^^^^^^^
export EXPECTED_SERVER_SUBSTR="obsint-sno-4xlarge-5-myhub"
```

If unset, every script aborts immediately with:
```
ABORT: EXPECTED_SERVER_SUBSTR is empty
```

---

## Scripts

| Script | Role | Key env vars |
|---|---|---|
| `generate_180day.sh` | Generate blocks to local disk + write run-manifest | `CLUSTERS`, `NUM_NAMESPACES`, `NUM_WORKLOADS`, `NUM_PODS`, `NUM_POD_METRICS`, `NUM_EXTRA_METRICS`, `WEEKS`, `FORCE`, `DRY_RUN`, `OUT` |
| `preflight_180day.sh` | READ-ONLY go/no-go checks (retention, capacity, compactor) | `MIN_RETENTION_DAYS` (182), `CAP_MARGIN` |
| `expand_minio_pvc.sh` | One-time: replace MinIO emptyDir → 500Gi gp3-csi PVC | `PVC_SIZE` (500Gi) |
| `upload_180day_batched.sh` | Upload local blocks → MinIO + trigger store-gw resync | `RESUME`, `TEARDOWN`, `RESTART_STORE`, `STAGE_PAUSE_SEC`, `PARALLEL` |
| `validate_compaction_180day.sh` | Assert compaction/downsampling in MinIO (re-runnable) | `REQUIRE_SETTLED`, `GAP_THRESH_H`, `MANIFEST` |
| `validate_load.sh` | Query-side correctness checks via port-forward | `DAYS` (182 or 14 for trial), `STEP`, `SVC`, `MANIFEST` |

Exit codes for validators: **0 = pass, 1 = data problem, 2 = environment/not-ready**.

---

## Runbook

```bash
# 0. Set the required guard variable
export EXPECTED_SERVER_SUBSTR="<your-cluster-substring>"

# 1. GENERATE — writes blocks to ./gen-180day-flat/ + gen-180day.manifest.json
#    CLUSTERS defaults to 3 clusters; set it for more. NUM_POD_METRICS/NUM_EXTRA_METRICS
#    add filler for the other metrics a real cluster sends (see RIGHT_SIZING.md).
#    The settings are passed with `env` instead of `export`, so they can't leak into
#    other scripts (e.g. run_parallel.sh) run later in the same shell.
#    Needs ~8.2 GB RAM; ~90 s and ~0.92 GB of disk per cluster-week.
#    20 clusters = category 1; use 100 or 300 for categories 2 and 3.
GEN_ENV=(CLUSTERS="$(seq -f 'ac-test-man-%g' 1 20 | tr '\n' ' ')"
         NUM_NAMESPACES=100 NUM_WORKLOADS=10 NUM_PODS=3 NUM_POD_METRICS=20 NUM_EXTRA_METRICS=4)

#    Trial (20 clusters × 2 weeks; ~1h, ~40 GB):
env "${GEN_ENV[@]}" WEEKS=2 bash generate_180day.sh

#    Full 180-day (20 clusters × 26 weeks; ~13h, ~0.5 TB):
env "${GEN_ENV[@]}" WEEKS=26 bash generate_180day.sh

# 2. PREFLIGHT — read-only; must print "GO" before uploading
!  bash preflight_180day.sh

# 3. (one-time) Expand MinIO if it is using an emptyDir volume. Size it for the hub
#    footprint, not the upload: the compactor's 5m/1h copies make it ~5.9x the
#    upload. The default 500Gi fits the trial; the full 20-cluster run needs ~4Ti.
!  bash expand_minio_pvc.sh                  # trial
!  PVC_SIZE=4Ti bash expand_minio_pvc.sh     # full 20-cluster run

# 4. UPLOAD — uploads cluster-by-cluster; resumes cleanly after a port-forward drop
!  STAGE_PAUSE_SEC=60 bash upload_180day_batched.sh
!  RESUME=1 STAGE_PAUSE_SEC=60 bash upload_180day_batched.sh   # resume after drop

# 5. VALIDATE COMPACTION — poll until all tiers settle: ~1h for the trial, an estimated
#    5–8h for the full 20-cluster run with filler (starts ~30 min after upload)
!  bash validate_compaction_180day.sh             # repeat to watch progress
!  REQUIRE_SETTLED=1 bash validate_compaction_180day.sh   # final assertion

# 6. VALIDATE LOAD — query-side checks (full range)
   DAYS=14 bash validate_load.sh     # trial window
   bash validate_load.sh             # full 182-day window

# Teardown — deletes demo blocks by cluster label (real tenant data is safe)
!  TEARDOWN=1 bash upload_180day_batched.sh
```

Commands prefixed with `!` mutate the cluster and should be run by the operator
(type `! <command>` in the Claude Code prompt to run them in-session).

### Categories 2 and 3 (100 / 300 clusters)

Same settings with `CLUSTERS` set to 100 or 300 names. Plan for (recommended filler,
26 weeks, one generating machine):

| | 20 clusters | 100 clusters | 300 clusters |
|---|---|---|---|
| Blocks | 4,680 | 23,400 | 70,200 |
| Upload (raw) | ~0.5 TB | ~2.4 TB | ~7.2 TB |
| On the hub after downsampling | ~3 TB | ~15 TB | ~45 TB |
| Generation time | ~13h | ~65h | ~195h |

- Raise `DELETE_CAP` for `upload_180day_batched.sh` above the block count (default 5000).
- The later stages read one run-manifest, so splitting generation across machines
  needs the manifests merged first (not supported by these scripts yet).

---

## What NOT to commit

The following are generated at runtime and must not be added to git:

```
gen-180day-flat/          # generated TSDB blocks (~40 GB for the 2-week trial with filler)
gen-3day-flat/
gen-180day.manifest.json  # run manifest (cluster-specific)
*.backup.*.yaml           # secret backups
```

Add these to `.gitignore` if you work from this directory directly.
