# Hand off: copy one AWS S3 folder to Ceph from the cluster

This procedure copies an entire AWS S3 prefix into a **new, separate** prefix
in the existing `thanos-ceph` Ceph bucket. It uses the same in-cluster network
path and existing Secrets as the successful pilot. The teammate runs the Jobs;
the manifest contains no credential values. No namespace or ObjectBucketClaim
name becomes part of an S3 object key: the destination is a bucket plus a
prefix.

**Share only this README and `folder-copy-template.yaml`.** The parent
`perf-scale-cluster/` directory also contains local `backups/` and `work/`
directories with private credentials and inventory data. Git ignores those
directories, but a ZIP or direct copy of the parent directory would include
them.

Use this template for a folder that is **not currently served by Thanos**.
Keep the new prefix outside any active Thanos prefix until its copy passes the
final check. For Thanos block data in an active prefix, use the staged
data-then-`meta.json` procedure so incomplete blocks are not published.

## Before starting

- Use `oc` logged into `https://api.vlan618.rdu2.scalelab.redhat.com:6443`.
  Run commands from the `thanosbench` repository root.
- The Job runs in `open-cluster-management-observability` and reads
  `thanos-object-storage` (`thanos.yaml`) for AWS, `thanos-ceph` for Ceph,
  and `openshift-service-ca.crt` for the internal RGW TLS certificate.
  The AWS Secret must still contain `access_key` and `secret_key`. If the
  Thanos Secret later changes to Ceph, supply a separate AWS Secret with the
  same `thanos.yaml` format and set `AWS_SECRET_NAME` to its name below.
- Choose a destination prefix that is unused and does not overlap
  `thanos/ac-test-man-1-to-20/` or other live data. Concurrent copies share
  Ceph capacity and network throughput.
- Check Ceph capacity before the real copy. The `MAX AVAIL` value is an
  estimate for the shared RGW data pool, not a bucket reservation. Compare
  it with this folder's source size **and** any other active transfers;
  leave headroom.

The [OpenShift Template](folder-copy-template.yaml) renders one Job for each
mode: `inventory`, `dry-run`, `copy`, or `check`. Each Job is read-only except
`copy`. `copy` does not delete destination objects.

```sh
oc -n open-cluster-management-observability get obc thanos-ceph
oc -n open-cluster-management-observability get secret \
  thanos-object-storage thanos-ceph -o name
oc -n open-cluster-management-observability get configmap \
  openshift-service-ca.crt -o name
```

## 1. Set the three paths and a unique Job tag

Change the example folder names before use. Prefixes are paths **inside**
their buckets, with no leading slash and a trailing slash. Keep the
destination prefix dedicated to this copy.

```sh
export RUN_TAG=ceph-copy-category-2-20261106
export SRC_BUCKET=oia-rs
export SRC_PREFIX=perf-test-shared-data/category-2/
export DST_PREFIX=team-copies/category-2/
export CEPH_BUCKET=thanos-ceph-97e777ff-c845-4595-9eea-71fc4f10ad62
export SOURCE_REGION=us-west-2
export AWS_SECRET_NAME=thanos-object-storage
```

The last three values match this cluster. Change them only if the Ceph
bucket, AWS region, or AWS Secret changes. Use a different `RUN_TAG` for
each attempt because Kubernetes Job names are immutable and must be unique.

Define this small shell function once in the same terminal:

```sh
render_job() {
  oc process --local \
    -f perf-scale-cluster/s3-folder-copy-utility/folder-copy-template.yaml \
    -p JOB_NAME="$RUN_TAG-$1" -p MODE="$1" \
    -p SOURCE_BUCKET="$SRC_BUCKET" \
    -p SOURCE_PREFIX="$SRC_PREFIX" \
    -p DEST_PREFIX="$DST_PREFIX" \
    -p CEPH_BUCKET="$CEPH_BUCKET" \
    -p SOURCE_REGION="$SOURCE_REGION" \
    -p AWS_SECRET_NAME="$AWS_SECRET_NAME" \
    -o yaml
}
```

To review any Job manifest before creating it, run
`render_job dry-run > /tmp/"$RUN_TAG"-dry-run.yaml` and inspect that file.
It has paths and Secret **names**, but no credential values.

## 2. Inventory and capacity (read-only)

```sh
render_job inventory | oc -n open-cluster-management-observability create -f -
oc -n open-cluster-management-observability logs "job/$RUN_TAG-inventory"
oc -n openshift-storage exec deploy/rook-ceph-tools -- ceph df detail
```

Wait for the inventory Job to finish if logs are not yet available. Its
`source_inventory` and `destination_inventory` JSON show object counts and
bytes. Confirm the source has the expected objects and the destination has
**zero objects**. In `ceph df detail`, inspect
`ocs-storagecluster-cephobjectstore.rgw.buckets.data` and its `MAX AVAIL`.
If the destination is not empty, check the selected path before proceeding.

## 3. Dry run, then copy

```sh
render_job dry-run | oc -n open-cluster-management-observability create -f -
oc -n open-cluster-management-observability get job "$RUN_TAG-dry-run"
oc -n open-cluster-management-observability logs "job/$RUN_TAG-dry-run" --tail=40
```

Confirm the dry-run Job shows `Complete`, the planned files and bytes match
the inventory, and it reports no errors. A Kubernetes `--dry-run` only
checks the manifest; this Job executes **rclone's** `--dry-run` against the
real S3 paths without writing objects.

Then run the real copy:

```sh
render_job copy | oc -n open-cluster-management-observability create -f -
oc -n open-cluster-management-observability get job "$RUN_TAG-copy"
oc -n open-cluster-management-observability logs "job/$RUN_TAG-copy" --tail=40
```

Poll the last two commands while it runs. A successful Job reports
`Complete` and `elapsed_seconds` in its log. The copy uses four transfers,
compares existing objects by size, fails on a size mismatch, and never
deletes destination-only objects. Do not run `rclone sync` as a shortcut;
it can remove objects from Ceph.

## 4. Verify every key and size (read-only)

```sh
render_job check | oc -n open-cluster-management-observability create -f -
oc -n open-cluster-management-observability get job "$RUN_TAG-check"
oc -n open-cluster-management-observability logs "job/$RUN_TAG-check" --tail=60
```

The `check` Job compares the entire source and destination prefixes. It must
report `Complete` and **zero differences**. It detects missing, extra, and
different-size objects. This is a key-and-size check, not a full byte-level
content comparison. Run a fresh `inventory` Job with a new `RUN_TAG` if the
source may have changed during the transfer; repeat `copy` and `check` after
reviewing any differences.

See the official [rclone copy](https://rclone.org/commands/rclone_copy/)
and [rclone check](https://rclone.org/commands/rclone_check/) references for
the transfer and comparison behavior.

For a spot check from a workstation with the existing AWS CLI profiles:

```sh
aws --profile oia-rs s3api head-object \
  --bucket "$SRC_BUCKET" --key "${SRC_PREFIX}PATH/TO/OBJECT"
aws --profile thanos-ceph s3api head-object \
  --bucket "$CEPH_BUCKET" \
  --key "${DST_PREFIX}PATH/TO/OBJECT"
```

Replace `PATH/TO/OBJECT` with the same relative key in both prefixes. These
two commands should return the same `ContentLength`. The in-cluster Jobs do
not require workstation AWS profiles.

## If a Job fails

```sh
oc -n open-cluster-management-observability describe job "$RUN_TAG-copy"
oc -n open-cluster-management-observability logs "job/$RUN_TAG-copy" --tail=100
```

Investigate the error first. To resume after a transient failure, change
`RUN_TAG` to a fresh value and run `copy` again against the **same paths**.
Completed equal-size objects are skipped. An existing object with a
different size is an error requiring investigation; do not delete or
overwrite it without checking source and destination inventories.

## Template validation

On November 6, 2026, all four modes rendered with `oc process --local`, the
embedded shell passed `sh -n`, and a rendered Job passed
`oc create --dry-run=client` in the target namespace. The OBC was `Bound`,
and the named Secrets and CA ConfigMap existed. No Job was created by these
checks. The example `category-2/` folder has not been transferred; replace
it with the team's chosen path and complete the inventory and capacity gates.
