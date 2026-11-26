#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: bash $0 <oc-context> <namespace>" >&2
  exit 2
fi

dir=$(cd "$(dirname "$0")" && pwd)
source "$dir/full-1-100.env"
oc_() { oc --context="$1" -n "$2" "${@:3}"; }
context=$1
namespace=$2
origin_profile=${ORIGIN_AWS_PROFILE:-oia-rs}
session_mode=${AWS_SESSION_MODE:-scoped}
umask 077
temp=$(mktemp -d)
check_key="$SHARED_PREFIX/.auth-check-$(basename "$temp")"
uploaded=0

scoped_aws() {
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
    AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE="$temp/credentials" \
    aws --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION" --no-cli-pager "$@"
}

cleanup() {
  if (( uploaded )); then
    scoped_aws s3api delete-object --bucket "$BUCKET" --key "$check_key" >/dev/null ||
      echo "Check object cleanup failed: s3://$BUCKET/$check_key" >&2
  fi
  rm -rf "$temp"
}
trap cleanup EXIT

python3 - "$BUCKET" "$SHARED_PREFIX" <<'PY' > "$temp/policy.json"
import json, sys
bucket, prefix = sys.argv[1:]
resource = f"arn:aws:s3:::{bucket}"
json.dump({"Version": "2012-10-17", "Statement": [
    {"Effect": "Allow", "Action": "s3:ListBucket", "Resource": resource,
     "Condition": {"StringLike": {"s3:prefix": [prefix, prefix + "/*"]}}},
    {"Effect": "Allow", "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject",
      "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"], "Resource": f"{resource}/{prefix}/*"},
]}, sys.stdout)
PY

case "$session_mode" in
  scoped)
    aws --profile "$origin_profile" --region "$AWS_REGION" --no-cli-pager sts get-federation-token \
      --name thanosbench-full-1-100 --duration-seconds 43200 --policy "file://$temp/policy.json" > "$temp/session.json"
    ;;
  profile)
    aws --profile "$origin_profile" --region "$AWS_REGION" --no-cli-pager sts get-session-token \
      --duration-seconds 43200 > "$temp/session.json"
    ;;
  *) echo "AWS_SESSION_MODE must be scoped or profile" >&2; exit 2 ;;
esac

python3 -c '
import datetime, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
c = json.load(sys.stdin)["Credentials"]
expiry = datetime.datetime.fromisoformat(c["Expiration"].replace("Z", "+00:00"))
if (expiry - datetime.datetime.now(datetime.timezone.utc)).total_seconds() < int(sys.argv[3]):
    sys.exit("AWS returned a session shorter than the configured minimum.")
(root/"expires_at").write_text(str(int(expiry.timestamp())) + "\n")
keys = (("AccessKeyId", "aws_access_key_id"), ("SecretAccessKey", "aws_secret_access_key"), ("SessionToken", "aws_session_token"))
(root/"credentials").write_text("[" + sys.argv[2] + "]\n" + "".join(f"{name}={c[key]}\n" for key, name in keys))
print("AWS session expires " + expiry.isoformat())
' "$temp" "$AWS_PROFILE_NAME" "$AWS_MIN_SESSION_SECONDS" < "$temp/session.json"

scoped_aws sts get-caller-identity >/dev/null
scoped_aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$SHARED_PREFIX/" --no-paginate --max-keys 1 >/dev/null
printf 'thanosbench credential check\n' > "$temp/check"
scoped_aws s3api put-object --bucket "$BUCKET" --key "$check_key" --body "$temp/check" >/dev/null
uploaded=1
scoped_aws s3api head-object --bucket "$BUCKET" --key "$check_key" >/dev/null
scoped_aws s3api delete-object --bucket "$BUCKET" --key "$check_key" >/dev/null
uploaded=0

oc_ "$context" "$namespace" create secret generic thanosbench-full-1-100-aws \
  --from-file="credentials=$temp/credentials" --from-file="expires_at=$temp/expires_at" --dry-run=client -o yaml |
  oc_ "$context" "$namespace" apply --server-side --field-manager=thanosbench-full-1-100 -f -
