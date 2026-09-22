#!/usr/bin/env bash
set -euo pipefail

release_tag="${1:-}"
expected_sha="${2:-}"
repository="${3:-${GITHUB_REPOSITORY:-}}"

if [[ ! "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
  echo "Release tag must be a version such as v1.2.1: $release_tag" >&2
  exit 1
fi
if [[ ! "$expected_sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "Expected release commit is not a full Git SHA: $expected_sha" >&2
  exit 1
fi
if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "Repository must use the OWNER/REPO format: $repository" >&2
  exit 1
fi
command -v gh >/dev/null 2>&1 || {
  echo "GitHub CLI is required to resolve the remote release tag." >&2
  exit 1
}

read -r remote_type remote_sha < <(
  gh api "repos/$repository/git/ref/tags/$release_tag" \
    --jq '[.object.type, .object.sha] | @tsv'
)

tag_depth=0
while [[ "$remote_type" == "tag" ]]; do
  ((tag_depth += 1))
  if ((tag_depth > 5)); then
    echo "Remote tag $release_tag has too many nested tag objects." >&2
    exit 1
  fi
  read -r remote_type remote_sha < <(
    gh api "repos/$repository/git/tags/$remote_sha" \
      --jq '[.object.type, .object.sha] | @tsv'
  )
done

if [[ "$remote_type" != "commit" ]]; then
  echo "Remote tag $release_tag resolves to $remote_type, not a commit." >&2
  exit 1
fi
if [[ "$remote_sha" != "$expected_sha" ]]; then
  echo "Remote tag $release_tag moved from $expected_sha to $remote_sha." >&2
  exit 1
fi

echo "Remote tag $release_tag still resolves to triggering commit $expected_sha."
