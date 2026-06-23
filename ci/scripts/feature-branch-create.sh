#!/usr/bin/env bash
# feature-branch-create.sh — creates a feature branch when an issue
# gets the `feature` label.
#
# Called by the `feature-branch-create` Argo Events Sensor Job.
# Pure gh api calls — no LLM, no Kelos Task.
#
# Behavior:
#   1. Slugify issue title
#   2. Create branch `feature/issue-{N}-{slug}` from main (idempotent)
#   3. Post issue comment with branch link
#   4. Apply `branch-created` label to the issue
#
# Required env:
#   GH_TOKEN       — PAT with contents:write + issues:write
#   REPO           — owner/repo
#   ISSUE_NUMBER   — issue number
#   ISSUE_TITLE    — issue title (for slug)
#
# Optional env:
#   BASE_BRANCH           — base to branch from (default: main)
#   BRANCH_CREATED_LABEL  — label applied after branch exists (default: branch-created)
#   AI_IMPLEMENT_LABEL    — label user applies to trigger implementer (default: ready:ai-implement; shown in comment)

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO:?REPO is required (owner/repo)}"
: "${ISSUE_NUMBER:?ISSUE_NUMBER is required}"
: "${ISSUE_TITLE:?ISSUE_TITLE is required}"
BASE_BRANCH="${BASE_BRANCH:-main}"
BRANCH_CREATED_LABEL="${BRANCH_CREATED_LABEL:-branch-created}"
AI_IMPLEMENT_LABEL="${AI_IMPLEMENT_LABEL:-ready:ai-implement}"

log() { echo "[feature-branch-create] $*" >&2; }

# ─── Slugify ─────────────────────────────────────────────────────────────
SLUG=$(echo "$ISSUE_TITLE" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g' \
  | sed -E 's/^-+|-+$//g' \
  | cut -c1-40 \
  | sed -E 's/-+$//')

if [ -z "$SLUG" ]; then
  SLUG="untitled"
fi

BRANCH="feature/issue-${ISSUE_NUMBER}-${SLUG}"
log "creating branch: $BRANCH"

# ─── Get base branch SHA ────────────────────────────────────────────────
BASE_SHA=$(gh api "repos/${REPO}/git/refs/heads/${BASE_BRANCH}" \
  --jq '.object.sha')
if [ -z "$BASE_SHA" ]; then
  log "ERROR: could not resolve $BASE_BRANCH SHA"
  exit 1
fi

# ─── Create branch (idempotent) ──────────────────────────────────────────
# 422 Unprocessable Entity = branch already exists — fine, skip.
HTTP_CODE=$(gh api -X POST "repos/${REPO}/git/refs" \
  -f ref="refs/heads/${BRANCH}" \
  -f sha="$BASE_SHA" \
  --silent \
  -i 2>&1 | head -n1 | awk '{print $2}' || true)

case "$HTTP_CODE" in
  201)
    log "branch created"
    ;;
  422)
    log "branch already exists — continuing"
    ;;
  *)
    # Try again without -i to see the actual error
    gh api -X POST "repos/${REPO}/git/refs" \
      -f ref="refs/heads/${BRANCH}" \
      -f sha="$BASE_SHA" 2>&1 || true
    log "branch create returned $HTTP_CODE — proceeding anyway"
    ;;
esac

# ─── Post issue comment (idempotent: skip if already commented) ──────────
EXISTING=$(gh api "repos/${REPO}/issues/${ISSUE_NUMBER}/comments?per_page=100" \
  --paginate --jq '.[] | select(.body | contains("<!-- branch-announce -->")) | .id' \
  | head -n1)

if [ -z "$EXISTING" ]; then
  BODY="<!-- branch-announce -->
Branch created: [\`${BRANCH}\`](https://github.com/${REPO}/tree/${BRANCH})

Push WIP commits here during ideation if useful. When requirements are clear, apply the \`${AI_IMPLEMENT_LABEL}\` label — the AI will push final code and open a PR on this branch."

  gh api -X POST "repos/${REPO}/issues/${ISSUE_NUMBER}/comments" \
    -f body="$BODY"
  log "comment posted"
else
  log "announce comment already exists (id=$EXISTING) — skipping"
fi

# ─── Apply branch-created label (idempotent) ─────────────────────────────
gh api -X POST "repos/${REPO}/issues/${ISSUE_NUMBER}/labels" \
  -f "labels[]=${BRANCH_CREATED_LABEL}" >/dev/null 2>&1 || true
log "label applied"

log "done: $BRANCH"
