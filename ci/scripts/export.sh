#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "${script_dir}/../.." && pwd)"

cluster=""
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)
      cluster="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    *)
      echo "Usage: $0 [--cluster NAME] [--dry-run]" >&2
      exit 1
      ;;
  esac
done

out_dir="${root_dir}/clusters"
cleanup_dir=""

if [[ "${dry_run}" == "true" ]]; then
  cleanup_dir="$(mktemp -d)"
  out_dir="${cleanup_dir}"
fi

if [[ -n "${cluster}" ]]; then
  cue export "${root_dir}/export/" -t cluster="${cluster}" -o "${out_dir}/${cluster}.yaml"
else
  cue export "${root_dir}/export/" -o "${out_dir}/all.yaml"
fi

if [[ "${dry_run}" == "true" ]]; then
  if [[ -d "${root_dir}/clusters" ]]; then
    diff -ru "${root_dir}/clusters" "${out_dir}" || true
  else
    echo "clusters/ does not exist; generated output is in ${out_dir}" >&2
  fi
  rm -rf "${cleanup_dir}"
fi
