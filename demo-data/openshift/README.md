# Run the generator on OpenShift

The Job uses the public AWS CLI image and runs the repository's
`generate_and_publish.sh` script. It builds the same blocks as the laptop runner.
The PVC keeps the binary, checkpoints, logs, and pending uploads across Job runs.

## Single-cluster pilot

Use `oc` with the intended cluster context and a dedicated namespace. Have the
namespace owner provision `thanosbench-aws` as a Secret with a `credentials` key
containing an AWS shared credentials file with an `[oia-rs]` profile. The
credentials need STS identity access and S3 list, read, write, and delete access
for the pilot. Use a session that covers the expected Job runtime.

From the repository root, build for the worker architecture and create the pilot
using a fresh S3 prefix and a fresh PVC. The manifest defaults to the RDU2 Ceph
RBD storage class. Select the appropriate storage class before applying it to
another cluster. The Linux build was tested with Go 1.25.1. The Job requests
eight CPUs and 32 GiB of memory and sets a 16 GiB Go memory target within its
64 GiB container limit.

```bash
NS=thanosbench-pilot
TEST_ROOT=thanosbench/your-name-tests
PILOT_PREFIX="$TEST_ROOT/short-6w"

CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath \
  -o /tmp/thanosbench-linux-amd64 ./cmd/thanosbench

oc -n "$NS" create configmap thanosbench-runner \
  --from-file=demo-data/generate_and_publish.sh
PILOT_ENV=$(mktemp)
cat demo-data/openshift/pilot.env > "$PILOT_ENV"
printf 'SHARED_PREFIX=%s\n' "$PILOT_PREFIX" >> "$PILOT_ENV"
oc -n "$NS" create configmap thanosbench-settings --from-env-file="$PILOT_ENV"
rm -f "$PILOT_ENV"
oc -n "$NS" create -f demo-data/openshift/job.yaml
```

Once the `stage` init container is running, copy and verify the binary on the
PVC. The generator starts as soon as the transfer succeeds.

```bash
oc -n "$NS" wait --for='jsonpath={.status.initContainerStatuses[0].state.running.startedAt}' \
  --timeout=2m pod -l job-name=thanosbench-pilot
bash demo-data/openshift/stage.sh "$NS" /tmp/thanosbench-linux-amd64
oc -n "$NS" wait --for=condition=Ready --timeout=2m pod -l job-name=thanosbench-pilot
oc -n "$NS" logs -f job/thanosbench-pilot -c generate
```

The pilot generates 54 blocks for one cluster over six weeks at 160,264 series
per block. Compare the `generated in` timings and the elapsed time through the
final S3 manifest. The short run includes ramp-up and the final upload drain.

## Full 26-week pilot

Use a sibling folder such as `$TEST_ROOT/full-26w-7way` for the full pilot.
Set `WEEKS=26`, `GEN_PARALLEL=7`, and `MAX_INFLIGHT=7` in its configuration.
Each generation worker keeps `WORKERS=8`. The seven-way RDU2 Job requests 56
CPUs and 224 GiB of RAM, with a 256 GiB container memory limit. Give the test
its own Job and settings ConfigMap and its own `WORK` directory on the PVC.

`GEN_PARALLEL` defaults to one. With parallel generation, the runner bounds
active generators and uploads separately. It stages at most `GEN_PARALLEL +
MAX_INFLIGHT` active cluster-weeks, plus any failed uploads retained for retry.
Keep the same S3 folder and work directory when resuming an interrupted test.

Set `GEN_DIRECT=1` to generate from the same profile in one process. This
requires a binary built with `block gen --profile` support. For a benchmark
comparison, use `$TEST_ROOT/full-26w-direct-7way` and a separate `WORK` directory.

## Prepared 100-cluster run

`full-1-100.yaml` declares an 80 GiB PVC and a suspended Job for clusters
`ac-test-man-1` through `ac-test-man-100`. `full-1-100.env` pins the 26-week
window with `BASE_EPOCH_OVERRIDE=1792800000`, 18 direct generators and 18 upload
slots. The Job requests 72 CPUs and 224 GiB of RAM with a 256 GiB memory limit,
matching the 18-slot pilot. The PVC has room for the combined generation and
upload queues and blocks retained for retry. Blocks use the flat layout for the
downstream hub loader.

Create the `thanosbench-full-1-100-settings` and `thanosbench-full-1-100-runner`
ConfigMaps from `full-1-100.env` and `generate_and_publish.sh`, respectively.
Stage the verified Linux binary at `/work/runner/thanosbench` on the new claim.
Refresh the dedicated AWS Secret with `refresh-full-1-100-credentials.sh`,
passing the intended `oc` context and namespace. The helper tries a prefix-scoped
session by default. `AWS_SESSION_MODE=profile` uses the source profile's
permissions and requires approval for that wider access. The startup check
requires at least eight hours left on the session.

The publisher pauses new generation when three weeks have failed uploads and
drains the work already in flight. It retries the saved blocks in three bounded
rounds with 30-second and 60-second waits before rounds two and three. It resumes
generation after the backlog clears or exits with checkpoints on the PVC if
failures persist. Preserve the PVC and S3 folder when restarting the Job.

## Resume an existing run

For a migration, stop the original runner and wait for its uploads to exit.
Transfer the entire original `WORK` directory into `/work/data` on a fresh PVC
before staging the executable. Set `thanosbench-settings` to the original
cluster list, anchor, duration, series settings, and exact S3 destination.
Keep one writer for that destination. The runner reads completed weeks and
pending block IDs from the transferred state. For a Job retry on the same PVC,
keep the existing settings and recreate only the Job after the previous pod
has terminated.
