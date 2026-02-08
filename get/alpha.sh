#!/usr/bin/env bash
set -euo pipefail

OWNER="ByteCraftServices"
REPO="ddpc"
BRANCH="alpha"

# Optional: wenn du Rate-Limits umgehen willst (für private Repos nötig)
# PERSONAL_TOKEN="ghp_..."  # export PERSONAL_TOKEN=...

api="https://api.github.com/repos/${OWNER}/${REPO}/releases"

auth_header=()
if [[ -n "${PERSONAL_TOKEN:-}" ]]; then
  auth_header=(-H "Authorization: Bearer ${PERSONAL_TOKEN}")
fi

# 1) Neueste Release finden, deren target_commitish == alpha (und optional prerelease==true)
release_json="$(
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    "${auth_header[@]}" \
    "${api}?per_page=100" \
  | jq -r --arg br "$BRANCH" '
      map(select(.target_commitish == $br))
      | .[0]
    '
)"

tag="$(jq -r '.tag_name' <<<"$release_json")"
asset_url="$(jq -r '.assets[0].browser_download_url // empty' <<<"$release_json")"

if [[ -z "$tag" || "$tag" == "null" ]]; then
  echo "Kein Release für Branch '${BRANCH}' gefunden." >&2
  exit 1
fi

if [[ -z "$asset_url" ]]; then
  echo "Release '${tag}' gefunden, aber es hat keine Assets. (Source zips wären zipball_url/tarball_url)" >&2
  # Fallback auf Source ZIP des Releases (Tag-basiert):
  asset_url="$(jq -r '.zipball_url' <<<"$release_json")"
fi

out="${REPO}-${BRANCH}-${tag}.zip"
echo "Lade herunter: $asset_url"
curl -fL --retry 3 -o "$out" "$asset_url"
echo "OK: $out"