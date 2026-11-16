#!/usr/bin/env bash
set -euo pipefail

# The app version counts in decades: the patch runs from 0 to 9 and then rolls
# into the minor, which rolls into the major at 9 as well. Both the release
# script and the version bump call this, so the two can never disagree about
# what the next version is.
version="${1:-}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "next_version.sh expects a version like 1.0.9, got: ${version:-<empty>}" >&2
  exit 64
fi

IFS='.' read -r major minor patch <<<"$version"

if ((patch < 9)); then
  patch=$((patch + 1))
else
  patch=0
  if ((minor < 9)); then
    minor=$((minor + 1))
  else
    minor=0
    major=$((major + 1))
  fi
fi

echo "$major.$minor.$patch"

