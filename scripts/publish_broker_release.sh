#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY="trsdn/OpenWritr"
AUTHORIZED_ACTOR_ID="24534196"
BROKER_REPOSITORY="trsdn/macos-notarization-broker"
BROKER_REPOSITORY_ID="1315404585"
BROKER_WORKFLOW_ID="322509883"

tag="${1:-}"
artifact_dir="${2:-}"
if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ || -z "$artifact_dir" ]]; then
  echo "Usage: $0 vX.Y.Z BROKER_ARTIFACT_DIRECTORY" >&2
  exit 2
fi

for tool in cmp gh python3 shasum; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Required tool not found: $tool" >&2
    exit 1
  }
done
gh auth status >/dev/null
actor_id="$(gh api user --jq '.id')"
if [[ "$actor_id" != "$AUTHORIZED_ACTOR_ID" ]]; then
  echo "Only the authorized OpenWritr maintainer may create or publish releases." >&2
  exit 1
fi

version="${tag#v}"
artifact_dir="$(cd "$artifact_dir" && pwd)"
read -r broker_run_id broker_run_attempt broker_commit request_id < <(
  python3 - "$artifact_dir/provenance.json" <<'PY'
import json
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
if path.is_symlink() or not path.is_file():
    raise SystemExit("Supplied broker directory has no regular provenance.json")
provenance = json.loads(path.read_text(encoding="utf-8"))
broker = provenance.get("broker", {})
values = (
    str(broker.get("run_id", "")),
    str(broker.get("run_attempt", "")),
    str(broker.get("commit_sha", "")),
    str(provenance.get("request_id", "")),
)
patterns = (r"[0-9]+", r"[1-9][0-9]*", r"[0-9a-f]{40}", r"[A-Za-z0-9._-]{1,80}")
if any(re.fullmatch(pattern, value) is None for pattern, value in zip(patterns, values)):
    raise SystemExit("Supplied broker provenance has invalid run metadata")
print("\t".join(values))
PY
)

read -r run_repository_id run_workflow_id run_event run_branch run_sha \
  run_attempt run_actor_id run_status run_conclusion < <(
  gh api "repos/$BROKER_REPOSITORY/actions/runs/$broker_run_id" \
    --jq '[.repository.id, .workflow_id, .event, .head_branch, .head_sha, .run_attempt, .actor.id, .status, .conclusion] | @tsv'
)
if [[ "$run_repository_id" != "$BROKER_REPOSITORY_ID" ||
      "$run_workflow_id" != "$BROKER_WORKFLOW_ID" ||
      "$run_event" != "workflow_dispatch" ||
      "$run_branch" != "main" ||
      "$run_sha" != "$broker_commit" ||
      "$run_attempt" != "$broker_run_attempt" ||
      "$run_actor_id" != "$AUTHORIZED_ACTOR_ID" ||
      "$run_status" != "completed" ||
      "$run_conclusion" != "success" ]]; then
  echo "Broker workflow run identity or conclusion does not match the provenance." >&2
  exit 1
fi

artifact_name="openwritr-${version}-${request_id}"
artifact_rows="$(
  gh api "repos/$BROKER_REPOSITORY/actions/runs/$broker_run_id/artifacts" \
    --jq ".artifacts[] | select(.name == \"$artifact_name\") | [.id, .digest, .expired] | @tsv"
)"
artifact_count="$(awk 'NF { count += 1 } END { print count + 0 }' <<< "$artifact_rows")"
if [[ "$artifact_count" != "1" ]]; then
  echo "Broker run does not contain exactly one correlated artifact named $artifact_name." >&2
  exit 1
fi
read -r artifact_id artifact_digest artifact_expired <<< "$artifact_rows"
if [[ ! "$artifact_id" =~ ^[0-9]+$ ||
      ! "$artifact_digest" =~ ^sha256:[0-9a-f]{64}$ ||
      "$artifact_expired" != "false" ]]; then
  echo "Broker workflow artifact is invalid, expired, or missing its GitHub digest." >&2
  exit 1
fi

work_dir="$(mktemp -d)"
notes_file="$work_dir/release-notes.md"
artifact_zip="$work_dir/broker-artifact.zip"
verified_dir="$work_dir/verified"
cleanup() {
  rm -rf -- "$work_dir"
}
trap cleanup EXIT

gh api "repos/$BROKER_REPOSITORY/actions/artifacts/$artifact_id/zip" > "$artifact_zip"
downloaded_digest="$(shasum -a 256 "$artifact_zip" | cut -d' ' -f1)"
if [[ "$downloaded_digest" != "${artifact_digest#sha256:}" ]]; then
  echo "Downloaded broker artifact digest does not match GitHub's immutable artifact record." >&2
  exit 1
fi
python3 - "$artifact_zip" "$verified_dir" <<'PY'
import pathlib
import stat
import sys
import zipfile

archive = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
destination.mkdir()
with zipfile.ZipFile(archive) as bundle:
    for entry in bundle.infolist():
        path = pathlib.PurePosixPath(entry.filename)
        mode = entry.external_attr >> 16
        if path.is_absolute() or ".." in path.parts or stat.S_ISLNK(mode):
            raise SystemExit(f"Unsafe path in broker artifact: {entry.filename}")
    bundle.extractall(destination)
PY

artifact_dir="$verified_dir"
source_sha="$(python3 "$SCRIPT_DIR/verify_broker_artifacts.py" "$artifact_dir" "$tag")"
bash "$SCRIPT_DIR/verify_remote_release_tag.sh" "$tag" "$source_sha" "$REPOSITORY"

asset_base="OpenWritr-v${version}-macOS-arm64"
asset_names=(
  "$asset_base.zip"
  "$asset_base.zip.sha256"
  "$asset_base.dmg"
  "$asset_base.dmg.sha256"
  "OpenWritr-${version}.dmg"
)
assets=()
for name in "${asset_names[@]}"; do
  path="$artifact_dir/$name"
  [[ -f "$path" && ! -L "$path" ]] || {
    echo "Expected release file is missing or unsafe: $path" >&2
    exit 1
  }
  assets+=("$path")
done

verify_release_bytes() {
  local stage="$1"
  local download_dir="$work_dir/release-$stage"
  rm -rf -- "$download_dir"
  mkdir -p "$download_dir"
  gh release download "$tag" --repo "$REPOSITORY" --dir "$download_dir" \
    --pattern "$asset_base.zip" \
    --pattern "$asset_base.zip.sha256" \
    --pattern "$asset_base.dmg" \
    --pattern "$asset_base.dmg.sha256" \
    --pattern "OpenWritr-${version}.dmg"
  for name in "${asset_names[@]}"; do
    if ! cmp -s "$artifact_dir/$name" "$download_dir/$name"; then
      echo "$stage release asset differs from the authenticated broker artifact: $name" >&2
      exit 1
    fi
  done
}

changelog="$(
  gh api "repos/$REPOSITORY/contents/CHANGELOG.md?ref=$tag" \
    -H "Accept: application/vnd.github.raw"
)"
held="$(
  printf '%s\n' "$changelog" | awk '
    tolower($0) ~ /^##[ \t]+\[?unreleased\]?/ { capture = 1; next }
    capture && /^## / { exit }
    capture { print }
  ' | tr -d '[:space:]'
)"
if [[ -n "$held" ]]; then
  echo "CHANGELOG.md still holds entries under Unreleased; promote them into $version." >&2
  exit 1
fi
notes="$(
  printf '%s\n' "$changelog" | awk -v version="$version" '
    BEGIN { gsub(/\./, "\\.", version) }
    $0 ~ "^## \\[?" version "\\]?([ \t]|$)" { capture = 1; next }
    capture && /^## / { exit }
    capture { print }
  '
)"
if [[ -z "${notes//[[:space:]]/}" ]]; then
  echo "CHANGELOG.md has no non-empty entry for $version." >&2
  exit 1
fi
printf '%s\n' "$notes" > "$notes_file"

if gh release view "$tag" --repo "$REPOSITORY" >/dev/null 2>&1; then
  echo "Release or draft $tag already exists; refusing an overlapping or resumed handoff." >&2
  echo "For a failed unpublished attempt, the maintainer must delete the draft before starting again." >&2
  exit 1
fi
gh release create "$tag" --repo "$REPOSITORY" \
  --verify-tag --draft --title "OpenWritr $version" --notes-file "$notes_file"

bash "$SCRIPT_DIR/verify_release_asset_contract.sh" \
  subset "$tag" "$REPOSITORY" "${asset_names[@]}"
gh release upload "$tag" --repo "$REPOSITORY" "${assets[@]}"
bash "$SCRIPT_DIR/verify_release_asset_contract.sh" \
  exact "$tag" "$REPOSITORY" "${asset_names[@]}"
verify_release_bytes "draft-before-smoke"

existing_runs="$(
  gh run list --repo "$REPOSITORY" --workflow smoke-test.yml \
    --event workflow_dispatch --limit 30 --json databaseId --jq '.[].databaseId'
)"
gh workflow run smoke-test.yml --repo "$REPOSITORY" --ref main --field "tag=$tag"

run_id=""
for _ in $(seq 1 30); do
  run_id="$(
    gh run list --repo "$REPOSITORY" --workflow smoke-test.yml \
      --event workflow_dispatch --branch main --limit 30 \
      --json databaseId,displayTitle \
      --jq ".[] | select(.displayTitle == \"Smoke-test OpenWritr $tag\") | .databaseId" |
      while IFS= read -r candidate; do
        if ! grep -Fxq "$candidate" <<< "$existing_runs"; then
          printf '%s\n' "$candidate"
          break
        fi
      done
  )"
  [[ -n "$run_id" ]] && break
  sleep 2
done
if [[ -z "$run_id" ]]; then
  echo "Could not correlate the smoke-test workflow run for $tag; the draft remains unpublished." >&2
  exit 1
fi
gh run watch "$run_id" --repo "$REPOSITORY" --exit-status

bash "$SCRIPT_DIR/verify_remote_release_tag.sh" "$tag" "$source_sha" "$REPOSITORY"
bash "$SCRIPT_DIR/verify_release_asset_contract.sh" \
  exact "$tag" "$REPOSITORY" "${asset_names[@]}"
verify_release_bytes "draft-after-smoke"
if [[ "$(gh release view "$tag" --repo "$REPOSITORY" --json isDraft --jq .isDraft)" != "true" ]]; then
  echo "Release $tag stopped being a draft before publication." >&2
  exit 1
fi

gh release edit "$tag" --repo "$REPOSITORY" --draft=false
if [[ "$(gh release view "$tag" --repo "$REPOSITORY" --json isDraft --jq .isDraft)" != "false" ]]; then
  echo "Release $tag is still a draft." >&2
  exit 1
fi
bash "$SCRIPT_DIR/verify_release_asset_contract.sh" \
  exact "$tag" "$REPOSITORY" "${asset_names[@]}"
verify_release_bytes "published"

echo "Published https://github.com/$REPOSITORY/releases/tag/$tag after smoke run $run_id passed."
