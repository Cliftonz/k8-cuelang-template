#!/usr/bin/env bash
# Detect Helm chart-version bumps that would change an IMMUTABLE Kubernetes
# field — the failure mode that wedges provider-helm Releases in
# STATE=failed because `helm upgrade` patches resources in place and the
# apiserver rejects the patch.
#
# Known offenders this catches:
#   - RoleBinding / ClusterRoleBinding   .roleRef            (cf-tunnel 0.0.15→0.0.23)
#   - Deployment/StatefulSet/DaemonSet/
#     ReplicaSet/Job                     .spec.selector
#   - StatefulSet                        .spec.serviceName, volumeClaimTemplates
#   - PersistentVolumeClaim              storageClass/accessModes/volumeMode/size
#   - Service                            .spec.clusterIP (headless ↔ normal)
#
# For every release in composites/<cluster>/helmreleases.cue whose chart
# version differs from the base ref, the chart is rendered with `helm
# template` at BOTH versions (each with its own desired values) and the
# immutable field paths are diffed. Any difference is reported with the
# exact `kubectl delete` that lets the next `helm upgrade` land cleanly.
#
# Resolution of the "from" (old) version:
#   - BASE_REF (default: HEAD) is checked out into a throwaway git worktree
#     and `cue export`-ed. Locally this compares working-tree edits against
#     the last commit; in CI set BASE_REF=origin/<base-branch> to compare a
#     PR head against its base.
#
# Output:
#   - human report on stdout
#   - if REMEDIATION_FILE is set, the `kubectl delete` commands are also
#     written there (one per line) for an opt-in apply step to consume.
#
# Exit status: 0 = no immutable changes; 1 = at least one detected;
#              2 = usage / tooling error.
#
# Env:
#   CLUSTER          cluster name (default: home; or pass as $1)
#   BASE_REF         git ref for the "old" state (default: HEAD)
#   REMEDIATION_FILE path to write `kubectl delete` lines to (optional)

set -euo pipefail

CLUSTER="${1:-${CLUSTER:-home}}"
BASE_REF="${BASE_REF:-HEAD}"
REMEDIATION_FILE="${REMEDIATION_FILE:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "${script_dir}/../.." && pwd)"

for bin in cue helm yq jq git; do
  command -v "$bin" >/dev/null 2>&1 || { echo "error: '$bin' not found in PATH" >&2; exit 2; }
done

composite_dir="composites/${CLUSTER}"
[[ -d "${root_dir}/${composite_dir}" ]] || { echo "error: ${composite_dir} not found" >&2; exit 2; }

workdir="$(mktemp -d)"
worktree=""
cleanup() {
  [[ -n "${worktree}" ]] && git -C "${root_dir}" worktree remove --force "${worktree}" >/dev/null 2>&1 || true
  rm -rf "${workdir}"
}
trap cleanup EXIT

# --- render the desired (NEW) release set from the working tree ----------
new_json="${workdir}/new.json"
( cd "${root_dir}" && cue export "./${composite_dir}" -e helmReleases --out json ) > "${new_json}" 2>"${workdir}/cue.err" || {
  echo "error: cue export of ${composite_dir} helmReleases failed:" >&2
  cat "${workdir}/cue.err" >&2
  exit 2
}

# --- render the base (OLD) release set from BASE_REF via a worktree ------
worktree="${workdir}/base-tree"
git -C "${root_dir}" worktree add --quiet --detach "${worktree}" "${BASE_REF}" || {
  echo "error: could not create worktree for ${BASE_REF}" >&2; exit 2; }
old_json="${workdir}/old.json"
if [[ -d "${worktree}/${composite_dir}" ]]; then
  ( cd "${worktree}" && cue export "./${composite_dir}" -e helmReleases --out json ) > "${old_json}" 2>/dev/null || echo "[]" > "${old_json}"
else
  echo "[]" > "${old_json}"
fi

# --- helpers -------------------------------------------------------------

# Emit normalized "KIND<TAB>NS<TAB>NAME<TAB>FIELD<TAB>VALUE" rows for the
# immutable fields of every object in a rendered manifest (JSON array).
# $1 = release namespace, used when an object omits .metadata.namespace
# (helm template does not inject it). Cluster-scoped kinds stay "-".
immutable_rows() {
  local relns="$1"
  jq -r --arg relns "${relns}" '
    .[] | select(type=="object" and .kind!=null) as $d
    | (if ($d.kind=="ClusterRoleBinding") then "-" else ($d.metadata.namespace // $relns) end) as $ns
    | $d.metadata.name as $name
    | if ($d.kind=="RoleBinding" or $d.kind=="ClusterRoleBinding") then
        "\($d.kind)\t\($ns)\t\($name)\troleRef\t\($d.roleRef|@json)"
      elif ($d.kind=="Deployment" or $d.kind=="DaemonSet" or $d.kind=="ReplicaSet" or $d.kind=="Job") then
        "\($d.kind)\t\($ns)\t\($name)\tselector\t\($d.spec.selector|@json)"
      elif ($d.kind=="StatefulSet") then
        "\($d.kind)\t\($ns)\t\($name)\tselector\t\($d.spec.selector|@json)",
        "\($d.kind)\t\($ns)\t\($name)\tserviceName\t\($d.spec.serviceName // "")",
        "\($d.kind)\t\($ns)\t\($name)\tvolumeClaimTemplates\t\([ ($d.spec.volumeClaimTemplates // [])[] | {n:.metadata.name, sc:.spec.storageClassName, am:.spec.accessModes, size:.spec.resources.requests.storage} ]|@json)"
      elif ($d.kind=="PersistentVolumeClaim") then
        "\($d.kind)\t\($ns)\t\($name)\tpvcSpec\t\({sc:$d.spec.storageClassName, am:$d.spec.accessModes, vm:$d.spec.volumeMode, size:$d.spec.resources.requests.storage}|@json)"
      elif ($d.kind=="Service") then
        "\($d.kind)\t\($ns)\t\($name)\tclusterIPMode\t\(if $d.spec.clusterIP=="None" then "headless" else "clusterip" end)"
      else empty end
  '
}

# Render one chart at a given version with given values JSON → immutable rows.
render_rows() {
  local name="$1" ns="$2" cname="$3" repo="$4" version="$5" valsfile="$6" out="$7"
  local tmpl_err="${workdir}/tmpl.err"
  local ref_args=()
  if [[ "${repo}" == oci://* ]]; then
    ref_args=("${repo}/${cname}" --version "${version}")
  else
    ref_args=("${cname}" --repo "${repo}" --version "${version}")
  fi
  if helm template "${name}" "${ref_args[@]}" \
        --namespace "${ns}" -f "${valsfile}" \
        --no-hooks 2>"${tmpl_err}" \
        | yq ea -o=json '[.]' - 2>/dev/null \
        | immutable_rows "${ns}" > "${out}" 2>/dev/null; then
    return 0
  fi
  echo "WARN: could not render ${name} (${cname} ${version}); skipping immutable diff" >&2
  sed 's/^/    helm: /' "${tmpl_err}" | head -3 >&2 || true
  : > "${out}"
  return 1
}

# --- main loop -----------------------------------------------------------

drift=0
conflicts_report="${workdir}/report.txt"
: > "${conflicts_report}"
[[ -n "${REMEDIATION_FILE}" ]] && : > "${REMEDIATION_FILE}"

count="$(jq 'length' "${new_json}")"
for (( i=0; i<count; i++ )); do
  name="$(jq -r ".[$i].name" "${new_json}")"
  ns="$(jq -r ".[$i].namespace" "${new_json}")"
  cname="$(jq -r ".[$i].chart.name" "${new_json}")"
  repo="$(jq -r ".[$i].chart.repository" "${new_json}")"
  newv="$(jq -r ".[$i].chart.version" "${new_json}")"
  url="$(jq -r ".[$i].chart.url // empty" "${new_json}")"

  oldv="$(jq -r --arg n "$name" '.[] | select(.name==$n) | .chart.version' "${old_json}" | head -1)"

  # No prior entry, unchanged version, or a tarball-URL pin (can't --version) → skip.
  [[ -z "${oldv}" || "${oldv}" == "null" ]] && continue
  [[ "${oldv}" == "${newv}" ]] && continue
  if [[ -n "${url}" ]]; then
    echo "SKIP ${name}: chart.url tarball pin (${oldv}→${newv}); render-diff not supported" >&2
    continue
  fi

  newvals="${workdir}/${name}.new.vals.json"
  oldvals="${workdir}/${name}.old.vals.json"
  jq ".[$i].values // {}" "${new_json}" > "${newvals}"
  jq -r --arg n "$name" '.[] | select(.name==$n) | .values // {}' "${old_json}" > "${oldvals}"
  [[ -s "${oldvals}" ]] || echo "{}" > "${oldvals}"

  oldrows="${workdir}/${name}.old.rows"
  newrows="${workdir}/${name}.new.rows"
  render_rows "${name}" "${ns}" "${cname}" "${repo}" "${oldv}" "${oldvals}" "${oldrows}" || continue
  render_rows "${name}" "${ns}" "${cname}" "${repo}" "${newv}" "${newvals}" "${newrows}" || continue

  # Conflict = same kind/ns/name/field present in both renders with a
  # different immutable value.
  mapfile -t hits < <(awk -F'\t' '
    NR==FNR { k=$1 FS $2 FS $3 FS $4; old[k]=$5; next }
    { k=$1 FS $2 FS $3 FS $4; if (k in old && old[k]!=$5) print $1 FS $2 FS $3 FS $4 }
  ' "${oldrows}" "${newrows}")

  if (( ${#hits[@]} > 0 )); then
    drift=1
    {
      echo "✗ ${name} (${cname} ${oldv} → ${newv}) — immutable field change(s):"
    } >> "${conflicts_report}"
    for h in "${hits[@]}"; do
      IFS=$'\t' read -r kind objns objname field <<<"${h}"
      echo "    ${kind}/${objname} (ns=${objns}) .${field} changed — helm cannot patch in place" >> "${conflicts_report}"
      # Build remediation kubectl delete.
      lc_kind="$(echo "${kind}" | tr '[:upper:]' '[:lower:]')"
      if [[ "${kind}" == "ClusterRoleBinding" ]]; then
        cmd="kubectl delete ${lc_kind} ${objname}"
      else
        cmd="kubectl delete ${lc_kind} ${objname} -n ${objns}"
      fi
      echo "      remediation: ${cmd}  (then re-apply; helm recreates it)" >> "${conflicts_report}"
      [[ -n "${REMEDIATION_FILE}" ]] && echo "${cmd}" >> "${REMEDIATION_FILE}"
    done
    echo "" >> "${conflicts_report}"
  fi
done

# --- output --------------------------------------------------------------

echo "── Helm immutable-field upgrade check (cluster=${CLUSTER}, base=${BASE_REF}) ──"
if (( drift == 0 )); then
  echo "✓ no immutable-field changes in any bumped chart — upgrades can apply in place"
  exit 0
fi

cat "${conflicts_report}"
echo "Immutable-field changes detected. The bumped charts above will fail"
echo "'helm upgrade' (provider-helm Release → STATE=failed) until the listed"
echo "objects are deleted so helm can recreate them. Run the remediation"
echo "deletes, then 'make apply CLUSTER=${CLUSTER}'."
exit 1
