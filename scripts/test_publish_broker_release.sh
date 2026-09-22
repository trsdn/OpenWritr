#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
publication_script="$SCRIPT_DIR/publish_broker_release.sh"

assignment_count="$(grep -c '^smoke_nonce=' "$publication_script")"
if [[ "$assignment_count" -ne 1 ]]; then
  echo "Expected exactly one smoke_nonce assignment, found $assignment_count." >&2
  exit 1
fi

assignment_line="$(grep '^smoke_nonce=' "$publication_script")"
expected_assignment='smoke_nonce="$(python3 -c '\''import uuid; print("smoke-" + uuid.uuid4().hex)'\'')"'
if [[ "$assignment_line" != "$expected_assignment" ]]; then
  echo "Unexpected smoke_nonce assignment: $assignment_line" >&2
  exit 1
fi

smoke_nonce="$(python3 -c 'import uuid; print("smoke-" + uuid.uuid4().hex)')"
if [[ ! "$smoke_nonce" =~ ^smoke-[0-9a-f]{32}$ ]]; then
  echo "Invalid smoke nonce: $smoke_nonce" >&2
  exit 1
fi
