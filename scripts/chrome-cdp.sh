#!/usr/bin/env bash
set -euo pipefail

# --- config ---
DATA_DIR="$HOME/.chrome-debug-profile"
CHROME_PROFILE_DIR="$HOME/.config/google-chrome"

# --- usage ---
usage() {
  local code="${1:-1}"
  echo "Usage: $0 [--reset | --clone <ProfileName>] [--help]"
  echo "  --reset              Clear the test data dir before launching"
  echo "  --clone <Profile>    Copy Bookmarks, History, Cookies, Preferences,"
  echo "                       Local Storage, Extensions, and Local State from"
  echo "                       ~/.config/google-chrome/<Profile> into the test dir,"
  echo "                       skipping all cache directories."
  echo "  --reset and --clone are mutually exclusive."
  exit "$code"
}

# --- parse args ---
RESET=false
CLONE_PROFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset)
      RESET=true
      shift
      ;;
    --clone)
      CLONE_PROFILE="$2"
      shift 2
      ;;
    -h|--help)
      usage 0
      ;;
    *)
      echo "ERROR: unknown option: $1"
      usage
      ;;
  esac
done

# --- mutually exclusive ---
if $RESET && [[ -n "$CLONE_PROFILE" ]]; then
  echo "ERROR: --reset and --clone are mutually exclusive"
  usage
fi

# --- --reset: blow away the test data dir ---
if $RESET; then
  echo "==> Removing $DATA_DIR"
  rm -rf "$DATA_DIR"
fi

# --- --clone: copy selected profile data (no cache) ---
if [[ -n "$CLONE_PROFILE" ]]; then
  SRC="$CHROME_PROFILE_DIR/$CLONE_PROFILE"
  if [[ ! -d "$SRC" ]]; then
    echo "ERROR: profile '$CLONE_PROFILE' not found at $SRC"
    exit 1
  fi

  DST="$DATA_DIR/Default"
  echo "==> Cloning '$CLONE_PROFILE' -> $DST"
  rm -rf "$DATA_DIR"
  mkdir -p "$DST"

  copy_item() {
    local name="$1"
    if [[ -e "$SRC/$name" ]]; then
      cp -a "$SRC/$name" "$DST/"
      echo "    $name"
    fi
  }

  copy_item "Bookmarks"
  copy_item "History"
  copy_item "Cookies"
  copy_item "Preferences"
  copy_item "Local Storage"
  copy_item "Extensions"

  # Local State lives one level above profiles (browser-wide)
  LOCAL_STATE="$CHROME_PROFILE_DIR/Local State"
  if [[ -f "$LOCAL_STATE" ]]; then
    cp -a "$LOCAL_STATE" "$DATA_DIR/"
    echo "    Local State"
  fi
fi

# --- Kill any existing Chrome so the profile is not locked ---
pkill -9 chrome 2>/dev/null || true
pkill -9 google-chrome 2>/dev/null || true
pkill -9 chrome_crashpad 2>/dev/null || true

LOG=/tmp/chrome-cdp-normal.log
rm -f "$LOG"

# --- Start Chrome with CDP ---
/usr/bin/google-chrome-stable \
  --remote-debugging-address=127.0.0.1 \
  --remote-debugging-port=9222 \
  --user-data-dir="$DATA_DIR" \
  --no-first-run \
  --no-default-browser-check \
  >"$LOG" 2>&1 &

echo "PID=$!"
echo "Log: $LOG"

# Quick check
sleep 5
curl -sS http://127.0.0.1:9222/json/version | jq
