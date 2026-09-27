# 180-Day Right-Sizing Demo Data Pipeline

Scripts for generating, publishing, and validating synthetic ACM right-sizing metrics
(180 days) for a MultiClusterObservability (MCO) hub whose Thanos uses an **S3 bucket**
as object store. Blocks are generated one cluster-week at a time and uploaded to a
shared S3 prefix while the next one generates (a few GB of local disk), then copied
server-side into the hub's own prefix. Nothing goes through a PVC or in-cluster MinIO.

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
| `generate_and_publish.sh` | Generate one cluster-week at a time, upload to S3 while the next generates, server-side copy to the hub prefix, resumable; writes `manifest.json` last | `CLUSTERS`, `WEEKS`, `NUM_*`, `BUCKET`, `SHARED_PREFIX`, `HUB_PREFIX`, `AWS_PROFILE_NAME`, `MAX_INFLIGHT`, `WORK`, `DRY_RUN` |
| `configure_hub_s3.sh` | Point the hub's `thanos-object-storage` Secret at `s3://BUCKET/PREFIX` and restart the Thanos pods; `rollback` restores the backup | `EXPECTED_SERVER_SUBSTR`, `BUCKET`, `PREFIX`, `REGION`, `AWS_PROFILE_NAME` |
| `preflight_180day.sh` | READ-ONLY go/no-go checks (retention, compactor; capacity only for MinIO) | `MIN_RETENTION_DAYS` (182) |
| `validate_compaction_180day.sh` | Assert compaction/downsampling in the hub's object store (S3 or MinIO, read from the Secret) | `REQUIRE_SETTLED`, `GAP_THRESH_H`, `MANIFEST` |
| `validate_load.sh` | Query-side correctness checks via port-forward | `DAYS` (182 or 14 for trial), `STEP`, `SVC`, `MANIFEST` |
| `generate_180day.sh` | Legacy: generate everything to local disk first (needs the whole dataset's disk) | `CLUSTERS`, `NUM_*`, `WEEKS`, `OUT` |
| `upload_180day_batched.sh`, `expand_minio_pvc.sh` | Legacy, **in-cluster MinIO only**; not used in the S3 flow | |

Exit codes for validators: **0 = pass, 1 = data problem, 2 = environment/not-ready**.

---

## Runbook

```bash
# 0. Guard variable (a substring of the hub's API URL) and AWS profile for the bucket
export EXPECTED_SERVER_SUBSTR="<your-cluster-substring>"
export AWS_PROFILE_NAME=oia-rs

# 1. POINT THE HUB AT S3 (one-time per hub). Backs up the current Secret, writes the
#    S3 config (bucket/prefix, keys from the AWS profile) and restarts the Thanos pods.
#    Receive then uploads to this prefix too. `rollback` restores the backup.
!  BUCKET=oia-rs PREFIX=jdj64-thanos bash configure_hub_s3.sh

# 2. PREFLIGHT — read-only; must print "GO" (retention >= 182d, compactor healthy)
!  bash preflight_180day.sh

# 3. GENERATE + PUBLISH — one cluster-week at a time (~90 s, ~0.94 GB), uploaded to the
#    shared prefix while the next one generates, then copied server-side into the hub
#    prefix; ~3 GB of local disk, resumable (re-run the same command). Needs ~8.2 GB RAM.
#    NUM_POD_METRICS and NUM_CLUSTER_METRICS add filler for the other metrics a real
#    cluster sends (see RIGHT_SIZING.md). 20 clusters = category 1; 100 / 300 = 2 / 3.
#    Use a new SHARED_PREFIX (and WORK dir) per dataset; the prefix must be empty. Write
#    the date into SHARED_PREFIX by hand: a resume must re-run the exact same command.
GEN_ENV=(CLUSTERS="$(seq -f 'ac-test-man-%g' 1 20 | tr '\n' ' ')"
         NUM_NAMESPACES=100 NUM_WORKLOADS=10 NUM_PODS=3 NUM_POD_METRICS=20 NUM_CLUSTER_METRICS=154
         BUCKET=oia-rs HUB_PREFIX=jdj64-thanos)

#    Plan only:
env "${GEN_ENV[@]}" WEEKS=26 SHARED_PREFIX=rs-perf-shared/20c-180d-2026-09-29 DRY_RUN=1 bash generate_and_publish.sh
#    Trial (20 clusters × 2 weeks; ~1h):
env "${GEN_ENV[@]}" WEEKS=2  SHARED_PREFIX=rs-perf-shared/20c-14d-2026-09-29 WORK=./gen-work-trial bash generate_and_publish.sh
#    Full 180 days (20 clusters × 26 weeks; ~15h from a laptop, upload-bound; ~0.5 TB uploaded):
env "${GEN_ENV[@]}" WEEKS=26 SHARED_PREFIX=rs-perf-shared/20c-180d-2026-09-29 WORK=./gen-work-180d bash generate_and_publish.sh

# 4. VALIDATE COMPACTION — reads the object store named in the hub's Secret; run it after
#    step 3 has finished (blocks still being uploaded show up as incomplete) and poll until
#    all tiers settle (the compactor starts ~30 min after upload; hours for 180 days)
!  bash validate_compaction_180day.sh             # repeat to watch progress
!  REQUIRE_SETTLED=1 bash validate_compaction_180day.sh   # final assertion

# 5. VALIDATE LOAD — query-side checks (full range) through the query-frontend
   DAYS=14 bash validate_load.sh     # trial window
   bash validate_load.sh             # full 182-day window

# Teardown — remove the dataset from the hub prefix (the shared copy stays). This deletes
#    EVERYTHING under the hub prefix, including the blocks Receive and Rule uploaded since
#    the hub was pointed at it: fine for a private test hub, not for one with real tenants.
   aws s3 rm --recursive s3://oia-rs/jdj64-thanos/ --profile oia-rs
```

Other teams load the same dataset by copying `s3://oia-rs/<SHARED_PREFIX>/<ULID>/` blocks
server-side into their own hub prefix (`aws s3 cp --recursive`, `meta.json` last) and
pointing their hub at it with `configure_hub_s3.sh`. Never point a hub at the shared
prefix itself: its compactor would rewrite the shared copy.

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
| Generation time (one machine) | ~13h (~15h from a laptop, upload-bound) | ~65h | ~195h |

- Local disk is no longer the limit (~3 GB at any time); upload bandwidth is. From a
  laptop (~10 MB/s measured) the upload is slightly slower than generation, so category 1
  takes ~15h instead of ~13h; `MAX_INFLIGHT=3` is the right setting (2 costs ~4h more, 6
  saves under 1h). For categories 2 and 3 run `generate_and_publish.sh` on a machine in the
  bucket's region (an EC2 instance in us-west-2): in-region the upload is not a factor and
  generation is the only cost. Ctrl-C stops the run; re-run the same command to resume.
- One dataset must be produced by one `generate_and_publish.sh` run (one machine, one
  `WORK` dir): the script owns its `SHARED_PREFIX` and checks the final block count
  against its own plan. Splitting a dataset across machines is not supported.

---

## What NOT to commit

The following are generated at runtime and must not be added to git:

```
gen-work*/                # generate_and_publish.sh state, logs and in-flight blocks
gen-180day-flat/          # legacy generate_180day.sh output (~40 GB for the 2-week trial with filler)
gen-3day-flat/
gen-180day.manifest.json  # run manifest (cluster-specific)
*.backup.*.yaml           # secret backups
```

Add these to `.gitignore` if you work from this directory directly.
