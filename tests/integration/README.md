# Integration Tests

End-to-end tests that deploy both pipeline modules into real GCP + AWS test
accounts and verify log/object flow, filtering, data integrity, and teardown.
See `../../docs/INTEGRATION_TEST_PLAN.md` for the full plan; this directory
implements Phase 1.

## Setup (once)

1. `cp env.tfvars.example env.tfvars` and fill in your **dedicated test**
   GCP project / AWS account. `env.tfvars` is gitignored - environment IDs
   never enter the repo.
2. Authenticate:
   - `gcloud auth login` and `gcloud auth application-default login`
   - `aws sso login --profile <your-test-profile>`

## Run

```bash
./run.sh                              # apply -> test -> destroy (~30 min)
KEEP=1 ./run.sh                       # leave infra up for debugging
RUN_SUFFIX=abc123 DESTROY_ONLY=1 ./run.sh   # tear down a kept run
KEEP=1 ./run.sh -k mirror             # extra args pass through to pytest
```

## Safety properties

- Every resource name embeds a per-run suffix; nothing references
  pre-existing resources, and `terraform destroy` only removes what the
  fixture created (state-scoped).
- `run.sh` verifies after destroy that no bucket bearing the run suffix
  remains in either cloud, and fails the run if one does.
- The "existing bucket" module inputs are exercised against buckets the
  fixture itself creates - never against real pre-existing buckets.
