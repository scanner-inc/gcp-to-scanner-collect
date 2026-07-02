# Integration Tests

End-to-end testing for both pipeline modules against real GCP and AWS
infrastructure. Implementation: `tests/integration/`. This document covers
what the suite tests, how it's structured, and the platform behaviors it is
designed around.

## 1. Objectives

Verify, against real cloud APIs, the properties unit tests cannot cover:

1. **Cross-cloud auth works**: GCP metadata-server OIDC tokens are accepted by AWS
   STS (`AssumeRoleWithWebIdentity`) using the Terraform-created role and trust policy.
2. **Events flow end-to-end**: Cloud Logging → Pub/Sub → GCS → Eventarc → Cloud
   Function → S3 (logging module), and GCS notification → Pub/Sub push → Cloud
   Function → S3 (mirror module).
3. **Data integrity**: bytes that land in S3 decompress to exactly what went in,
   with correct `Content-Encoding` / `Content-Type` / metadata for every
   compression path.
4. **Filtering semantics**: key prefix / include regex / exclude regex behave as
   documented, including negative cases.
5. **Safety properties**: the mirror module never deletes source objects; the
   logging module deletes temp objects only after successful transfer.
6. **Retry paths**: the logging cleanup function recovers stranded files, and
   the mirror pipeline's Pub/Sub redelivery recovers from delivery outages.
7. **Terraform contract**: apply-from-scratch succeeds, outputs are correct,
   destroy leaves nothing behind, and re-apply is a no-op (idempotent plan).

### Non-goals

- Load/soak testing (high-volume batching behavior is observed, not asserted).
- Testing against a real Scanner tenant (see Out of scope / Future work).
- Multi-region matrix beyond one regional + one multi-region GCS bucket case.

## 2. Test Environments

| | Resource | Notes |
|---|---|---|
| GCP | Dedicated test project | Isolates API enablement, IAM, quotas; safe to sweep clean |
| AWS | Dedicated test account | Lifecycle/notification assertions need bucket-level control |
| Region | `us-central1` / `us-east-1` (defaults) | One mirror case uses a `US` multi-region bucket |

**Naming**: every run uses a short run suffix (random hex, or `RUN_SUFFIX=` to
pin one); every resource name embeds it (`it-<suffix>-...`). This makes
concurrent runs safe and orphans attributable.

**Credentials**: developer `gcloud auth login` + `gcloud auth application-default
login` + AWS SSO profile. All runs are manual/local (see Out of scope).

## 3. Harness Architecture

```
tests/integration/
├── fixture/                  # Terraform root that instantiates the modules under test
│   ├── main.tf               # shared module + pipeline instances + test-owned source buckets
│   ├── variables.tf
│   └── outputs.tf            # everything the test driver needs (bucket names, fn names, ...)
├── conftest.py               # terraform outputs, cloud clients, polling helpers, settle canaries
├── test_logging_pipeline.py
├── test_mirror_pipeline.py
├── test_mirror_multi.py
├── test_terraform_contract.py
└── run.sh                    # entrypoint: preflight → terraform apply → pytest → destroy → leftover check
```

- **Driver**: Python + pytest, using `google-cloud-storage`, `google-cloud-logging`,
  and `boto3` directly (CLI only for one-off actions like scheduler runs and
  IAM toggles).
- **One apply per session**: the fixture deploys everything once (~10–15 min,
  dominated by Cloud Functions Gen2 builds), all tests run against it, one destroy
  at the end. Tests namespace their object keys, so they don't collide.
- **Polling helper**: `wait_for(predicate, timeout, interval)` with per-path
  timeouts (logging: minutes, batching-dominated; mirror: ~2 min) and a
  copy-pasteable `gcloud functions logs read` hint in every failure message.
- **Negative assertions**: to prove "object X was NOT copied," each negative test
  uploads a positive-control object in the same batch and asserts
  `control arrived && X absent` - bounding the wait without racing the pipeline.

### Fixture deployment matrix

| Instance | Module | Configuration under test |
|---|---|---|
| `log-new` | cloud-logging-to-s3 | Auto-named S3 bucket, filtered sink (test log name), 60s batching, `s3_expiration_days = 7`, `age_threshold_minutes = 0` (for the cleanup-retry test) |
| `mir-new` | gcs-bucket-to-s3 | Regional source bucket, all three filters set, `s3_key_prefix`, `s3_expiration_days = 7`, no `alert_email` (DLQ alert policy asserted via outputs) |
| `mir-multi` | gcs-bucket-to-s3 | `US` multi-region source bucket, no filters, `existing_s3_bucket_name` |

The "existing" S3 bucket and both GCS source buckets are created by the fixture
itself. The module blocks carry `depends_on` on the source buckets so the
module's bucket data source defers to apply.

## 4. Test Matrix

### 4.1 Cloud Logging pipeline (`test_logging_pipeline.py`)

| ID | Test | Steps | Assertions |
|---|---|---|---|
| L1 | Happy path | Write 20 entries via Cloud Logging API with unique run-ID payloads | All 20 payloads present in S3 under `log_prefix` (at-least-once; Pub/Sub may duplicate across batch files) |
| L2 | Compression contract | Inspect L1 objects | `ContentEncoding: gzip`, `ContentType: application/x-ndjson`, `transferred-by` metadata |
| L3 | Temp bucket drains | After L1 settles | GCS temp bucket contains no objects older than a few minutes |
| L5 | Cleanup retry | Revoke the transfer function's `run.invoker` binding, upload a `.jsonl` to the temp bucket and retry until it strands (IAM propagation is lazy), run the cleanup scheduler job **while delivery is still blocked** (avoids racing Pub/Sub redelivery), restore the binding in a `finally` | Object lands in S3 with `transferred-by: cleanup-function`; temp copy deleted |
| L6 | Lifecycle opt-in | Covered by the contract tests | 7-day expiration rule enabled on the created bucket |
| L7 | Lifecycle absent on existing bucket | Covered against `mir-multi`'s existing bucket in M9 | `NoSuchLifecycleConfiguration` |

*L5 note*: `age_threshold_minutes = 0` on this instance so an on-demand cleanup
run considers a just-stranded file stale immediately.

### 4.2 GCS bucket mirror pipeline (`test_mirror_pipeline.py`)

| ID | Test | Steps | Assertions |
|---|---|---|---|
| M1 | Happy path + key mapping | Upload `logs/<runid>/a.json` to source bucket | Appears in S3 at `<s3_key_prefix>/logs/<runid>/a.json` within ~2 min; content round-trips |
| M2 | **Source never deleted** | After M1 | Source object still present in GCS |
| M3 | Prefix filter (negative) | Upload `other/<runid>/b.json` + control under `logs/` | Control arrives; `other/...` never copied |
| M4 | Exclude regex (negative) | Upload `logs/<runid>/c.tmp` + control | Control arrives; `.tmp` never copied |
| M5 | Include regex (negative) | Upload `logs/<runid>/d.csv` + control | CSV never copied |
| M6 | Compression: plain file | Folded into M1 | S3 copy has `ContentEncoding: gzip`; decompressed bytes == original |
| M7 | Compression: `.gz` passthrough | Upload a real gzip file as `logs/<runid>/e.json.gz` | S3 bytes byte-identical to source; **no** `ContentEncoding` header |
| M8 | Compression: GCS `content_encoding=gzip` | Upload with `content_encoding='gzip'` set on the blob | S3 copy has `ContentEncoding: gzip`; decompresses to original |
| M9 | Multi-region bucket + existing S3 bucket | Upload to the `US` multi-region bucket (`mir-multi`, in `test_mirror_multi.py`) | Copied into the pre-existing S3 bucket (notifications flow regardless of bucket location); no lifecycle configuration on the existing bucket |
| M12 | Redelivery recovers from outage | (`mir-new`) revoke the function's `run.invoker` (push deliveries 403), upload an object, confirm it strands, restore the binding in a `finally` | Pub/Sub backoff redelivery (≤600s) lands the object with no other mechanism; `transferred-by: mirror-function`; source untouched |
| M13 | Lifecycle opt-in / default | `mir-new` bucket has the 7-day rule (contract test); `mir-multi`'s existing bucket has none (M9) | As in L6/L7 |

### 4.3 Terraform contract (`test_terraform_contract.py`)

| ID | Test | Assertions |
|---|---|---|
| T1 | Outputs | All outputs non-empty and consistent with reality (buckets exist, run suffix embedded in resource names) |
| T1b | Lifecycle rules | 7-day expiration present on both created buckets |
| T1c | DLQ + retry wiring | Mirror push subscription has a dead-letter policy and retry policy; the DLQ pull subscription exists (a dead-letter topic without a subscription silently drops messages) |
| T2 | Idempotent plan | `terraform plan -detailed-exitcode` after apply returns 0 (no drift) |
| T3 | Clean destroy | After `terraform destroy`: no bucket bearing the run suffix remains in either cloud (`run.sh` checks and fails the run otherwise) |

## 5. Execution Flow & Timing Budget

```
run.sh:
  1. preflight        (~15 s)  creds on both clouds, terraform >= 1.9, billing
                               enabled, quota project pinned (GOOGLE_CLOUD_QUOTA_PROJECT)
  2. terraform apply  (~13 min) fixture (3 pipeline instances, 6 functions)
  3. pytest           (~13 min) settle canaries first (see §7), then tests
  4. terraform destroy(~8 min)  always runs (trap on EXIT), force_destroy=true
  5. leftover check   (~5 s)   T3: fail if any run-suffixed bucket remains
```

Total ≈ 30–40 min. `KEEP=1 ./run.sh` skips the destroy for debugging;
`RUN_SUFFIX=<sfx> DESTROY_ONLY=1 ./run.sh` tears a kept run down.

## 6. Cost & Quotas

Per run, rough order: Cloud Build minutes for 6 function deploys (~free tier),
< 1k Class A/B GCS ops, < 100 MB egress GCP→AWS (~$0.01), S3 requests negligible.
**Estimated < $0.25/run**. Quota watch-items: Cloud Build concurrent builds (10)
and service accounts per project (run suffixes mean SAs accumulate only if
destroy fails).

## 7. Known Platform Behaviors (and how the harness compensates)

These are real, reproducible behaviors of the underlying platforms - not bugs in
the pipelines - that anyone extending the suite should know about:

1. **New Cloud Logging sinks silently drop entries while propagating.** For the
   first minutes after a sink is created, entries that match its filter may not
   be exported - with no `sink_error`, no Pub/Sub backlog, no signal anywhere.
   Deploy-time-only; long-lived sinks are unaffected. *Harness*: the session
   canary writes real log entries through the full sink → Pub/Sub → GCS → S3
   path and requires 2 consecutive deliveries before any test counts entries.
2. **Fresh Eventarc triggers drop first-minute events** (logging pipeline's
   temp-bucket trigger). *Harness*: a canary object is uploaded to the temp
   bucket repeatedly until one demonstrably reaches S3. (The mirror pipeline
   doesn't use Eventarc; its Pub/Sub push path *retries* early failures instead
   of dropping them, which the canary simply rides out.)
3. **IAM bindings propagate lazily, in both directions.** A fresh `run.invoker`
   binding can take ~1–2 min to allow pushes (Pub/Sub retries absorb this); a
   revoked binding keeps working for a while (L5/M12 retry until the revocation
   actually bites). AWS STS may likewise reject the first OIDC assume from a
   brand-new role.
4. **Google client libraries bill the ADC quota project, not the resource
   project.** If the quota project lacks a billing account, every GCS call fails
   403 with a misleading "The billing account for the owning project is disabled
   in state absent" - while Terraform (which doesn't send that header) works
   fine. *Harness*: `run.sh` exports `GOOGLE_CLOUD_QUOTA_PROJECT` pinned to the
   test project.

General flakiness rules: all arrival assertions use bounded polling, never fixed
sleeps (two deliberate exceptions: the negative-assertion grace period and the
IAM-propagation waits, which retry with fresh uploads). If a run is killed
outright, the EXIT trap can't fire - re-run with `DESTROY_ONLY=1`; the
post-destroy leftover check fails loudly rather than leaking silently.

## 8. Out of Scope

- **Scanner integration surface** (stand-in SNS/SQS/IAM assertions): the
  `scanner_sns_topic_arn` / `scanner_role_arn` path is exercised against real
  Scanner tenants in practice.
- **CI automation**: runs are manual/local via `run.sh`.

## 9. Future Work

- L4: sink-filter negative test (out-of-filter entries never reach S3).
- L8: dedup/idempotency test for the logging transfer path.
- Forced end-to-end DLQ test: drive a message to exhaust its delivery attempts,
  assert it dead-letters and the alert fires (slow - requires ~20 failed
  deliveries at growing backoff).
- Volume probe: burst 10k objects through the mirror path, assert zero loss via
  manifest diff.
- Upgrade test: `terraform apply` from the last released tag to HEAD.
- Real Scanner staging tenant: assert mirrored/exported logs become searchable.
