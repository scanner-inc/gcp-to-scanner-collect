#!/usr/bin/env bash
# Integration test entrypoint: apply fixture -> pytest -> destroy.
#
# Usage:
#   ./run.sh                # full cycle with a fresh run suffix
#   KEEP=1 ./run.sh         # skip destroy (debugging); destroy later with:
#   RUN_SUFFIX=<sfx> DESTROY_ONLY=1 ./run.sh
#
# Requires: env.tfvars (copy env.tfvars.example), terraform >= 1.9, python3,
# gcloud auth (CLI + ADC) and a valid AWS SSO session for the profile in
# env.tfvars.
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f env.tfvars ]]; then
  echo "ERROR: env.tfvars not found. Copy env.tfvars.example and fill in your test environment." >&2
  exit 1
fi

# openssl (not tr|head over /dev/urandom): the pipeline version dies with
# SIGPIPE/141 under `set -o pipefail` when head closes the pipe early
RUN_SUFFIX="${RUN_SUFFIX:-$(openssl rand -hex 3)}"
VAR_FLAGS=(-var-file="$(pwd)/env.tfvars" -var "run_suffix=${RUN_SUFFIX}")
AWS_PROFILE_VAL="$(sed -n 's/^aws_profile[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' env.tfvars)"
if [[ -z "${AWS_PROFILE_VAL}" ]]; then
  echo "ERROR: could not read aws_profile from env.tfvars (expected a line like: aws_profile = \"my-profile\")" >&2
  exit 1
fi
KEEP="${KEEP:-0}"
DESTROY_ONLY="${DESTROY_ONLY:-0}"

echo "=== Integration test run: suffix=${RUN_SUFFIX} ==="

check_leftovers() {
  # T3: after destroy, nothing bearing our run suffix may remain
  echo "--- Checking for leftover resources (suffix ${RUN_SUFFIX}) ---"
  local leftovers=0
  local gcs_left aws_left
  gcs_left="$(gcloud storage buckets list --format='value(name)' 2>/dev/null | grep "${RUN_SUFFIX}" || true)"
  aws_left="$(aws s3api list-buckets --profile "${AWS_PROFILE_VAL}" \
    --query "Buckets[?contains(Name, \`${RUN_SUFFIX}\`)].Name" --output text 2>/dev/null || true)"
  if [[ -n "${gcs_left}" ]]; then echo "LEFTOVER GCS buckets: ${gcs_left}"; leftovers=1; fi
  if [[ -n "${aws_left}" ]]; then echo "LEFTOVER S3 buckets: ${aws_left}"; leftovers=1; fi
  if [[ "${leftovers}" == "1" ]]; then
    echo "ERROR: destroy left resources behind (see above)" >&2
    return 1
  fi
  echo "No leftovers."
}

destroy() {
  echo "--- Destroying fixture (suffix ${RUN_SUFFIX}) ---"
  terraform -chdir=fixture destroy -auto-approve -input=false "${VAR_FLAGS[@]}"
  check_leftovers
}

if [[ "${DESTROY_ONLY}" == "1" ]]; then
  destroy
  exit 0
fi

cleanup() {
  local exit_code=$?
  if [[ "${KEEP}" == "1" ]]; then
    echo "KEEP=1: leaving fixture deployed. Destroy later with:"
    echo "  RUN_SUFFIX=${RUN_SUFFIX} DESTROY_ONLY=1 ./run.sh"
  else
    destroy || exit_code=1
  fi
  exit "${exit_code}"
}
trap cleanup EXIT

# --- Python environment ---
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install -q -r requirements.txt

# --- Preflight ---
echo "--- Preflight ---"
terraform version -json | python3 -c 'import json,sys; v=json.load(sys.stdin)["terraform_version"]; print(f"terraform {v}")'
gcloud auth application-default print-access-token >/dev/null || { echo "GCP ADC missing: run 'gcloud auth application-default login'"; exit 1; }
aws sts get-caller-identity --profile "${AWS_PROFILE_VAL}" >/dev/null || { echo "AWS session invalid: run 'aws sso login --profile ${AWS_PROFILE_VAL}'"; exit 1; }
GCP_PROJECT_VAL="$(sed -n 's/^project_id[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' env.tfvars)"
if [[ -z "${GCP_PROJECT_VAL}" ]]; then
  echo "ERROR: could not read project_id from env.tfvars (expected a line like: project_id = \"my-test-project\")" >&2
  exit 1
fi
# Google client libraries bill requests to the ADC quota project (sent as
# x-goog-user-project), NOT the resource's project. If the ADC quota project
# has no billing account, every GCS call 403s with a misleading "billing
# account for the owning project is disabled in state absent". Pin it to the
# test project so tests bill the same project that owns the resources.
export GOOGLE_CLOUD_QUOTA_PROJECT="${GCP_PROJECT_VAL}"
BILLING_ENABLED="$(gcloud billing projects describe "${GCP_PROJECT_VAL}" --format='value(billingEnabled)' 2>/dev/null || echo unknown)"
if [[ "${BILLING_ENABLED}" != "True" ]]; then
  echo "ERROR: billing is not enabled on GCP project ${GCP_PROJECT_VAL} (billingEnabled=${BILLING_ENABLED})." >&2
  echo "Resource creation will fail with 403s. Fix billing before running." >&2
  exit 1
fi

# --- Deploy ---
echo "--- terraform apply (this takes ~10-15 min; Cloud Functions builds dominate) ---"
terraform -chdir=fixture init -input=false -upgrade=false
terraform -chdir=fixture apply -auto-approve -input=false "${VAR_FLAGS[@]}"

# --- Test ---
echo "--- pytest ---"
pytest -v --tb=short "$@"
