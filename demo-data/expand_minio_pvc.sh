#!/usr/bin/env bash
# LOCAL OPS SCRIPT (untracked, do NOT commit). Run it yourself:
#   ! bash expand_minio_pvc.sh
#
# Replaces MinIO's emptyDir volume with a 500 Gi gp3-csi PVC so the
# thanos bucket has enough headroom for the 180-day demo data upload.
#
# EFFECT:
#   * Creates PVC "minio-data" (500 Gi, gp3-csi, RWO)
#   * Patches the MinIO Deployment to use it instead of emptyDir
#   * MinIO pod restarts; starts with an EMPTY /data
#   * Existing emptyDir contents (~973 MB of demo blocks) are LOST
#     (expected — we are regenerating them)
#   * Thanos-receive will resume uploading new blocks to the PVC
#     automatically; no receive reconfiguration needed
#
# CONSTRAINTS:
#   * Only touches the MinIO Deployment and creates one PVC
#   * Does NOT change thanos-object-storage secret or any Thanos config
#   * Does NOT restart store-gateway or compactor (they auto-sync)
set -euo pipefail

NS="open-cluster-management-observability"
PVC_NAME="minio-data"
PVC_SIZE="${PVC_SIZE:-500Gi}"
SC="gp3-csi"
EXPECTED_SERVER_SUBSTR="${EXPECTED_SERVER_SUBSTR:-}"

echo "== context =="
SERVER="$(oc whoami --show-server)"
echo "user:   $(oc whoami)"
echo "server: ${SERVER}"
[[ "${SERVER}" == *"${EXPECTED_SERVER_SUBSTR}"* ]] || {
  echo "ABORT: wrong cluster (server missing '${EXPECTED_SERVER_SUBSTR}')." >&2; exit 1
}

echo
echo "== current MinIO volume (confirming emptyDir) =="
CURRENT_VOL="$(oc get deployment minio -n "${NS}" \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="data")]}')"
echo "  ${CURRENT_VOL}"
if ! echo "${CURRENT_VOL}" | grep -q 'emptyDir'; then
  echo "ABORT: MinIO 'data' volume is not an emptyDir — already patched or unexpected config." >&2
  exit 1
fi

echo
echo "== current MinIO data usage (will be lost after patch) =="
MPOD="$(oc get pods -n "${NS}" -o name | grep 'minio' | grep -viE 'setup|job' | head -1 | sed 's|pod/||')"
oc exec -n "${NS}" "${MPOD}" -- du -sh /data/ 2>/dev/null || true

echo
echo "== creating PVC ${PVC_NAME} (${PVC_SIZE}, ${SC}) =="
if oc get pvc "${PVC_NAME}" -n "${NS}" &>/dev/null; then
  echo "  PVC already exists:"
  oc get pvc "${PVC_NAME}" -n "${NS}"
else
  oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NS}
  labels:
    app: minio
    purpose: demo-data-expansion
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: ${PVC_SIZE}
  storageClassName: ${SC}
EOF
  echo "  PVC created."
fi

echo
echo "== PVC binding mode: WaitForFirstConsumer (gp3-csi/AWS EBS) =="
echo "   PVC stays Pending until a pod claims it — patching Deployment next triggers the bind."

echo
echo "== patching MinIO Deployment: emptyDir -> PVC ${PVC_NAME} =="
oc patch deployment minio -n "${NS}" --type=json -p="[
  {
    \"op\": \"replace\",
    \"path\": \"/spec/template/spec/volumes/0\",
    \"value\": {
      \"name\": \"data\",
      \"persistentVolumeClaim\": {\"claimName\": \"${PVC_NAME}\"}
    }
  }
]"
echo "  patch applied — MinIO pod rolling restart in progress"

echo
echo "== waiting for MinIO rollout =="
oc rollout status deployment/minio -n "${NS}" --timeout=120s

echo
echo "== verifying PVC is now Bound (pod claimed it during rollout) =="
PVC_STATUS="$(oc get pvc "${PVC_NAME}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
echo "  PVC ${PVC_NAME}: ${PVC_STATUS}"
[[ "${PVC_STATUS}" == "Bound" ]] || echo "  ⚠️  still not Bound — check: oc describe pvc ${PVC_NAME} -n ${NS}"

echo
echo "== verifying MinIO is up and /data is the PVC =="
NEWPOD="$(oc get pods -n "${NS}" -o name | grep 'minio' | grep -viE 'setup|job' | head -1 | sed 's|pod/||')"
oc exec -n "${NS}" "${NEWPOD}" -- df -h /data 2>/dev/null
oc exec -n "${NS}" "${NEWPOD}" -- ls /data/ 2>/dev/null && echo "  /data is empty (expected)" || true

echo
echo "== done =="
echo "MinIO now uses PVC ${PVC_NAME} (${PVC_SIZE})."
echo "The old emptyDir contents (~973 MB demo blocks) are gone — regenerate with generate_180day.sh."
echo "Thanos-receive will resume uploading new blocks automatically."
echo
echo "Next steps:"
echo "  bash generate_180day.sh          (generate trial or full run locally)"
echo "  ! bash preflight_180day.sh       (re-run preflight — capacity check will now pass)"
echo "  ! bash upload_180day_batched.sh  (upload to MinIO)"
