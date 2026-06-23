#!/usr/bin/env bash
# feature-orchestrator.sh — counts review verdicts on a PR and decides
# the next pipeline action.
#
# Called by the `feature-review-orchestrator` Sensor Job. Fires on:
#   - pull_request_review.submitted events
#   - push events to branches with open PRs
#
# Reads reviews on the current HEAD SHA (discards stale reviews from
# prior commits), parses verdict markers, counts tier-1 and tier-2
# approvals, and either:
#   - spawns tier 2 Tasks (if tier 1 both approved, tier 2 not started)
#   - spawns fixer Task (if any CHANGES_REQUESTED, rounds < 3)
#   - posts "ready to merge" + label (if all 7 approved on HEAD)
#   - escalates to human (if rounds >= 3)
#
# Required env:
#   GH_TOKEN       — PAT with pull_requests:write + contents:read
#   REPO           — owner/repo
#   PR_NUMBER      — pull request number
#
# Optional env:
#   MAX_FIX_ROUNDS — default 3

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO:?REPO is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
MAX_FIX_ROUNDS="${MAX_FIX_ROUNDS:-3}"
READY_TO_MERGE_LABEL="${READY_TO_MERGE_LABEL:-ready-to-merge}"
REVIEW_FAILED_LABEL="${REVIEW_FAILED_LABEL:-review-failed}"
AWAITING_HUMAN_LABEL="${AWAITING_HUMAN_LABEL:-awaiting-human}"

# Role sets.
TIER1_ROLES=(security architect)
TIER2_ROLES=(lead-dev designer devrel qa devops)
ALL_ROLES=("${TIER1_ROLES[@]}" "${TIER2_ROLES[@]}")

log() { echo "[feature-orchestrator] $*" >&2; }

# ─── Resolve HEAD SHA ─────────────────────────────────────────────────
HEAD_SHA=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.head.sha')
BASE_REPO_NAME=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.head.repo.full_name')
BRANCH=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.head.ref')
log "PR #${PR_NUMBER} HEAD=${HEAD_SHA} branch=${BRANCH}"

# ─── Fetch reviews on HEAD SHA only ────────────────────────────────────
REVIEWS=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews" --paginate \
  | jq --arg sha "$HEAD_SHA" '[.[] | select(.commit_id == $sha)]')
log "reviews on HEAD: $(echo "$REVIEWS" | jq 'length')"

# ─── Parse verdicts per role ───────────────────────────────────────────
# Verdict marker format: <!-- review-{role}: {verdict} -->
# Fall back to review.state if marker missing.
get_verdict() {
  local role=$1
  # Prefer explicit marker
  MARKER=$(echo "$REVIEWS" | jq -r --arg r "$role" \
    '.[] | select(.body | test("<!-- review-" + $r + ":")) | .body' \
    | grep -oE "<!-- review-${role}: [a-z-]+ -->" \
    | tail -n1 \
    | sed -E "s/<!-- review-${role}: ([a-z-]+) -->/\\1/" || true)
  if [ -n "$MARKER" ]; then
    echo "$MARKER"
    return
  fi
  # Fall back to GitHub state (last review by a reviewer matching this role)
  # We match on review body containing the role keyword as a heuristic.
  STATE=$(echo "$REVIEWS" | jq -r --arg r "$role" \
    '.[] | select(.body | test($r; "i")) | .state' | tail -n1 || true)
  case "$STATE" in
    APPROVED)           echo "approve" ;;
    CHANGES_REQUESTED)  echo "changes-requested" ;;
    COMMENTED)          echo "pending" ;;
    *)                  echo "none" ;;
  esac
}

declare -A VERDICTS
for role in "${ALL_ROLES[@]}"; do
  VERDICTS[$role]=$(get_verdict "$role")
  log "  ${role}: ${VERDICTS[$role]}"
done

# ─── Count tier statuses ──────────────────────────────────────────────
count_in_state() {
  local state=$1; shift
  local roles=("$@")
  local count=0
  for r in "${roles[@]}"; do
    [ "${VERDICTS[$r]}" = "$state" ] && count=$((count + 1))
  done
  echo $count
}

TIER1_APPROVED=$(count_in_state approve "${TIER1_ROLES[@]}")
TIER1_CHANGES=$(count_in_state changes-requested "${TIER1_ROLES[@]}")
TIER1_NONE=$(count_in_state none "${TIER1_ROLES[@]}")
TIER2_APPROVED=$(count_in_state approve "${TIER2_ROLES[@]}")
TIER2_CHANGES=$(count_in_state changes-requested "${TIER2_ROLES[@]}")
TIER2_NONE=$(count_in_state none "${TIER2_ROLES[@]}")
TOTAL_APPROVED=$((TIER1_APPROVED + TIER2_APPROVED))
TOTAL_CHANGES=$((TIER1_CHANGES + TIER2_CHANGES))

log "tier1: approved=$TIER1_APPROVED changes=$TIER1_CHANGES none=$TIER1_NONE"
log "tier2: approved=$TIER2_APPROVED changes=$TIER2_CHANGES none=$TIER2_NONE"

# ─── Count fix rounds (bot commits on the branch) ─────────────────────
FIX_ROUNDS=$(gh api "repos/${REPO}/commits?sha=${BRANCH}&per_page=100" \
  --paginate \
  --jq '[.[] | select(.commit.message | test("^fix\\(review\\)"))] | length')
log "fix rounds so far: $FIX_ROUNDS"

# ─── Helper: spawn a Kelos Task ────────────────────────────────────────
spawn_review_task() {
  local role=$1
  local agent_config="feature-review-${role}"
  local task_name="${role}-pr${PR_NUMBER}-${HEAD_SHA:0:7}"

  log "spawning: ${task_name}"
  cat <<EOF | kubectl create -f - 2>&1 | sed 's/^/  /' >&2 || true
apiVersion: kelos.dev/v1alpha1
kind: Task
metadata:
  name: ${task_name}
  namespace: kelos-system
  labels:
    app.kubernetes.io/managed-by: feature-orchestrator
    kelos.dev/role: review-${role}
    feature.k8-infra/pr: "${PR_NUMBER}"
    feature.k8-infra/sha: "${HEAD_SHA:0:7}"
spec:
  type: claude-code
  credentials:
    type: oauth
    secretRef:
      name: claude-code-oauth
  agentConfigRef:
    name: ${agent_config}
  ttlSecondsAfterFinished: 3600
  podOverrides:
    env:
      - name: GITHUB_TOKEN
        valueFrom:
          secretKeyRef:
            name: github-pat
            key: GITHUB_TOKEN
  prompt: |
    Review PR #${PR_NUMBER} on ${REPO} at commit ${HEAD_SHA}.

    Follow your AgentConfig instructions. Post ONE formal PR review
    via the GitHub Reviews API (not an issue comment). Include the
    verdict marker <!-- review-${role}: {verdict} --> in the review
    body. Use commit_id="${HEAD_SHA}" in the review.

    Stop after posting.
EOF
}

spawn_fixer_task() {
  local round=$((FIX_ROUNDS + 1))
  local task_name="fixer-pr${PR_NUMBER}-round${round}"

  log "spawning fixer (round ${round}): ${task_name}"
  cat <<EOF | kubectl create -f - 2>&1 | sed 's/^/  /' >&2 || true
apiVersion: kelos.dev/v1alpha1
kind: Task
metadata:
  name: ${task_name}
  namespace: kelos-system
  labels:
    app.kubernetes.io/managed-by: feature-orchestrator
    kelos.dev/role: review-fixer
    feature.k8-infra/pr: "${PR_NUMBER}"
    feature.k8-infra/round: "${round}"
spec:
  type: claude-code
  credentials:
    type: oauth
    secretRef:
      name: claude-code-oauth
  agentConfigRef:
    name: feature-review-fixer
  workspaceRef:
    name: ${BASE_REPO_NAME##*/}
  branch: ${BRANCH}
  ttlSecondsAfterFinished: 3600
  podOverrides:
    env:
      - name: GITHUB_TOKEN
        valueFrom:
          secretKeyRef:
            name: github-pat
            key: GITHUB_TOKEN
  prompt: |
    Fix review findings on PR #${PR_NUMBER} (${REPO}).
    Current HEAD: ${HEAD_SHA}. This is round ${round} of ${MAX_FIX_ROUNDS}.
    Follow your AgentConfig instructions. Stop after pushing.
EOF
}

post_ready_to_merge() {
  local body
  body=$(printf ':rocket: All %d reviewers approved on commit `%s`.\n\n@%s — ready to merge.' \
    "${#ALL_ROLES[@]}" "${HEAD_SHA:0:7}" "$(gh api "repos/${REPO}" --jq '.owner.login')")
  gh api -X POST "repos/${REPO}/issues/${PR_NUMBER}/comments" \
    -f body="$body" >/dev/null
  gh api -X POST "repos/${REPO}/issues/${PR_NUMBER}/labels" \
    -f "labels[]=${READY_TO_MERGE_LABEL}" >/dev/null 2>&1 || true
  log "posted ready-to-merge"
}

post_escalation() {
  local blockers
  blockers=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/comments" --paginate \
    --jq '.[] | "- `\(.path):\(.line // .original_line)` — \(.body | split("\n")[0])"' \
    | head -n 20)

  local body
  body=$(cat <<BODY
## :no_entry: Auto-fix limit reached

After ${MAX_FIX_ROUNDS} fix rounds, reviewers still request changes.
Human intervention required.

**Remaining blockers (first 20):**
${blockers}

Review the PR diff + reviews, then either:
- Remove the \`${AWAITING_HUMAN_LABEL}\` label after pushing fixes (pipeline resumes)
- Close this PR if the approach is wrong
BODY
)
  gh api -X POST "repos/${REPO}/issues/${PR_NUMBER}/comments" \
    -f body="$body" >/dev/null
  gh api -X POST "repos/${REPO}/issues/${PR_NUMBER}/labels" \
    -f "labels[]=${REVIEW_FAILED_LABEL}" -f "labels[]=${AWAITING_HUMAN_LABEL}" >/dev/null 2>&1 || true
  log "posted escalation"
}

# ─── Decide next action ───────────────────────────────────────────────
# Precedence:
#   1. All 7 approved → ready-to-merge
#   2. Any changes-requested + rounds < max → spawn fixer
#   3. Any changes-requested + rounds >= max → escalate
#   4. Tier-1 both approved + tier-2 not started → spawn tier-2
#   5. Otherwise → wait

if [ "$TOTAL_APPROVED" -eq "${#ALL_ROLES[@]}" ]; then
  log "all approved → ready to merge"
  post_ready_to_merge
  exit 0
fi

if [ "$TOTAL_CHANGES" -gt 0 ]; then
  if [ "$FIX_ROUNDS" -ge "$MAX_FIX_ROUNDS" ]; then
    log "fix rounds exhausted → escalate"
    post_escalation
    exit 0
  fi
  log "changes requested → spawn fixer"
  spawn_fixer_task
  exit 0
fi

if [ "$TIER1_APPROVED" -eq "${#TIER1_ROLES[@]}" ] && [ "$TIER2_NONE" -gt 0 ]; then
  # All tier-2 roles that haven't submitted yet should spawn.
  log "tier 1 passed → spawning tier 2 (${TIER2_NONE} missing)"
  for role in "${TIER2_ROLES[@]}"; do
    if [ "${VERDICTS[$role]}" = "none" ]; then
      spawn_review_task "$role"
    fi
  done
  exit 0
fi

log "waiting for more reviews; no action"
