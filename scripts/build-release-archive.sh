#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: build-release-archive.sh <output-dir> [git-ref]" >&2
  exit 1
fi

output_dir="$1"
git_ref="${2:-HEAD}"
version="$(git describe --tags --exact-match "$git_ref" 2>/dev/null || true)"

hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

if [ -z "$version" ]; then
  short_sha="$(git rev-parse --short "$git_ref")"
  version="0.0.0-${short_sha}"
fi

version="${version#v}"
prefix="codex-orbit-${version}"
archive_path="${output_dir}/${prefix}.tar.gz"

mkdir -p "$output_dir"
git archive --format=tar.gz --prefix="${prefix}/" -o "$archive_path" "$git_ref"

sha256="$(hash_file "$archive_path")"

printf 'ARCHIVE_PATH=%s\n' "$archive_path"
printf 'ARCHIVE_SHA256=%s\n' "$sha256"
printf 'ARCHIVE_VERSION=%s\n' "$version"
