# Unblocking Service Account JSON Key Creation in GCP

When provisioning the Dex `dex-groups-reader` service account in our
`your-gcp-project` project for Workspace Groups API access, we
hit GCP's Secure-by-Default org policy blocking JSON key creation.
This doc records exactly which commands moved the needle.

## Symptom

```
ERROR: (gcloud.iam.service-accounts.keys.create) FAILED_PRECONDITION:
Key creation is not allowed on this service account.
- violations:
  - description: Key creation is not allowed on this service account.
    type: constraints/iam.disableServiceAccountKeyCreation
```

UI version: "Service account key creation is disabled — An Organization
Policy that blocks service accounts key creation has been enforced on
your organization."

Two related constraints exist:
- `iam.disableServiceAccountKeyCreation` (legacy)
- `iam.managed.disableServiceAccountKeyCreation` (newer managed variant,
  condition `keyType == 'USER_MANAGED' && keyOrigin == 'GOOGLE_PROVIDED'`)

Both can be enforced independently. Overriding only one is not enough.

## Prerequisites

You need:
- Workspace **Super Admin** role (to receive org-level IAM in GCP)
- GCP `roles/resourcemanager.organizationAdmin` (super admin auto-gets,
  may need 5-10 min propagation + re-login)
- GCP `roles/orgpolicy.policyAdmin` (granted to self via org admin)

## Diagnostic flow

```bash
# 1. Confirm you can see the org
gcloud auth login admin@example.com
gcloud organizations list
# Expect: example.com  123456789012  C0xxxxxxx

# 2. Confirm project is direct child of org (no folder)
gcloud projects describe your-gcp-project --format='value(parent)'
# Expect: id=123456789012;type=organization

# 3. List currently-enforced SA-key constraints
gcloud org-policies list --project=your-gcp-project \
  --format='value(constraint)' | grep -iE 'key|serviceaccount'
```

## Grant self the policy-admin role

If you can't grant directly (no org admin yet):

```bash
gcloud organizations add-iam-policy-binding 123456789012 \
  --member="user:admin@example.com" \
  --role="roles/resourcemanager.organizationAdmin"
```

Then orgpolicy admin:

```bash
gcloud organizations add-iam-policy-binding 123456789012 \
  --member="user:admin@example.com" \
  --role="roles/orgpolicy.policyAdmin"
```

If both `add-iam-policy-binding` calls fail with "permission denied",
the Workspace super-admin propagation hasn't reached GCP yet — re-login
and wait up to 10 minutes.

## The override that finally worked

Project-level override alone wasn't sufficient — Secure-by-Default
enforces from org level and project override didn't satisfy it. Set
**both constraints** at **both levels** (project AND org):

```bash
# Project-level: legacy constraint
cat > /tmp/sa-key-project-legacy.yaml <<EOF
name: projects/your-gcp-project/policies/iam.disableServiceAccountKeyCreation
spec:
  rules:
  - enforce: false
EOF
gcloud org-policies set-policy /tmp/sa-key-project-legacy.yaml

# Project-level: managed constraint
cat > /tmp/sa-key-project-managed.yaml <<EOF
name: projects/your-gcp-project/policies/iam.managed.disableServiceAccountKeyCreation
spec:
  rules:
  - enforce: false
EOF
gcloud org-policies set-policy /tmp/sa-key-project-managed.yaml

# Org-level: legacy constraint
cat > /tmp/sa-key-org-legacy.yaml <<EOF
name: organizations/123456789012/policies/iam.disableServiceAccountKeyCreation
spec:
  rules:
  - enforce: false
EOF
gcloud org-policies set-policy /tmp/sa-key-org-legacy.yaml

# Org-level: managed constraint
cat > /tmp/sa-key-org-managed.yaml <<EOF
name: organizations/123456789012/policies/iam.managed.disableServiceAccountKeyCreation
spec:
  rules:
  - enforce: false
EOF
gcloud org-policies set-policy /tmp/sa-key-org-managed.yaml
```

## Verification

```bash
# Effective policy at project level — both should show enforce: false
gcloud org-policies describe iam.disableServiceAccountKeyCreation \
  --project=your-gcp-project --effective
gcloud org-policies describe iam.managed.disableServiceAccountKeyCreation \
  --project=your-gcp-project --effective
```

## Cache wait

After the override is applied, **IAM enforcement cache is independent
of the org-policy service cache**. The org-policy service confirms the
override in seconds, but IAM can take 15-30 min before it stops
rejecting. The Cloud Console UI cache is even longer.

Symptom during the wait: `gcloud org-policies describe --effective`
shows `enforce: false` but the API call still fails with the same
`constraints/iam.disableServiceAccountKeyCreation` violation.

## Creating the key (once cache clears)

```bash
gcloud iam service-accounts keys create dex-groups-reader.json \
  --iam-account=dex-groups-reader@your-gcp-project.iam.gserviceaccount.com \
  --key-file-type=json
```

`Created key [...] of type [json] as [dex-groups-reader.json]`.

## After you have the key

1. Stash in OpenBao immediately (do NOT commit the JSON):
   ```bash
   bao kv put secret/home/dex/google \
     client_id=<oauth web client ID> \
     client_secret=<oauth web client secret> \
     service_account_json=@dex-groups-reader.json \
     admin_email=admin@example.com
   ```
2. `rm dex-groups-reader.json` once stashed.

## Optional hardening — re-enforce after Dex is up

The Dex deployment only needs the JSON key once (loaded into the
container at startup). After Dex is running and the key is in OpenBao,
you can re-enable the org policy to prevent future leaks:

```bash
# Re-enforce at org level (project overrides will still be in place;
# delete them too if you want full re-enforcement)
cat > /tmp/sa-key-org-legacy-restore.yaml <<EOF
name: organizations/123456789012/policies/iam.disableServiceAccountKeyCreation
spec:
  rules:
  - enforce: true
EOF
gcloud org-policies set-policy /tmp/sa-key-org-legacy-restore.yaml

cat > /tmp/sa-key-org-managed-restore.yaml <<EOF
name: organizations/123456789012/policies/iam.managed.disableServiceAccountKeyCreation
spec:
  rules:
  - enforce: true
EOF
gcloud org-policies set-policy /tmp/sa-key-org-managed-restore.yaml

# Remove project overrides
gcloud org-policies delete iam.disableServiceAccountKeyCreation \
  --project=your-gcp-project
gcloud org-policies delete iam.managed.disableServiceAccountKeyCreation \
  --project=your-gcp-project
```

This is good hygiene — keep the policy enforced by default, only
disable when actively provisioning a new SA key.

## Why this is a one-off

Each Dex Workspace integration needs exactly one SA key, generated
once, stored in OpenBao, rotated rarely. After the key is in OpenBao
and ESO is syncing it into the cluster, nothing in the cluster ever
touches the GCP API for the key again. Re-enforcing the org policy
after the initial setup is the right end state.

## What didn't work

Things tried that turned out to be no-ops or insufficient:
- Setting the override at **project level only** — IAM service still
  honoured the org-level enforcement.
- Setting only **one** of the two constraints — the legacy variant
  was still active even after the managed one was turned off.
- **Waiting 30 min** without org-level override — cache lifts within
  ~15 min once the right override is in place, but never lifts if the
  override is incomplete.
- **UI-based policy edit** in Cloud Console — works, but the page UI
  for "Manage Policy" on managed constraints kept refreshing back to
  the parent state. CLI was more reliable.

## References

- IAM org policy constraints catalog: https://cloud.google.com/iam/docs/org-policy-constraints
- Managed constraints overview: https://cloud.google.com/resource-manager/docs/organization-policy/creating-managing-managed-org-policy
- Secure-by-Default enforcement notice (Google blog, 2024-Q3 rollout)
