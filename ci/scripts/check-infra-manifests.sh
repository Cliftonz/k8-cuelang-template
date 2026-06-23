#!/usr/bin/env bash
# Drift-check pinned infrastructure components against upstream.
#
# Components:
#   - Helm charts pinned via VAR="${VAR:-X}" in infrastructure/*/install.sh
#   - Crossplane Providers/Functions pinned via `package: <oci>:<tag>` YAML
#     (queried directly from xpkg.upbound.io via the Docker Registry v2 API,
#     with GitHub releases as fallback)
#   - Plain GitHub-released YAMLs (e.g. metrics-server) pinned via VAR="${VAR:-X}"
#
# Behavior:
#   - Reports drift for every component
#   - Components in INTENTIONAL_PINS are surfaced as info, never failed/auto-PRed
#   - Components without any pin are surfaced as warnings (don't fail)
#   - In CI (GITHUB_ACTIONS=true), opens a PR per drifted component bumping
#     the pinned version. Supersedes any older drift PR for the same component.
#   - Exits 1 if any non-intentional drift exists
#
# Env:
#   GITHUB_TOKEN   — required for auto-PR
#   GITHUB_ACTIONS — set by Actions; controls auto-PR mode

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "${script_dir}/../.." && pwd)"

ci_mode="${GITHUB_ACTIONS:-false}"
drift=0

# --- intentional pins ----------------------------------------------------

declare -A INTENTIONAL_PINS=(
  [crossplane-uxp]="Upbound stable repo serves -up pre-release suffixes; bumps require manual review (install.sh:87-88)"
  [longhorn]="Longhorn chart has known upstream bugs in newer minors; manual review required"
)

# --- helpers -------------------------------------------------------------

clean_semver() { grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' || true; }

helm_repo_init() {
  helm repo add upbound-stable https://charts.upbound.io/stable >/dev/null 2>&1 || true
  helm repo add longhorn       https://charts.longhorn.io       >/dev/null 2>&1 || true
  helm repo add cnpg           https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
  helm repo update >/dev/null
}

helm_latest() {
  local chart_ref="$1" devel_flag="${2:-}"
  if [[ -n "${devel_flag}" ]]; then
    helm search repo "${chart_ref}" "${devel_flag}" -o json 2>/dev/null | jq -r '.[0].version // empty'
  else
    helm search repo "${chart_ref}" -o json 2>/dev/null | jq -r '.[0].version // empty'
  fi
}

xpkg_latest_tag() {
  local repo="$1" gh_repo="$2"
  local token tag
  token=$(curl -sSL "https://xpkg.upbound.io/service/token?service=xpkg.upbound.io&scope=repository:${repo}:pull" 2>/dev/null | jq -r '.token // empty' || true)
  if [[ -n "${token}" ]]; then
    tag=$(curl -sSL -H "Authorization: Bearer ${token}" "https://xpkg.upbound.io/v2/${repo}/tags/list" 2>/dev/null \
      | jq -r '.tags[]? // empty' \
      | clean_semver \
      | sort -V \
      | tail -1)
    if [[ -n "${tag}" ]]; then
      echo "${tag}"
      return
    fi
  fi
  gh_latest_release "${gh_repo}"
}

gh_latest_release() {
  local gh_repo="$1"
  local args=(-fsSL -H "Accept: application/vnd.github+json")
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  local tag
  tag=$(curl "${args[@]}" "https://api.github.com/repos/${gh_repo}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' || true)
  if [[ -z "${tag}" ]]; then
    tag=$(curl "${args[@]}" "https://api.github.com/repos/${gh_repo}/tags" 2>/dev/null | jq -r '.[0].name // empty' || true)
  fi
  echo "${tag}"
}

# --- auto-PR -------------------------------------------------------------

ensure_drift_label() {
  if [[ "${ci_mode}" != "true" ]]; then return; fi
  gh label create infra-drift --color FBCA04 --description "Auto-detected infrastructure drift" >/dev/null 2>&1 || true
}

open_or_refresh_drift_pr() {
  local key="$1" file="$2" current="$3" latest="$4" pattern="$5"

  if [[ "${ci_mode}" != "true" ]]; then return; fi

  local branch="infra/bump-${key}-${latest}"
  local title="bump ${key} to ${latest}"
  local rel_file="${file#${root_dir}/}"

  if gh pr list --head "${branch}" --state open --json number 2>/dev/null | jq -e '.[0]' >/dev/null; then
    echo "  ↳ PR already open for ${key} at ${latest}"
  else
    git fetch origin main >/dev/null 2>&1 || true
    git checkout -B "${branch}" origin/main >/dev/null 2>&1

    local resolved_pattern="${pattern//NEW/${latest}}"
    sed -i.bak -E "${resolved_pattern}" "${file}"
    rm -f "${file}.bak"

    if git diff --quiet -- "${file}"; then
      echo "  ↳ sed pattern matched nothing in ${rel_file}; cannot auto-PR ${key}" >&2
      git checkout -- "${file}" 2>/dev/null || true
      git checkout main >/dev/null 2>&1 || true
      return
    fi

    git -c user.email=ci@example.com -c user.name=example-org-ci \
      commit -am "chore(infra): bump ${key} from ${current} to ${latest}" >/dev/null
    git push -u origin "${branch}" >/dev/null 2>&1
    gh pr create \
      --base main \
      --head "${branch}" \
      --title "${title}" \
      --body "Auto-detected by check-infra-manifests workflow.

Component **${key}** drift:
- Pinned: \`${current}\`
- Latest upstream: \`${latest}\`

Source: \`${rel_file}\`

Review changelog upstream before merging." \
      --label "infra-drift" >/dev/null
    echo "  ↳ opened PR for ${key} → ${latest}"
    git checkout main >/dev/null 2>&1 || true
  fi

  # Close superseded drift PRs for the same component.
  local open_pr_data
  open_pr_data=$(gh pr list --label infra-drift --state open --json number,title 2>/dev/null || echo '[]')
  echo "${open_pr_data}" | jq -r --arg key "${key}" --arg ver "${latest}" \
    '.[] | select(.title | startswith("bump " + $key + " to ")) | select(.title != "bump " + $key + " to " + $ver) | .number' \
    | while read -r num; do
        [[ -z "${num}" ]] && continue
        gh pr close "${num}" --comment "Superseded by drift PR for ${key} at ${latest}." --delete-branch >/dev/null 2>&1 || true
      done
}

# --- report --------------------------------------------------------------

report() {
  local key="$1" pinned="$2" latest="$3" file="$4" pattern="$5"

  if [[ -z "${pinned}" ]]; then
    echo "warn: ${key}: could not parse pinned version, skipping" >&2
    return
  fi
  if [[ -z "${latest}" ]]; then
    echo "warn: ${key}: could not determine upstream latest, skipping" >&2
    return
  fi

  if [[ "${pinned}" == "${latest}" ]]; then
    echo "  ${key}: up to date (${pinned})"
    return
  fi

  if [[ -n "${INTENTIONAL_PINS[${key}]:-}" ]]; then
    echo "  ${key}: pinned ${pinned}, latest ${latest} (INTENTIONAL: ${INTENTIONAL_PINS[${key}]})"
    return
  fi

  echo "  ${key}: pinned ${pinned}, latest ${latest}"
  drift=1
  open_or_refresh_drift_pr "${key}" "${file}" "${pinned}" "${latest}" "${pattern}"
}

extract_default() { grep -E "^${1}=" "$2" 2>/dev/null | head -1 | sed -E 's/.*:-([^"}]+).*/\1/' || true; }

# --- main ----------------------------------------------------------------

helm_repo_init
ensure_drift_label

echo "## Helm chart drift"

file="${root_dir}/infrastructure/crossplane/install.sh"
pinned=$(extract_default CHART_VERSION "${file}")
latest=$(helm_latest upbound-stable/crossplane --devel)
report "crossplane-uxp" "${pinned}" "${latest}" "${file}" \
  's|(CHART_VERSION="\$\{CROSSPLANE_CHART_VERSION:-)[^"}]+(\}")|\1NEW\2|'

file="${root_dir}/infrastructure/longhorn/install.sh"
pinned=$(extract_default CHART_VERSION "${file}")
latest=$(helm_latest longhorn/longhorn)
report "longhorn" "${pinned}" "${latest}" "${file}" \
  's|(CHART_VERSION="\$\{LONGHORN_CHART_VERSION:-)[^"}]+(\}")|\1NEW\2|'

cnpg_latest=$(helm_latest cnpg/cloudnative-pg)
echo "  cloudnative-pg: UNPINNED in install.sh; upstream latest is ${cnpg_latest:-unknown} (consider adding CHART_VERSION pin)"

echo ""
echo "## Crossplane Provider / Function drift (xpkg.upbound.io)"

xpkg_components=(
  "provider-helm|crossplane-contrib/provider-helm|crossplane-contrib/provider-helm|infrastructure/crossplane/providers/helm/provider.yaml"
  "provider-kubernetes|crossplane-contrib/provider-kubernetes|crossplane-contrib/provider-kubernetes|infrastructure/crossplane/providers/kubernetes/provider.yaml"
  "provider-harbor|globallogicuki/provider-harbor|globallogicuki/provider-harbor|infrastructure/crossplane/providers/harbor/provider.yaml"
  "function-patch-and-transform|crossplane-contrib/function-patch-and-transform|crossplane-contrib/function-patch-and-transform|infrastructure/crossplane/functions/patch-and-transform/function.yaml"
  "function-extra-resources|crossplane-contrib/function-extra-resources|crossplane-contrib/function-extra-resources|infrastructure/crossplane/functions/extra-resources/function.yaml"
)

for entry in "${xpkg_components[@]}"; do
  IFS='|' read -r key xpkg_repo gh_repo rel_file <<< "${entry}"
  file="${root_dir}/${rel_file}"
  if [[ ! -f "${file}" ]]; then
    echo "warn: ${key}: ${rel_file} not found, skipping" >&2
    continue
  fi
  pinned=$(grep -E '^[[:space:]]+package:' "${file}" 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '[:space:]' || true)
  latest=$(xpkg_latest_tag "${xpkg_repo}" "${gh_repo}")
  report "${key}" "${pinned}" "${latest}" "${file}" \
    's|^([[:space:]]*package:[[:space:]]*[^:[:space:]]+):[^[:space:]]+[[:space:]]*$|\1:NEW|'
done

echo ""
echo "## GitHub-released YAMLs"

file="${root_dir}/infrastructure/metrics-server/install.sh"
if [[ -f "${file}" ]]; then
  pinned=$(extract_default CERT_APPROVER_VERSION "${file}")
  latest=$(gh_latest_release "alex1989hu/kubelet-serving-cert-approver")
  report "kubelet-serving-cert-approver" "${pinned}" "${latest}" "${file}" \
    's|(CERT_APPROVER_VERSION="\$\{CERT_APPROVER_VERSION:-)[^"}]+(\}")|\1NEW\2|'

  pinned=$(extract_default METRICS_SERVER_VERSION "${file}")
  latest=$(gh_latest_release "kubernetes-sigs/metrics-server")
  report "metrics-server" "${pinned}" "${latest}" "${file}" \
    's|(METRICS_SERVER_VERSION="\$\{METRICS_SERVER_VERSION:-)[^"}]+(\}")|\1NEW\2|'
fi

echo ""
echo "## Helm charts pinned in CUE composites"

# Enumerate every (name, repo, version, file, line) tuple of XHelmRelease
# chart pins across composites/**/helmreleases.cue. Source of truth is the
# CUE rendering — `cue export` collapses all clusters' helm releases into
# the same XHelmRelease shape.
#
# We do NOT scan composites/*.cue with grep because:
#   - chart blocks may span multiple lines / use let-bindings
#   - the same chart can appear in multiple clusters, but should be reported
#     once with a definitive file:line for auto-PR
#
# Strategy:
#   1. Render manifests to JSON, dedupe (name, repo, version) tuples.
#   2. For each unique tuple, locate the *first* helmreleases.cue line
#      whose `version: "X"` matches the pin AND whose surrounding `name:`
#      key matches the chart name (filter prevents false matches when
#      two charts share the same version string).
#   3. helm search for upstream latest, compare, report, optionally auto-PR.
if ! command -v cue >/dev/null 2>&1; then
  echo "warn: cue binary not in PATH; skipping CUE helm-chart drift section" >&2
else
  # Repo aliases must be unique; key on a sha1 prefix of the URL.
  helm_repo_alias() { echo "drift-$(printf '%s' "$1" | shasum | cut -c1-8)"; }

  cd "${root_dir}"
  cue_manifests=$(cue export ./export/ -e manifests -t platform=true -t shared=true --out json 2>/dev/null || echo '[]')

  # Add every distinct repo so `helm search` resolves chart names.
  printf '%s\n' "${cue_manifests}" \
    | jq -r '[.[] | select(.kind=="XHelmRelease") | .spec.chart.repository] | unique | .[]' \
    | while read -r repo; do
        [[ -z "${repo}" ]] && continue
        # Skip OCI repos — `helm search repo` doesn't support them; OCI charts
        # are version-pinned by digest semantics and rarely drift in the way
        # http(s) repos do. They surface as "could not determine upstream".
        [[ "${repo}" == oci://* ]] && continue
        helm repo add "$(helm_repo_alias "${repo}")" "${repo}" >/dev/null 2>&1 || true
      done
  helm repo update >/dev/null 2>&1 || true

  # Group by (name, repo); pick the lowest pinned version (worst case)
  # so a chart that diverges across clusters surfaces the older pin once
  # rather than emitting one row per cluster. semver sort via `sort -V`
  # handles both `1.2.3` and `v1.2.3` shapes correctly.
  printf '%s\n' "${cue_manifests}" \
    | jq -r '.[] | select(.kind=="XHelmRelease") | "\(.spec.chart.name)|\(.spec.chart.repository)|\(.spec.chart.version)"' \
    | sort -t'|' -k1,1 -k2,2 -k3,3V \
    | awk -F'|' '!seen[$1"|"$2]++' \
    | while IFS='|' read -r chart_name chart_repo pinned; do
        [[ -z "${chart_name}" ]] && continue

        if [[ "${chart_repo}" == oci://* ]]; then
          echo "  ${chart_name}: ${pinned} (OCI repo — skipping drift check)"
          continue
        fi

        alias=$(helm_repo_alias "${chart_repo}")
        latest=$(helm_latest "${alias}/${chart_name}")

        # Locate the source file — first composites/*/helmreleases.cue file
        # that contains both this chart name and this pinned version. This
        # gives auto-PR a unique target even when multiple charts coexist.
        source_file=""
        for cand in composites/*/helmreleases.cue; do
          [[ -f "${cand}" ]] || continue
          if awk -v n="${chart_name}" -v v="${pinned}" '
                $0 ~ "name:[[:space:]]+\"" n "\""        { in_chart=1; saw_name=1 }
                in_chart && $0 ~ "version:[[:space:]]+\"" v "\"" { print; found=1; exit }
                /^[[:space:]]*\}/                        { in_chart=0; saw_name=0 }
                END                                      { exit !found }
              ' "${cand}" >/dev/null 2>&1; then
            source_file="${root_dir}/${cand}"
            break
          fi
        done

        # Auto-PR sed: scope the version replace to the chart block whose
        # name matches, so we don't accidentally bump a different chart that
        # happens to share the same version string.
        pattern="/name:[[:space:]]+\"${chart_name}\"/,/version:/{ s|(version:[[:space:]]+\")[^\"]+(\")|\\1NEW\\2| }"
        report "cue-helm-${chart_name}" "${pinned}" "${latest}" "${source_file:-${root_dir}/composites}" "${pattern}"
      done
fi

if [[ "${drift}" -ne 0 ]]; then
  echo ""
  echo "Infrastructure drift detected. See messages above (intentional pins excluded)." >&2
  exit 1
fi

echo ""
echo "All non-intentional infrastructure pins up to date."
