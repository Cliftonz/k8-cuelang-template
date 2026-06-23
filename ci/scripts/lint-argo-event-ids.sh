#!/usr/bin/env bash
# Lint argo-events sensor templates for unsafe rendering of GitHub IDs.
#
# Background:
# GitHub integer IDs (comment.id, issue.id, pull_request.id, check_run.id,
# etc.) can exceed 2^32. Argo Events parameter substitution uses Go's
# text/template, and the JSON decoder puts numbers into float64. When
# rendered with the default `{{ . }}` formatter, large floats become
# scientific notation (e.g. "4.433828475e+09"). That string contains '+'
# and '.' in positions that violate the Kubernetes RFC-1123 subdomain
# rule, so any sensor trigger that uses this in a metadata.name will
# fail silently at k8s-create time. URLs constructed with the same
# unwrapped ID will 404.
#
# Fix: wrap with `printf "%.0f"` to force decimal integer rendering.
#
# See docs/argo-events-large-int-pitfall.md for the full incident report.

set -eu

FILE="${1:-composites/home/argoevents.cue}"
if [ ! -f "$FILE" ]; then
  echo "lint-argo-event-ids: file not found: $FILE" >&2
  exit 2
fi

# Pattern: {{ ... .Input.body.<path>.id ... }} where the inner expression
# does NOT contain "printf" or "%.0f". We accept either spelling because
# the operator could in principle use printf with %d on an integer, but
# right now %.0f is the canonical fix.
#
# Negative lookbehind would be cleanest but grep on macOS/BSD doesn't
# support PCRE. Two-pass instead: find candidate lines, then filter out
# the safe ones.
BAD=$(grep -nE '\{\{[^}]*\.Input\.body\.[A-Za-z0-9_.]+\.id\b' "$FILE" \
  | grep -vE 'printf .*%\.0f' \
  | grep -vE '\{\{ *printf' \
  || true)

if [ -n "$BAD" ]; then
  cat >&2 <<'EOF'
lint-argo-event-ids: unwrapped GitHub ID interpolation(s) detected.

Lines below render `.Input.body.*.id` without a `printf "%.0f"` wrapper.
GitHub IDs > 2^32 will render as scientific notation (e.g. "4.4e+09"),
which produces invalid Kubernetes resource names and 404-prone URLs.

Replace:
    {{ .Input.body.comment.id }}
with:
    {{ printf "%.0f" .Input.body.comment.id }}

See docs/argo-events-large-int-pitfall.md.

Offending lines:
EOF
  echo "$BAD" >&2
  exit 1
fi

echo "lint-argo-event-ids: ok — all .Input.body.*.id references are %.0f-wrapped"
