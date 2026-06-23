#!/usr/bin/env bash
#
# Unit tests for ci/scripts/lib/validate-tool-name.sh — the classifier
# that gates whether a telemetry-discovered tool name is safe to feed
# into a Kelos Task prompt or has to be quarantined for human review.
#
# Run: bash ci/scripts/tests/test-validate-tool-name.sh
# Exit 0 if every case matches its expected band; 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/../lib/validate-tool-name.sh"
# shellcheck source=../lib/validate-tool-name.sh
source "$LIB"

PASS=0
FAIL=0
declare -a FAILED_CASES=()

check() {
  local expected="$1" input="$2" label="${3:-}"
  local actual
  actual=$(validate_tool_name "$input")
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("  expected=$expected actual=$actual  input='$input'  ${label:+($label)}")
  fi
}

# ── Band 1: safe (every real Jarvy tool name in the registry today,
# plus the typical shapes Astral / vendor / cloud tools produce) ──
check safe "git"            "single short name"
check safe "uv"             "two-char Astral tool"
check safe "kubectl"        "kubernetes cli"
check safe "k9s"            "digit in name"
check safe "k3d"            "digit-bracketed"
check safe "docker"
check safe "argocd"
check safe "atlas"
check safe "azure_cli"      "underscore"
check safe "terraform_docs" "underscore + multi-word"
check safe "git_lfs"
check safe "docker-compose" "hyphen"
check safe "pre_commit"
check safe "p7zip"          "digit + alpha"
check safe "go"             "two-char language tool"
check safe "a"              "single letter (regex minimum length 1)"
check safe "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghij" "exact 64 chars"

# ── Band 2: quarantine (passes the regex but contains tokens that
# strongly suggest prompt-injection framing) ──
check quarantine "ignorepreviousinstructions"  "classic injection phrase squashed"
check quarantine "ignore"                       "single trigger word"
check quarantine "ignore-previous"              "hyphenated still matches"
check quarantine "system"                       "role-prefix term"
check quarantine "systemtool"                   "substring still flags"
check quarantine "assistant"                    "assistant role term"
check quarantine "you-are-now-evil"             "you-are hyphenated"
check quarantine "newrole"                      "role-switch attempt"
check quarantine "prompt"                       "literal prompt"
check quarantine "revealsecrets"                "exfil framing"
check quarantine "exfilsecrets"
check quarantine "rmrfslash"                    "destructive shell intent without metachars"
check quarantine "curlevildomain"
check quarantine "wget"                         "exfil tool name as the candidate"

# ── Band 3: reject (fails the strict regex outright) ──
check reject ""                                "empty input"
check reject "Git"                              "uppercase letter"
check reject "0docker"                          "leads with digit"
check reject "-leading-hyphen"                  "leads with hyphen"
check reject "_leading-underscore"              "leads with underscore"
check reject "foo bar"                          "embedded space"
check reject $'foo\nbar'                        "embedded newline"
check reject $'foo\tbar'                        "embedded tab"
check reject $'foo\x1b[2J'                      "ANSI escape"
check reject $'foo​it'                     "zero-width space (homograph)"
check reject "foo;curl"                         "shell separator"
check reject "foo|sh"                           "pipe to shell"
check reject 'foo$IFS'                          "IFS variable"
check reject 'foo`whoami`'                      "command substitution backticks"
check reject 'foo$(whoami)'                     "command substitution"
check reject "foo&"                             "background operator"
check reject "foo&&bar"                         "and-list"
check reject "foo||bar"                         "or-list"
check reject 'foo>output'                       "redirection"
check reject "foo/bar"                          "path separator"
check reject "../etc/passwd"                    "path traversal"
check reject "foo.bar"                          "dot (Jarvy disallows dots in tool names)"
check reject "café"                             "non-ASCII letter"
check reject "foo+bar"                          "plus sign"
check reject "$(printf 'a%.0s' {1..65})"        "exactly 65 chars — one over the cap"
check reject "$(printf 'a%.0s' {1..200})"       "very-long input (>>64)"

# ── Report ──
echo
echo "── validate_tool_name test results ──"
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo
  echo "Failed cases:"
  printf '%s\n' "${FAILED_CASES[@]}"
  exit 1
fi
echo "All cases matched their expected band."
exit 0
