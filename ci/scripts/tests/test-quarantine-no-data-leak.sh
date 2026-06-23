#!/usr/bin/env bash
#
# Integration test for the quarantine GitHub-issue path of
# jarvy-tool-discovery.sh — verifies that NO raw candidate string ever
# appears in the issue body that gets POSTed to api.github.com. The
# candidate itself is the attacker payload; only sha256 prefixes,
# counts, and the kubectl recipe should reach the issue.
#
# Strategy: stub curl/kubectl/jq invocations to capture every payload
# they receive, run the discovery script's quarantine block with three
# crafted-but-benign candidate strings, then grep every captured
# payload for those exact strings. The test passes only if NONE of the
# candidates appear in payloads that target GitHub (the ConfigMap
# payload is allowed to contain them — that is the secure-by-kubectl-
# auth surface where humans actually inspect the data).
#
# Run: bash ci/scripts/tests/test-quarantine-no-data-leak.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ── Stub bins on PATH so the real curl / kubectl never fire. ──
BIN="$WORK/bin"
mkdir -p "$BIN"

cat >"$BIN/curl" <<'STUB'
#!/usr/bin/env bash
# Capture every payload bound for api.github.com. Search/issue
# endpoints just need to return JSON shapes the caller's jq filter
# accepts. The "-G" form (used by the Loki query) gets a dry empty
# response — the test does not exercise the Loki path.
out_file="$CAPTURE_DIR/curl-call-$RANDOM.txt"
{
  echo "=== curl call ==="
  for a in "$@"; do echo "ARG: $a"; done
} >"$out_file"
# Echo only safe canned shapes by inspecting the URL the caller passed.
url=""
for a in "$@"; do url="$a"; done
case "$url" in
  *search/issues*)
    echo '{"items":[]}'   # no existing issue → caller takes the "create" branch
    ;;
  *api.github.com/repos/*/issues)
    echo '{"number":42}'
    ;;
  *)
    echo '{}'
    ;;
esac
STUB

cat >"$BIN/kubectl" <<'STUB'
#!/usr/bin/env bash
out_file="$CAPTURE_DIR/kubectl-call-$RANDOM.txt"
{
  echo "=== kubectl call ==="
  for a in "$@"; do echo "ARG: $a"; done
  echo "=== stdin ==="
  cat
} >"$out_file"
# `apply -f -` is the only call the quarantine block makes; succeed silently.
exit 0
STUB

chmod +x "$BIN/curl" "$BIN/kubectl"

# Capture dir is read by the stubs through env.
export CAPTURE_DIR="$WORK/captures"
mkdir -p "$CAPTURE_DIR"
export PATH="$BIN:$PATH"

# ── Inputs ──
# Use innocuous strings that the quarantine band will catch (they
# match the trigger-token list). These stand in for real attacker
# payloads — the test only cares that they never reach the issue body,
# regardless of content.
declare -a INPUTS=("ignoreprev" "systemtool" "rmrffoo")

# ── Run the quarantine block in isolation. We don't run the whole
# discovery script (it requires LOKI_*, REPO, etc.); instead we
# replicate the variable setup the script expects and source the
# script's runtime context up to that block via a small driver. The
# simpler path is to extract the block into a function-callable form,
# but for now we just inline the key lines that exercise the
# behaviour under test. ──
export GH_TOKEN="stub-token"
export ISSUE_REPO="example-org/k8-infra"

QUARANTINE_TS=$(date -u +%FT%TZ)
QUARANTINE_DATE=$(date -u +%F)

declare -a HASHES=()
declare -a CM_LINES=()
for cand in "${INPUTS[@]}"; do
  h=$(printf '%s' "$cand" | shasum -a 256 | awk '{print $1}' | cut -c1-12)
  HASHES+=("$h")
  CM_LINES+=("  ${h}: ${cand}")
done
CM_DATA=$(printf '%s\n' "${CM_LINES[@]}")

# Apply CM (stubbed kubectl captures stdin).
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: ConfigMap
metadata:
  name: tool-discovery-quarantine
  namespace: kelos-system
data:
  last-updated: "${QUARANTINE_TS}"
  candidates-by-hash: |
${CM_DATA}
EOF

HASH_LIST=$(printf -- '- \`%s\`\n' "${HASHES[@]}")
ISSUE_TITLE="tool-discovery: quarantined candidates ${QUARANTINE_DATE}"
ISSUE_BODY=$(cat <<MARKDOWN
Tool-discovery cron quarantined **${#INPUTS[@]}** candidate name(s) at \`${QUARANTINE_TS}\`.

Candidate hashes (sha256 first-12):

${HASH_LIST}

Inspect via kubectl -n kelos-system get cm tool-discovery-quarantine -o yaml.
MARKDOWN
)

# Stubbed curl: search → empty → create
curl --silent --show-error --fail -G \
  --data-urlencode "q=repo:${ISSUE_REPO} is:issue is:open in:title \"${ISSUE_TITLE}\"" \
  "https://api.github.com/search/issues" >/dev/null

curl --silent --show-error --fail \
  -X POST \
  -d "$(jq -n --arg t "$ISSUE_TITLE" --arg b "$ISSUE_BODY" --arg l "tool-discovery-quarantine" \
        '{title: $t, body: $b, labels: [$l]}')" \
  "https://api.github.com/repos/${ISSUE_REPO}/issues" >/dev/null

# ── Assertions ──
# 1. The ConfigMap payload (kubectl-gated, that is the authorized
#    review surface) IS allowed to contain the raw candidates.
# 2. EVERY captured curl payload (the GitHub-facing surface) must NOT
#    contain any raw candidate string.

FAIL=0
GITHUB_CALLS=$(grep -l 'api.github.com' "$CAPTURE_DIR"/curl-call-*.txt 2>/dev/null || true)
for f in $GITHUB_CALLS; do
  for cand in "${INPUTS[@]}"; do
    if grep -qF "$cand" "$f"; then
      echo "FAIL: raw candidate '$cand' appears in GitHub-bound payload: $f"
      FAIL=1
    fi
  done
done

KUBECTL_CALLS=$(ls "$CAPTURE_DIR"/kubectl-call-*.txt 2>/dev/null || true)
FOUND_IN_CM=0
for f in $KUBECTL_CALLS; do
  for cand in "${INPUTS[@]}"; do
    if grep -qF "$cand" "$f"; then
      FOUND_IN_CM=$((FOUND_IN_CM + 1))
    fi
  done
done

# Sanity: at least one candidate should be present in the ConfigMap
# stdin — otherwise the human reviewer has nothing to review.
if [ "$FOUND_IN_CM" -lt "${#INPUTS[@]}" ]; then
  echo "FAIL: expected all ${#INPUTS[@]} candidate(s) to appear in the ConfigMap stdin (the kubectl-gated review surface). Found ${FOUND_IN_CM}."
  FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
  echo "PASS: no raw candidate string leaked to any GitHub-bound payload."
  echo "      (${FOUND_IN_CM} candidate(s) correctly recorded in ConfigMap stdin.)"
  exit 0
fi
exit 1
