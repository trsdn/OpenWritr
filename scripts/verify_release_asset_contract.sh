#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
release_tag="${2:-}"
repository="${3:-${GITHUB_REPOSITORY:-}}"
shift_count=3

if [[ "$mode" != "subset" && "$mode" != "exact" ]]; then
  echo "Asset verification mode must be subset or exact: $mode" >&2
  exit 1
fi
if [[ ! "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
  echo "Release tag must be a version such as v1.2.1: $release_tag" >&2
  exit 1
fi
if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "Repository must use the OWNER/REPO format: $repository" >&2
  exit 1
fi
if (($# <= shift_count)); then
  echo "At least one expected release asset name is required." >&2
  exit 1
fi
command -v gh >/dev/null 2>&1 || {
  echo "GitHub CLI is required to verify release assets." >&2
  exit 1
}

contains_name() {
  local expected="$1"
  local candidate
  shift
  for candidate in "$@"; do
    [[ "$candidate" == "$expected" ]] && return 0
  done
  return 1
}

shift "$shift_count"
expected_assets=("$@")
for name in "${expected_assets[@]}"; do
  if [[ -z "$name" || "$name" == */* ]]; then
    echo "Expected release asset must be a non-empty file name: $name" >&2
    exit 1
  fi
done

asset_output="$(
  gh release view "$release_tag" --repo "$repository" \
    --json assets --jq '.assets[].name'
)"
current_assets=()
while IFS= read -r name; do
  if [[ -n "$name" ]]; then
    current_assets+=("$name")
  fi
done <<< "$asset_output"

for name in "${current_assets[@]-}"; do
  [[ -z "$name" ]] && continue
  if ! contains_name "$name" "${expected_assets[@]}"; then
    echo "Draft release $release_tag contains unexpected asset: $name" >&2
    exit 1
  fi
done

if [[ "$mode" == "exact" ]]; then
  if ((${#current_assets[@]} != ${#expected_assets[@]})); then
    echo "Release $release_tag has ${#current_assets[@]} assets; expected ${#expected_assets[@]}." >&2
    exit 1
  fi

  for name in "${expected_assets[@]}"; do
    if ! contains_name "$name" "${current_assets[@]}"; then
      echo "Release $release_tag is missing expected asset: $name" >&2
      exit 1
    fi
  done
fi

echo "Release $release_tag asset contract passed in $mode mode."
