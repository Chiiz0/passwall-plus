#!/usr/bin/env bash
# The only public publisher: stage privately, verify uploads, then expose latest.
set -euo pipefail
: "${GITHUB_REPOSITORY:?}" "${GITHUB_REF_NAME:?}"
source "$(dirname "$0")/../versions.env"
[[ "$GITHUB_REF_NAME" =~ ^firmware-v${OPENWRT_VERSION//./\.}-r[0-9]+$ ]] || { echo 'Firmware tag does not match pinned OpenWrt version' >&2; exit 1; }
dist=${1:?release directory required}
python3 "$(dirname "$0")/release-manifest.py" "$dist" --verify
# Never overwrite a public release, or accidentally publish an incomplete retry.
if gh release view "$GITHUB_REF_NAME" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
    echo 'Release already exists; inspect the existing release before retrying.' >&2
    exit 1
fi
notes=(--generate-notes)
notes_file="$(dirname "$0")/../releases/${GITHUB_REF_NAME#firmware-v}.md"
[[ ! -f "$notes_file" ]] || notes=(--notes-file "$notes_file")
gh release create "$GITHUB_REF_NAME" --repo "$GITHUB_REPOSITORY" --verify-tag --draft \
    "${notes[@]}" --title "PassWall Plus OpenWrt ${GITHUB_REF_NAME#firmware-v}" "$dist"/*
verify_dir=$(mktemp -d)
trap 'rm -rf -- "$verify_dir"' EXIT
gh release download "$GITHUB_REF_NAME" --repo "$GITHUB_REPOSITORY" --dir "$verify_dir"
cmp "$dist/SHA256SUMS" "$verify_dir/SHA256SUMS"
cmp "$dist/release-manifest.json" "$verify_dir/release-manifest.json"
python3 "$(dirname "$0")/release-manifest.py" "$verify_dir" --verify
gh release edit "$GITHUB_REF_NAME" --repo "$GITHUB_REPOSITORY" --draft=false --latest
