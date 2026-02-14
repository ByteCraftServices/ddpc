#!/bin/bash
set -euo pipefail

# Ensure jq is installed
if ! command -v jq >/dev/null 2>&1; then
  echo "jq wird installiert..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y jq
  elif command -v brew >/dev/null 2>&1; then
    brew install jq
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --noconfirm jq
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y jq
  else
    echo "jq konnte nicht automatisch installiert werden. Bitte installieren Sie jq manuell." >&2
    exit 1
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load PATH_ROOT_DDPC from paths.conf
source "$HOME/ddpc/scripts/config/.local/paths.conf"
#PATH_ROOT_DDPC="$HOME/ddpc"

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
      # robuster Raw-URL + -L wegen Redirects
      local remote_url="https://raw.githubusercontent.com/ByteCraftServices/ddpc/${remote_branch}/get/${helper_name}"
      echo "Lade fehlendes $helper_name von $remote_url ..."
      if curl -fsSL -L "$remote_url" -o "$helper_path"; then
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

# ---- FIX START: robusten Root bestimmen ----
EXPECTED_DIRS=(res assistant scripts)

pick_extracted_root() {
  local candidate d ok

  # 1) Falls die Ordner direkt unter WORK_DIR liegen:
  ok=1
  for d in "${EXPECTED_DIRS[@]}"; do
    [[ -d "$WORK_DIR/$d" ]] || { ok=0; break; }
  done
  if (( ok )); then
    echo "$WORK_DIR"
    return 0
  fi

  # 2) Sonst: genau einen Level tiefer suchen (typisch bei GitHub zipball/release-zip mit Top-Ordner)
  for candidate in "$WORK_DIR"/*; do
    [[ -d "$candidate" ]] || continue
    ok=1
    for d in "${EXPECTED_DIRS[@]}"; do
      [[ -d "$candidate/$d" ]] || { ok=0; break; }
    done
    if (( ok )); then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

if ! EXTRACTED_ROOT="$(pick_extracted_root)"; then
  echo "Konnte entpackten Inhalt nicht eindeutig finden. Debug:" >&2
  find "$WORK_DIR" -maxdepth 2 -type d -print >&2 || true
  echo "Inhalt von $WORK_DIR:" >&2
  ls -l "$WORK_DIR" >&2 || true
  echo "Inhalt von $WORK_DIR (rekursiv):" >&2
  ls -lR "$WORK_DIR" >&2 || true
  exit 1
fi
# ---- FIX END ----

for dir in "${EXPECTED_DIRS[@]}"; do
  if [[ ! -d "$EXTRACTED_ROOT/$dir" ]]; then
    echo "Erwarteter Ordner $dir fehlt im Download. $EXTRACTED_ROOT/$dir" >&2
    echo "Debug: Inhalt von $EXTRACTED_ROOT:" >&2
    ls -l "$EXTRACTED_ROOT" >&2 || true
    echo "Debug: Inhalt von $EXTRACTED_ROOT/$dir (falls vorhanden):" >&2
    ls -l "$EXTRACTED_ROOT/$dir" >&2 || true
    exit 1
  fi
  rm -rf "$PATH_ROOT_DDPC/$dir"
  mv "$EXTRACTED_ROOT/$dir" "$PATH_ROOT_DDPC/"
done

rm -f "$ZIP_PATH"
rm -rf "$WORK_DIR"

# Clean up old directories
rm -rf "$HOME/Scripts" "$HOME/-profile" "$HOME/darts-hub/shared"

# Make all .sh files executable
find "$PATH_ROOT_DDPC" -type f -name "*.sh" -exec chmod +x {} \;

# Set Environment Variable for the current session
source "$PATH_ROOT_DDPC/scripts/config/.local/paths.conf"

$PATH_ROOT_DDPC/scripts/config/webserver/configure_webserver.sh