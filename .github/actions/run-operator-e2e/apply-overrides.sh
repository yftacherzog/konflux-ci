#!/usr/bin/env bash
#
# Applies ref-overrides and image-overrides to konflux-ci operator manifests,
# then rebuilds affected component manifests.
#
# Repo kustomization files (operator/upstream-kustomizations/) are never modified.
# When overrides are set, a temporary copy is used; overrides and rebuild run
# against that copy only. The repo's choice of digest vs tag per image stays as-is.
#
# Image overrides: upstream workflows can only supply a tag (e.g. commit SHA).
# For images listed in IMAGE_OVERRIDES we normalize digest -> newName+newTag only
# in the temp copy and only for that run; all other images keep their original
# digest or tag in the repo and in the temp copy.
#
# Requires: jq, yq (mikefarah yq / Go yq) on PATH.
#
# Usage:
#   REF_OVERRIDES='{"release-service":"abc123"}' \
#   IMAGE_OVERRIDES=$'quay.io/konflux-ci/konflux-ui|quay.io/org/konflux-ui:on-pr-xyz\n' \
#   apply-overrides.sh REPO_ROOT
#
# Inputs (env):
#   REPO_ROOT          - Path to konflux-ci repo root (required).
#   REF_OVERRIDES      - JSON object component name -> revision (optional).
#   IMAGE_OVERRIDES    - Multiline "released_image|output_image" (optional).
#
set -euo pipefail

REPO_ROOT="${1:-}"
if [[ -z "${REPO_ROOT}" || ! -d "${REPO_ROOT}" ]]; then
  echo "Usage: $0 REPO_ROOT" >&2
  echo "  REPO_ROOT must be the path to konflux-ci repo root." >&2
  exit 1
fi
REPO_ROOT="$(cd "${REPO_ROOT}" && pwd)"

SOURCE_UPSTREAM_DIR="${REPO_ROOT}/operator/upstream-kustomizations"
MANIFESTS_DIR="${REPO_ROOT}/operator/pkg/manifests"
UPSTREAM_DIR="${SOURCE_UPSTREAM_DIR}"
# Relative path from operator/pkg/manifests to UPSTREAM_DIR (for kustomize build)
BUILD_SRC_REL="../../upstream-kustomizations"

# If any overrides are set, work on a temporary copy so we never modify repo kustomizations.
# Rebuild writes to operator/pkg/manifests; we backup that dir and caller restores it after deploy.
if [[ -n "${REF_OVERRIDES:-}" && "${REF_OVERRIDES}" != "{}" ]] || [[ -n "${IMAGE_OVERRIDES:-}" ]]; then
  TMP_UPSTREAM="${REPO_ROOT}/.tmp/upstream-kustomizations"
  TMP_MANIFESTS_BACKUP="${REPO_ROOT}/.tmp/manifests-backup"
  rm -rf "${TMP_UPSTREAM}" "${TMP_MANIFESTS_BACKUP}"
  cp -r "${SOURCE_UPSTREAM_DIR}" "${TMP_UPSTREAM}"
  cp -r "${MANIFESTS_DIR}" "${TMP_MANIFESTS_BACKUP}"
  UPSTREAM_DIR="${TMP_UPSTREAM}"
  BUILD_SRC_REL="../../.tmp/upstream-kustomizations"
  echo "Using temporary copy of upstream-kustomizations for overrides (repo unchanged). Manifests backup at .tmp/manifests-backup for restore after deploy." >&2
fi

# ---- Ref overrides: update ?ref= and newTag in kustomization files ----
apply_ref_overrides() {
  local ref_overrides="${REF_OVERRIDES:-}"
  if [[ -z "${ref_overrides}" || "${ref_overrides}" == "{}" ]]; then
    return 0
  fi

  local components
  components=$(echo "${ref_overrides}" | jq -r 'keys[]' 2>/dev/null || true)
  if [[ -z "${components}" ]]; then
    return 0
  fi

  for component in ${components}; do
    local revision
    revision=$(echo "${ref_overrides}" | jq -r --arg c "${component}" '.[$c]')
    if [[ -z "${revision}" || "${revision}" == "null" ]]; then
      continue
    fi

    local dir="${UPSTREAM_DIR}/${component}"
    if [[ ! -d "${dir}" ]]; then
      echo "  [ref] component ${component}: directory not found, skipping" >&2
      continue
    fi

    while IFS= read -r -d '' file; do
      # Update ref= in resources[] (URLs) and newTag in images[] to new revision
      if REVISION="${revision}" yq eval '
        (.resources[]? | select(type == "!!str" and test("ref=[a-f0-9]{40}"))) |= sub("ref=[a-f0-9]{40}", "ref=" + strenv(REVISION))
        | (.images[]? | select(.newTag and (.newTag | type == "!!str") and (.newTag | test("^[a-f0-9]{40}$")))) |= .newTag = strenv(REVISION)
      ' "${file}" > "${file}.tmp" 2>/dev/null && mv "${file}.tmp" "${file}"; then
        echo "  [ref] ${file}: ref/newTag -> ${revision}" >&2
      fi
    done < <(find "${dir}" -type f \( -name 'kustomization.yaml' -o -name 'kustomization.yml' \) -print0 2>/dev/null)
  done
}

# Parse output image into newName (repo) and newTag (tag) as JSON array [newName, newTag].
parse_output_image() {
  local output_image="$1"
  if [[ "${output_image}" == *"@"* ]]; then
    jq -n -c --arg repo "${output_image%%@*}" --arg tag "${output_image#*@}" '[$repo, $tag]'
  elif [[ "${output_image}" == *":"* ]]; then
    jq -n -c --arg repo "${output_image%%:*}" --arg tag "${output_image#*:}" '[$repo, $tag]'
  else
    jq -n -c --arg repo "${output_image}" --arg tag "latest" '[$repo, $tag]'
  fi
}

# Apply image overrides: in the temp kustomization copy only, for image entries that match
# an IMAGE_OVERRIDES line and use digest, set newName+newTag and remove digest. All other
# images keep their original digest or tag (repo style unchanged).
apply_image_overrides_kustomization() {
  local overrides="${IMAGE_OVERRIDES:-}"
  if [[ -z "${overrides}" ]]; then
    return 0
  fi

  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ -z "${line}" ]]; then
      continue
    fi

    local released output_image
    released="${line%%|*}"
    output_image="${line#*|}"
    if [[ -z "${released}" || -z "${output_image}" ]]; then
      continue
    fi

    local new_name new_tag
    new_name=$(parse_output_image "${output_image}" | jq -r '.[0]')
    new_tag=$(parse_output_image "${output_image}" | jq -r '.[1]')

    while IFS= read -r -d '' file; do
      # Skip if file doesn't reference this image or have digest (yq outputs array, jq counts)
      if [[ $(RELEASED="${released}" yq eval -o=json '[.images[]? | select(.name == strenv(RELEASED) or .newName == strenv(RELEASED))]' "${file}" 2>/dev/null | jq 'length') -eq 0 ]]; then
        continue
      fi
      if [[ $(yq eval -o=json '[.images[]? | select(.digest)]' "${file}" 2>/dev/null | jq 'length') -eq 0 ]]; then
        continue
      fi
      # Update matching image entry: set newName, newTag, remove digest (keep other image entries unchanged)
      export RELEASED NEW_NAME NEW_TAG
      yq eval -i '(.images[] | select(.name == strenv(RELEASED) or .newName == strenv(RELEASED))) |= (.newName = strenv(NEW_NAME) | .newTag = strenv(NEW_TAG) | del(.digest))' "${file}" 2>/dev/null && echo "  [image] ${file}: ${released} -> newName=${new_name}, newTag=${new_tag}" >&2
    done < <(find "${UPSTREAM_DIR}" -type f \( -name 'kustomization.yaml' -o -name 'kustomization.yml' \) -print0 2>/dev/null)
  done <<< "${overrides}"
}

# Replace image references in built manifests (multi-doc YAML).
# Any string value that equals released or starts with released: or released@ is replaced with output_image.
apply_image_overrides_in_manifests() {
  local overrides="${IMAGE_OVERRIDES:-}"
  if [[ -z "${overrides}" ]]; then
    return 0
  fi

  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ -z "${line}" ]]; then
      continue
    fi

    local released output_image
    released="${line%%|*}"
    output_image="${line#*|}"
    if [[ -z "${released}" || -z "${output_image}" ]]; then
      continue
    fi

    # Regex matching: exact released, or released:..., or released@... (escape dots for regex)
    local regex
    regex="^$(printf '%s' "${released}" | sed 's/\./\\./g')($|:|@)"

    find "${MANIFESTS_DIR}" -name 'manifests.yaml' -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
      match_count=$(REGEX="${regex}" yq eval-all -o=json '[.. | select(tag == "!!str" and test(strenv(REGEX)))]' "${f}" 2>/dev/null | jq -s 'map(length) | add // 0')
      if [[ "${match_count:-0}" -eq 0 ]]; then
        continue
      fi
      REGEX="${regex}" OUTPUT_IMAGE="${output_image}" yq eval-all -i '(.. | select(tag == "!!str" and test(strenv(REGEX)))) |= strenv(OUTPUT_IMAGE)' "${f}" 2>/dev/null && echo "  [manifest] ${f}: replaced ${released} with ${output_image}" >&2
    done
  done <<< "${overrides}"
}

# ---- Rebuild manifests for all components ----
rebuild_manifests() {
  local components
  components=$(find "${UPSTREAM_DIR}" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort)
  for component in ${components}; do
    local src="${UPSTREAM_DIR}/${component}"
    local out="${MANIFESTS_DIR}/${component}"
    if [[ ! -d "${src}" ]]; then
      continue
    fi
    mkdir -p "${out}"
    local src_rel="${BUILD_SRC_REL}/${component}"
    local out_manifest="${REPO_ROOT}/operator/pkg/manifests/${component}/manifests.yaml"
    if ! (cd "${REPO_ROOT}/operator/pkg/manifests" && kustomize build "${src_rel}" > "${out_manifest}" 2>/dev/null); then
      echo "  [rebuild] ${component}: kustomize build failed" >&2
      continue
    fi
    echo "  [rebuild] ${component}" >&2
  done
}

# ---- Main ----
echo "Applying ref overrides..." >&2
apply_ref_overrides

echo "Applying image overrides (kustomization: digest -> newTag)..." >&2
apply_image_overrides_kustomization

echo "Rebuilding manifests..." >&2
mkdir -p "${MANIFESTS_DIR}"
rebuild_manifests

echo "Applying image overrides (built manifests)..." >&2
apply_image_overrides_in_manifests

# Caller must restore operator/pkg/manifests from .tmp/manifests-backup after building/deploying the operator.
echo "Done." >&2
