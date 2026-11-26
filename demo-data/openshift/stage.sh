#!/usr/bin/env bash
# Copy a Linux amd64 binary into the waiting Job's PVC.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: bash $0 <namespace> <linux-amd64-binary>" >&2
  exit 2
fi

namespace=$1
binary=$2
if ! file -b "$binary" | grep -q '^ELF 64-bit .* x86-64, .*statically linked'; then
  echo "Expected a statically linked Linux amd64 binary at $binary" >&2
  exit 2
fi

digest=$(shasum -a 256 < "$binary" | cut -d ' ' -f 1)
oc -n "$namespace" exec -i job/thanosbench-pilot -c stage -- /bin/bash -ec '
  cd /work/runner
  temp=$(mktemp ./thanosbench.XXXXXX)
  trap '\''rm -f "$temp"'\'' EXIT
  cat > "$temp"
  printf "%s  %s\n" "$1" "$temp" | sha256sum --check --status
  chmod 0755 "$temp"
  mv -f "$temp" thanosbench
' stage "$digest" < "$binary"
