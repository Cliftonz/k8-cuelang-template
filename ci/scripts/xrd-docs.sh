#!/usr/bin/env bash
set -euo pipefail

if ! command -v cue >/dev/null 2>&1; then
  echo "cue is required" >&2
  exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "yq is required" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${ROOT_DIR}/docs/api/xrds"
INDEX_PATH="${OUT_DIR}/README.md"
SCHEMA_DIR="${OUT_DIR}/schema"
TMP_PATH="$(mktemp)"

pushd "${ROOT_DIR}" >/dev/null
cue export ./export -e platform.apiDefinitions --out yaml > "${TMP_PATH}"
popd >/dev/null

mkdir -p "${OUT_DIR}"
mkdir -p "${SCHEMA_DIR}"
rm -f "${OUT_DIR}"/*.md
rm -f "${SCHEMA_DIR}"/*.json

{
  echo "# Platform XRD API"
  echo ""
  echo "Generated from CUE XRD definitions. Each XRD has its own file with full schema details."
  echo ""
} > "${INDEX_PATH}"

COUNT=$(yq eval 'length' "${TMP_PATH}")
for i in $(seq 0 $((COUNT - 1))); do
  KIND=$(yq eval ".[${i}].spec.names.kind" "${TMP_PATH}")
  NAME=$(yq eval ".[${i}].metadata.name" "${TMP_PATH}")
  GROUP=$(yq eval ".[${i}].spec.group" "${TMP_PATH}")
  VERSION=$(yq eval ".[${i}].spec.versions[0].name" "${TMP_PATH}")
  API_VERSION="${GROUP}/${VERSION}"
  DESCRIPTION=$(yq eval ".[${i}].spec.versions[0].schema.openAPIV3Schema.description // \"\"" "${TMP_PATH}")
  FILE_SLUG=$(echo "${KIND}" | tr '[:upper:]' '[:lower:]')
  OUT_PATH="${OUT_DIR}/${FILE_SLUG}.md"
  EXAMPLE=$(yq eval ".[${i}].spec.versions[0].schema.openAPIV3Schema.properties.spec.example // \"\"" "${TMP_PATH}")
  REQUIRED=$(yq eval ".[${i}].spec.versions[0].schema.openAPIV3Schema.properties.spec.required // []" "${TMP_PATH}")
  DOCS=$(yq eval ".[${i}].spec.versions[0].schema.openAPIV3Schema.properties.spec.\"x-docs\" // {}" "${TMP_PATH}")
  SPEC_SCHEMA_PATH="${SCHEMA_DIR}/${FILE_SLUG}.json"
  FULL_SCHEMA_PATH="${SCHEMA_DIR}/${FILE_SLUG}.full.json"

  yq eval -o=json ".[${i}].spec.versions[0].schema.openAPIV3Schema.properties.spec" "${TMP_PATH}" > "${SPEC_SCHEMA_PATH}"
  yq eval -o=json "{\"type\":\"object\",\"properties\":{\"apiVersion\":{\"type\":\"string\",\"enum\":[\"${API_VERSION}\"]},\"kind\":{\"type\":\"string\",\"enum\":[\"${KIND}\"]},\"metadata\":{\"type\":\"object\",\"description\":\"Kubernetes object metadata.\"},\"spec\":.[${i}].spec.versions[0].schema.openAPIV3Schema.properties.spec}}" "${TMP_PATH}" > "${FULL_SCHEMA_PATH}"

  {
    echo "---"
    echo "kind: ${KIND}"
    echo "group: ${GROUP}"
    echo "version: ${VERSION}"
    echo "xrd: ${NAME}"
    echo "---"
    echo ""
    echo "# ${KIND}"
    if [ -n "${DESCRIPTION}" ] && [ "${DESCRIPTION}" != "null" ]; then
      echo "${DESCRIPTION}"
      echo ""
    fi
    echo "- XRD: ${NAME}"
    echo "- Group: ${GROUP}"
    echo "- Version: ${VERSION}"
    echo "- Spec schema: ./schema/${FILE_SLUG}.json"
    echo "- Full schema: ./schema/${FILE_SLUG}.full.json"
    echo ""
    echo "## Usage"
    echo ""
    echo "Create a composite resource using this API, then export and apply manifests:"
    echo ""
    printf '%s\n' '```bash'
    echo "make export-split CLUSTER=new-dev"
    echo "kubectl apply -R -f clusters/new-dev/"
    printf '%s\n' '```'
    echo ""
    echo "## Defaults and Policy"
    echo ""
    echo "Tier-based defaults and policy enforcement live in libs/tiers and platform policies."
    echo "See docs/architecture.md and libs/tiers/*.cue for details."
    echo ""
    echo "## Required Fields"
    echo ""
    printf '%s\n' "${REQUIRED}" | yq eval '.[] | "- `" + . + "`"' -
    echo ""
    if [ "${DOCS}" != "{}" ] && [ "${DOCS}" != "null" ]; then
      PROVIDER=$(printf '%s\n' "${DOCS}" | yq eval '.provider // ""' -)
      POLICY=$(printf '%s\n' "${DOCS}" | yq eval '.policyRefs // []' -)
      BEHAVIOR=$(printf '%s\n' "${DOCS}" | yq eval '.behavior // []' -)
      GOTCHAS=$(printf '%s\n' "${DOCS}" | yq eval '.gotchas // []' -)

      if [ -n "${PROVIDER}" ] && [ "${PROVIDER}" != "null" ]; then
        echo "## Provider"
        echo ""
        echo "- ${PROVIDER}"
        echo ""
      fi

      if [ "${POLICY}" != "[]" ]; then
        echo "## Related Policy"
        echo ""
        printf '%s\n' "${POLICY}" | yq eval '.[] | "- " + .' -
        echo ""
      fi

      if [ "${BEHAVIOR}" != "[]" ]; then
        echo "## Behavior"
        echo ""
        printf '%s\n' "${BEHAVIOR}" | yq eval '.[] | "- " + .' -
        echo ""
      fi

      if [ "${GOTCHAS}" != "[]" ]; then
        echo "## Gotchas"
        echo ""
        printf '%s\n' "${GOTCHAS}" | yq eval '.[] | "- " + .' -
        echo ""
      fi
    fi
    echo ""
    echo "## Spec Schema"
    echo ""
    echo "This is the OpenAPI schema for the spec field."
    echo ""
    printf '%s\n' '```yaml'
    yq eval ".[${i}].spec.versions[0].schema.openAPIV3Schema.properties.spec" "${TMP_PATH}"
    printf '%s\n' '```'
    echo ""
    if [ -n "${EXAMPLE}" ] && [ "${EXAMPLE}" != "null" ]; then
      echo "## Example"
      echo ""
      printf '%s\n' '```yaml'
      echo "apiVersion: ${API_VERSION}"
      echo "kind: ${KIND}"
      echo "metadata:"
      echo "  name: example-${FILE_SLUG}"
      echo "spec:"
      printf '%s\n' "${EXAMPLE}" | sed 's/^/  /'
      printf '%s\n' '```'
    fi
  } > "${OUT_PATH}"

  echo "- [${KIND}](./${FILE_SLUG}.md)" >> "${INDEX_PATH}"
done

rm -f "${TMP_PATH}"

echo "Wrote ${INDEX_PATH} and ${OUT_DIR}/*.md"
