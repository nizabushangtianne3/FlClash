#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
next_version="$script_dir/next_version.sh"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

failures=0

expect_next() {
  local current="$1"
  local expected="$2"
  local actual
  actual="$(bash "$next_version" "$current")"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $current should become $expected, got $actual" >&2
    failures=$((failures + 1))
  fi
}

expect_rejected() {
  local value="$1"
  if bash "$next_version" "$value" >/dev/null 2>&1; then
    echo "FAIL: $value should be rejected" >&2
    failures=$((failures + 1))
  fi
}

expect_next 1.0.7 1.0.8
expect_next 1.0.8 1.0.9
expect_next 1.0.9 1.1.0
expect_next 1.1.0 1.1.1
expect_next 1.8.9 1.9.0
expect_next 1.9.0 1.9.1
expect_next 1.9.8 1.9.9
expect_next 1.9.9 2.0.0
expect_next 0.8.99 0.9.0
expect_next 9.9.9 10.0.0
expect_rejected ""
expect_rejected 1.0
expect_rejected 1.0.9.1
expect_rejected v1.0.9

# The bump script reads and rewrites a pubspec, so it has to roll the version
# the same way the helper does.
pub="$temp_dir/pubspec.yaml"
printf 'name: fl_clash\nversion: 1.0.9+2026111401\n' >"$pub"
PUBSPEC_FILE="$pub" bash "$script_dir/bump_version.sh" major >/dev/null
if ! grep -q '^version: 1\.1\.0+2026111401$' "$pub"; then
  echo "FAIL: bumping 1.0.9 should have produced 1.1.0" >&2
  cat "$pub" >&2
  failures=$((failures + 1))
fi

if ((failures > 0)); then
  echo "$failures version check(s) failed" >&2
  exit 1
fi

echo "version checks passed"

