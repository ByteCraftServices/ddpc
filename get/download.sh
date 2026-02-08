#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load PATH_ROOT_DDPC from paths.conf
source "$SCRIPT_DIR/paths.conf"

BRANCH="${1:-main}"
VERSION="${2:-latest}"

# Only main supports a version override; other branches always pull the current head
if [[ "$BRANCH" != "main" ]]; then
	VERSION="latest"
fi

case "$BRANCH" in
	main|alpha|beta) ;;
	*)
		echo "Unbekannter Branch '$BRANCH', nutze 'main'."
		BRANCH="main"
		VERSION="${VERSION:-latest}"
		;;
esac

download_branch_release() {
	local branch="$1"
	local dest="$2"

	if ! command -v jq >/dev/null 2>&1; then
		echo "Für Downloads der Branch-Releases wird jq benötigt." >&2
		exit 1
	fi

	local api="https://api.github.com/repos/ByteCraftServices/ddpc/releases"
	local curl_cmd=(curl -fsSL -H "Accept: application/vnd.github+json")
	if [[ -n "${PERSONAL_TOKEN:-}" ]]; then
		curl_cmd+=(-H "Authorization: Bearer ${PERSONAL_TOKEN}")
	fi
	curl_cmd+=("${api}?per_page=100")

	local release_json
	release_json="$(
		"${curl_cmd[@]}" |
		jq -r --arg br "$branch" '
			map(select(.target_commitish == $br))
			| .[0]
		'
	)"

	if [[ -z "$release_json" || "$release_json" == "null" ]]; then
		echo "Kein Release für Branch '$branch' gefunden." >&2
		exit 1
	fi

	local tag
	tag="$(jq -r '.tag_name // empty' <<<"$release_json")"
	local download_url
	download_url="$(jq -r '.assets[0].browser_download_url // empty' <<<"$release_json")"

	if [[ -z "$tag" ]]; then
		echo "Release-Informationen für Branch '$branch' unvollständig." >&2
		exit 1
	fi

	if [[ -z "$download_url" || "$download_url" == "null" ]]; then
		download_url="$(jq -r '.zipball_url // empty' <<<"$release_json")"
	fi

	if [[ -z "$download_url" || "$download_url" == "null" ]]; then
		echo "Konnte keine Download-URL für Branch '$branch' bestimmen." >&2
		exit 1
	fi

	local tmp_zip
	tmp_zip="$(mktemp)"
	echo "Lade herunter: $download_url"
	curl -fL --retry 3 -o "$tmp_zip" "$download_url"
	rm -f "$dest"
	mv "$tmp_zip" "$dest"
}

ensure_helper_available() {
	local helper_name="$1"
	local helper_path="$SCRIPT_DIR/$helper_name"

	if [[ ! -f "$helper_path" ]]; then
		local fetched=false
		local branches_to_try=()
		branches_to_try+=("$BRANCH")
		if [[ "$BRANCH" != "main" ]]; then
			branches_to_try+=("main")
		fi

		for remote_branch in "${branches_to_try[@]}"; do
			local remote_url="https://raw.githubusercontent.com/ByteCraftServices/ddpc/${remote_branch}/get/${helper_name}"
			echo "Lade fehlendes $helper_name von $remote_url ..."
			if curl -fsSL "$remote_url" -o "$helper_path"; then
				fetched=true
				break
			fi
		done

		if [[ "$fetched" != true ]]; then
			echo "Konnte $helper_name nicht aus dem Repository beziehen." >&2
			exit 1
		fi
	fi

	if [[ ! -x "$helper_path" ]]; then
		if ! chmod +x "$helper_path"; then
			echo "Konnte Ausführbarkeit für $helper_path nicht setzen." >&2
			exit 1
		fi
	fi
}

ensure_helper_available "alpha.sh"
ensure_helper_available "beta.sh"

BASE_REPO="https://github.com/ByteCraftServices/ddpc"
TMP_DIR="$HOME/Downloads"
WORK_DIR="$TMP_DIR/ddpc_download"

ZIP_BASENAME="ddpc"
if [[ "$BRANCH" == "alpha" ]]; then
	ZIP_BASENAME="alpha"
elif [[ "$BRANCH" == "beta" ]]; then
	ZIP_BASENAME="beta"
fi

ZIP_PATH="$TMP_DIR/${ZIP_BASENAME}.zip"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$PATH_ROOT_DDPC"

if [[ "$BRANCH" == "main" ]]; then
	if [[ "$VERSION" == "latest" ]]; then
		DOWNLOAD_URL="$BASE_REPO/releases/latest/download/ddpc.zip"
	else
		DOWNLOAD_URL="$BASE_REPO/releases/download/$VERSION/ddpc.zip"
	fi

	echo "Lade $DOWNLOAD_URL ..."
	curl -fL "$DOWNLOAD_URL" -o "$ZIP_PATH"
else
	download_branch_release "$BRANCH" "$ZIP_PATH"
fi

unzip -q -o "$ZIP_PATH" -d "$WORK_DIR"

# Identify the extracted root folder (release asset or branch archive)
EXTRACTED_ROOT=$(find "$WORK_DIR" -maxdepth 1 -mindepth 1 -type d | head -n1)
if [[ -z "$EXTRACTED_ROOT" ]]; then
	echo "Konnte entpackten Inhalt nicht finden." >&2
	exit 1
fi

for dir in ddpc.res ddpc.assistant ddpc.scripts; do
	if [[ ! -d "$EXTRACTED_ROOT/$dir" ]]; then
		echo "Erwarteter Ordner $dir fehlt im Download." >&2
		exit 1
	fi
	rm -rf "$PATH_ROOT_DDPC/$dir"
	mv "$EXTRACTED_ROOT/$dir" "$PATH_ROOT_DDPC/"
done

rm -f "$ZIP_PATH"
rm -rf "$WORK_DIR"

# Clean up old directories
rm -rf "$HOME/Scripts" "$HOME/-profile" "$HOME/darts-hub/shared"