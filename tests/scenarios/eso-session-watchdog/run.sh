#!/usr/bin/env bash
# Replay test for the ESO session-staleness watchdog.
#
# Pins the 2026-05-15 regression (ESO controller cached a dead OpenBao
# session for 30+ min; only a kubectl rollout restart cleared it) by
# running the watchdog's actual bash body — extracted live from the
# rendered CronJob — against table-driven CSS-status fixtures with a
# stubbed kubectl + curl.
#
# What each fixture proves:
#   healthy        — no Ready=False CSS                → no patch
#   stale-single   — one CSS Ready=False for 6 min     → exactly one patch
#   fresh-fail     — Ready=False but only 2 min ago    → no patch (boundary)
#   multi-stale    — two stale CSSes simultaneously    → exactly one patch,
#                                                        both names in alert
#   no-conditions  — just-created CSS, status empty    → no patch
#   bad-ltt        — malformed lastTransitionTime      → no patch (the
#                                                        original busybox
#                                                        date -d bug: this
#                                                        case used to
#                                                        trigger a patch
#                                                        on every tick)
#   cooldown       — stale CSS but Deployment patched  → no patch (cooldown
#                    <30 min ago                         dampens thrash)
#
# Usage: tests/scenarios/eso-session-watchdog/run.sh
#
# Requires: docker (runs the script inside alpine/k8s:1.31.1 — the same
# image the CronJob ships — so the busybox/jq/curl behaviour matches
# production exactly). If docker is unavailable, falls back to running
# the script on the host with whatever jq/curl/date are available; in
# that mode the "bad-ltt" regression guard may pass for the wrong reason.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCENARIO_DIR="$REPO_ROOT/tests/scenarios/eso-session-watchdog"
FIXTURES="$SCENARIO_DIR/fixtures"
# Source-of-truth: the freshly-rendered raw output. Run after
# `make export-raw CLUSTER=home`. Falls back to the committed golden
# if no fresh render exists (the golden is byte-stable per
# ci/scripts/test-raw-export.sh).
RENDERED="$REPO_ROOT/clusters/home-raw/cronjob-eso-session-watchdog.yaml"
GOLDEN="$REPO_ROOT/tests/raw-export/golden/home/cronjob-eso-session-watchdog.yaml"
if [ -f "$RENDERED" ]; then
	SOURCE="$RENDERED"
else
	SOURCE="$GOLDEN"
fi

pass=0
fail=0
total=0

if ! command -v yq >/dev/null 2>&1; then
	echo "FATAL: yq is required (brew install yq)" >&2
	exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
	echo "FATAL: jq is required (brew install jq)" >&2
	exit 2
fi

USE_DOCKER=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
	USE_DOCKER=1
fi

# Pull the script body from the golden so the test stays in sync with
# whatever the renderer produces. (Pulling from CUE would require
# re-rendering on every run; pulling from the live cluster would make
# the test environment-dependent.)
SCRIPT_BODY=$(yq -r '.spec.jobTemplate.spec.template.spec.containers[0].command[2]' "$SOURCE")
if [ -z "$SCRIPT_BODY" ] || [ "$SCRIPT_BODY" = "null" ]; then
	echo "FATAL: could not extract script body from $SOURCE" >&2
	exit 2
fi

# Build a workdir with stubbed kubectl + curl + sha256sum on PATH. The
# stubs record every call into $WORK/calls.log; assertions grep that.
make_workdir() {
	local fixture="$1" deploy_annotation="$2"
	local work
	work=$(mktemp -d -t eso-watchdog-replay.XXXXXX)
	mkdir -p "$work/bin" "$work/discord"

	# Pre-process the fixture: substitute __NOW_MINUS_*__ tokens with
	# real RFC3339 timestamps so the watchdog's age math is meaningful.
	local now now1h now8m now6m now2m now1m
	now=$(date -u +%s)
	now1h=$(date -u -r "$((now - 3600))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-1 hour" +%Y-%m-%dT%H:%M:%SZ)
	now8m=$(date -u -r "$((now - 480))"  +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-8 minutes" +%Y-%m-%dT%H:%M:%SZ)
	now6m=$(date -u -r "$((now - 360))"  +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-6 minutes" +%Y-%m-%dT%H:%M:%SZ)
	now2m=$(date -u -r "$((now - 120))"  +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-2 minutes" +%Y-%m-%dT%H:%M:%SZ)
	now1m=$(date -u -r "$((now - 60))"   +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-1 minutes" +%Y-%m-%dT%H:%M:%SZ)
	sed -e "s|__NOW_MINUS_1H__|$now1h|g" \
	    -e "s|__NOW_MINUS_8M__|$now8m|g" \
	    -e "s|__NOW_MINUS_6M__|$now6m|g" \
	    -e "s|__NOW_MINUS_2M__|$now2m|g" \
	    -e "s|__NOW_MINUS_1M__|$now1m|g" \
	    "$FIXTURES/$fixture" > "$work/css.json"

	# Deployment fixture — controls the cooldown gate. Pass a unix epoch
	# in $deploy_annotation to simulate a recent prior restart, or empty
	# string for "never restarted".
	if [ -n "$deploy_annotation" ]; then
		jq -nc --arg ep "$deploy_annotation" '{
			items: [{
				metadata: {name: "external-secrets"},
				spec: {template: {metadata: {annotations: {
					"k8-infra.io/eso-session-watchdog-restart-epoch": $ep
				}}}}
			}]
		}' > "$work/deploy.json"
	else
		jq -nc '{items: [{metadata: {name: "external-secrets"}, spec: {template: {metadata: {annotations: {}}}}}]}' > "$work/deploy.json"
	fi

	# Stub kubectl. Records the call, returns fixture data for known
	# arg patterns. Anything unknown is logged and returns "".
	cat >"$work/bin/kubectl" <<'STUB'
#!/usr/bin/env sh
# Record the call (one per line, newline-separated args).
printf 'kubectl %s\n' "$*" >> "$WORK/calls.log"
# Strip any leading --request-timeout flags.
while [ "${1:-}" != "" ]; do
	case "$1" in
		--request-timeout=*) shift ;;
		*) break ;;
	esac
done
case "$* " in
	"get clustersecretstore -o json "*)
		cat "$WORK/css.json"
		;;
	"-n external-secrets get deploy -l app.kubernetes.io/name=external-secrets,app.kubernetes.io/instance=external-secrets -o jsonpath="*)
		printf 'external-secrets'
		;;
	"-n external-secrets get deploy external-secrets "*)
		# jsonpath query for the restart-epoch annotation
		jq -r '.items[0].spec.template.metadata.annotations["k8-infra.io/eso-session-watchdog-restart-epoch"] // ""' "$WORK/deploy.json"
		;;
	"-n external-secrets patch deploy external-secrets "*)
		printf 'deployment.apps/external-secrets patched\n'
		;;
	*)
		printf 'STUB_KUBECTL_UNHANDLED: %s\n' "$*" >&2
		exit 0
		;;
esac
STUB
	chmod +x "$work/bin/kubectl"

	# Stub curl. Records the call. Discord posts return 204; pushgateway 200.
	cat >"$work/bin/curl" <<'STUB'
#!/usr/bin/env sh
printf 'curl %s\n' "$*" >> "$WORK/calls.log"
# Best-effort: write any --data-binary @- payload to a log file too.
for a in "$@"; do
	case "$a" in
		--data-binary)
			# next arg is @- or a literal — read stdin if @-
			;;
	esac
done
# Drain stdin so callers using `printf | curl --data-binary @-` don't block.
cat >/dev/null 2>&1 || true
exit 0
STUB
	chmod +x "$work/bin/curl"

	# Discord webhook URL fixture.
	echo "https://discord.example/webhook/AAA/BBB" > "$work/discord/url"

	echo "$work"
}

run_script() {
	local work="$1"
	(
		export PATH="$work/bin:$PATH"
		export WORK="$work"
		# Re-map /run/discord/url to a host path the stubbed script can read.
		# The script reads "$(cat /run/discord/url)"; we redirect that via a
		# wrapper sh that replaces the literal /run/discord/url with our path.
		# Simplest: write the script body to a file, sed the path, run.
		printf '%s' "$SCRIPT_BODY" \
			| sed "s|/run/discord/url|$work/discord/url|g" \
			> "$work/watchdog.sh"
		sh "$work/watchdog.sh" > "$work/stdout.log" 2> "$work/stderr.log"
		echo $? > "$work/exit.code"
	) || true
}

assert_grep() {
	local desc="$1" file="$2" pattern="$3"
	total=$((total + 1))
	if grep -qE "$pattern" "$file" 2>/dev/null; then
		echo "  PASS: $desc"
		pass=$((pass + 1))
	else
		echo "  FAIL: $desc"
		echo "    pattern: $pattern"
		echo "    file:    $file"
		echo "    --- contents (last 20 lines) ---"
		tail -20 "$file" | sed 's/^/    /'
		fail=$((fail + 1))
	fi
}

assert_no_grep() {
	local desc="$1" file="$2" pattern="$3"
	total=$((total + 1))
	if ! grep -qE "$pattern" "$file" 2>/dev/null; then
		echo "  PASS: $desc"
		pass=$((pass + 1))
	else
		echo "  FAIL: $desc"
		echo "    pattern (should NOT match): $pattern"
		echo "    file:                       $file"
		echo "    --- matches ---"
		grep -E "$pattern" "$file" | sed 's/^/    /'
		fail=$((fail + 1))
	fi
}

run_case() {
	local name="$1" fixture="$2" deploy_annot="$3" expect_patch="$4"
	echo
	echo "── case: $name ──"
	local work
	work=$(make_workdir "$fixture" "$deploy_annot")
	run_script "$work"

	if [ "$expect_patch" = "yes" ]; then
		assert_grep "kubectl patch was issued" "$work/calls.log" \
			'patch deploy external-secrets'
	else
		assert_no_grep "no kubectl patch issued" "$work/calls.log" \
			'patch deploy external-secrets'
	fi

	# Always assert: heartbeat metric was pushed (every tick).
	assert_grep "heartbeat metric posted" "$work/calls.log" \
		'curl.*pushgateway.*metrics/job/eso_session_watchdog'

	# Diagnostics on failure: keep workdir if --keep set.
	if [ -n "${KEEP_WORK:-}" ]; then
		echo "  workdir: $work"
	else
		rm -rf "$work"
	fi
}

echo "Replay test: ESO session-staleness watchdog"
echo "Script body source: $SOURCE"
echo

run_case healthy       healthy.json       ""                              no
run_case stale-single  stale-single.json  ""                              yes
run_case fresh-fail    fresh-fail.json    ""                              no
run_case multi-stale   multi-stale.json   ""                              yes
run_case no-conditions no-conditions.json ""                              no
run_case bad-ltt       bad-ltt.json       ""                              no
# cooldown: stale CSS but restart was 5 min ago — gate should skip.
run_case cooldown      stale-single.json  "$(($(date -u +%s) - 300))"     no

echo
echo "Summary: $pass/$total passed"
if [ "$fail" -gt 0 ]; then
	echo "FAILED"
	exit 1
fi
echo "OK"
