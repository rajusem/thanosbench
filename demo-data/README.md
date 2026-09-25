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
| `thanosbench` binary | built from this repo (`make build`) |

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
| `generate_180day.sh` | Generate blocks to local disk + write run-manifest | `NUM_NAMESPACES`, `NUM_WORKLOADS`, `NUM_PODS`, `WEEKS`, `FORCE`, `DRY_RUN`, `OUT` |
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
#    Trial (20 clusters × 2 weeks, ~17 min):
NUM_NAMESPACES=100 NUM_WORKLOADS=10 NUM_PODS=3 WEEKS=2 bash generate_180day.sh

#    Full 180-day (20 clusters × 26 weeks, ~3.5h):
NUM_NAMESPACES=100 NUM_WORKLOADS=10 NUM_PODS=3 WEEKS=26 bash generate_180day.sh

# 2. PREFLIGHT — read-only; must print "GO" before uploading
!  bash preflight_180day.sh

# 3. (one-time) Expand MinIO if it is using an emptyDir volume
!  bash expand_minio_pvc.sh

# 4. UPLOAD — uploads cluster-by-cluster; resumes cleanly after a port-forward drop
!  STAGE_PAUSE_SEC=60 bash upload_180day_batched.sh
!  RESUME=1 STAGE_PAUSE_SEC=60 bash upload_180day_batched.sh   # resume after drop

# 5. VALIDATE COMPACTION — poll over 1–6h until all tiers settle
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

---

## What NOT to commit

The following are generated at runtime and must not be added to git:

```
gen-180day-flat/          # generated TSDB blocks (~16 GB for trial)
gen-3day-flat/
gen-180day.manifest.json  # run manifest (cluster-specific)
*.backup.*.yaml           # secret backups
```

Add these to `.gitignore` if you work from this directory directly.
