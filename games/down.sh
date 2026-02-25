#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  GN-Math Game Downloader  (Parallel Edition)
#  Downloads game HTML + required assets from gn-math repos
#  Folder format: {GameName}
#  Compresses HTML/JS/CSS/JSON/SVG with gzip for serving
#
#  Assets are fetched via sparse checkout (only the ~50 folders
#  that actually have game assets, NOT the full 1.8 GB repo).
#
#  Uses N parallel workers (default 10, override with JOBS=N).
#  Requires bash ≥ 4.3 for `wait -n`.
#
#  NOTE: Do NOT run with sudo — files will get root ownership
#  and break git. Just run: bash down.sh
# ============================================================

# Number of parallel download workers
JOBS=${JOBS:-10}

# Warn if running as root
if [[ $EUID -eq 0 ]]; then
  echo "WARNING: Running as root. File ownership will be set to root."
fi

ZONES_JSON="https://cdn.jsdelivr.net/gh/gn-math/assets@main/zones.json"
HTML_BASE="https://cdn.jsdelivr.net/gh/gn-math/html@main"
ASSETS_REPO="https://github.com/gn-math/assets.git"
COVERS_CDN="https://cdn.jsdelivr.net/gh/gn-math/covers@main"

OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$OUT_DIR/games.json"
ASSETS_DIR="$(mktemp -d)"
TMP_JSON="$(mktemp)"
JOBS_DIR="$(mktemp -d)"          # each worker writes results here

MAX_RETRIES=3
COMPRESS_EXTS="html|js|css|json|svg|xml|txt|md|map|mjs|wasm"

cleanup() {
  rm -rf "$ASSETS_DIR" "$TMP_JSON" "$JOBS_DIR"
}
trap cleanup EXIT

mkdir -p "$OUT_DIR"

# ============================================================
#  Step 1: Download zones.json (game catalogue)
# ============================================================
echo "[*] Fetching zones.json…"
curl -fsSL "$ZONES_JSON" -o "$TMP_JSON"

TOTAL=$(jq 'length' "$TMP_JSON")
echo "[*] Found $TOTAL catalogue entries"

# ============================================================
#  Step 2: Sparse-clone asset repo (only numeric game folders)
#  Uses --filter=blob:none so the initial clone is tiny (~1 MB),
#  then sparse-checkout pulls only the folders that exist.
# ============================================================
echo "[*] Sparse-cloning assets repo…"
git clone --filter=blob:none --depth 1 --sparse "$ASSETS_REPO" "$ASSETS_DIR" 2>&1 | grep -v '^$' | tail -2 || true

cd "$ASSETS_DIR"
ASSET_IDS=$(git ls-tree --name-only HEAD | grep -E '^[0-9]+$' || true)
ASSET_COUNT=$(echo "$ASSET_IDS" | grep -c . || true)
echo "[*] $ASSET_COUNT games have asset folders"

if [[ -n "$ASSET_IDS" ]]; then
  # shellcheck disable=SC2086
  git sparse-checkout set $ASSET_IDS 2>&1 | tail -2 || true
  echo "[*] Asset folders checked out"
fi

# Pre-compute git tree hashes for all asset IDs (avoids repeated git calls)
declare -A ASSET_TREE_HASH
for aid in $ASSET_IDS; do
  ASSET_TREE_HASH["$aid"]=$(git rev-parse "HEAD:$aid" 2>/dev/null || echo "none")
done

cd "$OUT_DIR"

# Write asset hashes to a file so workers can read it (assoc arrays can't export)
ASSET_HASH_FILE="$JOBS_DIR/_asset_hashes"
for aid in $ASSET_IDS; do
  echo "$aid ${ASSET_TREE_HASH[$aid]}"
done > "$ASSET_HASH_FILE"

# ============================================================
#  Step 3: Download + process each game  (PARALLEL)
#  Each worker writes two files into $JOBS_DIR:
#    <safe_name>.json   – manifest entry
#    <safe_name>.status  – "skipped" / "updated" / "new" / "failed"
# ============================================================
echo ""
echo "[*] Downloading games ($JOBS parallel workers)…"

process_game() {
  local entry="$1"
  local OUT_DIR="$2"
  local ASSETS_DIR="$3"
  local HTML_BASE="$4"
  local COVERS_CDN="$5"
  local JOBS_DIR="$6"
  local COMPRESS_EXTS="$7"
  local MAX_RETRIES="$8"

  local ASSET_HASH_FILE="$JOBS_DIR/_asset_hashes"

  local id name raw_url
  id=$(echo "$entry" | jq -r '.id // empty')
  name=$(echo "$entry" | jq -r '.name // empty')
  raw_url=$(echo "$entry" | jq -r '.url // empty')

  # Skip junk
  [[ -z "$id" || "$id" == "null" || "$id" == "-1" ]] && return 0

  # Sanitised folder name
  local safe_name folder_name game_dir
  safe_name=$(echo "$name" | tr '/:' '_' | tr -cd '[:alnum:] _-')
  folder_name="${safe_name}"
  game_dir="$OUT_DIR/$folder_name"

  # Resolve HTML filename
  local html_file dl_url
  html_file=$(echo "$raw_url" | sed 's|.*{HTML_URL}/||')
  if [[ -z "$html_file" || "$html_file" == "null" || "$html_file" == "$raw_url" ]]; then
    html_file="${id}.html"
  fi
  dl_url="$HTML_BASE/$html_file"

  local file="$game_dir/index.html"
  local hash_file="$game_dir/.hash"

  # ── Download HTML ──────────────────────────────────────────
  local TMP_HTML
  TMP_HTML=$(mktemp)
  local RETRY=0 OK=false
  while [[ $RETRY -lt $MAX_RETRIES ]]; do
    if curl -fsSL "$dl_url" -o "$TMP_HTML" 2>/dev/null; then OK=true; break; fi
    RETRY=$((RETRY + 1))
    [[ $RETRY -lt $MAX_RETRIES ]] && sleep 1
  done

  if ! $OK; then
    echo "    [!] FAILED: $name (id=$id)"
    rm -f "$TMP_HTML"
    echo "failed" > "$JOBS_DIR/${id}.status"
    [[ -d "$game_dir" ]] && echo "{\"id\": \"$id\", \"name\": \"$name\", \"folder\": \"$folder_name\"}" > "$JOBS_DIR/${id}.json"
    return 0
  fi

  # ── Compute hash ───────────────────────────────────────────
  local HTML_HASH ASSET_HASH COMBINED
  HTML_HASH=$(md5sum "$TMP_HTML" | cut -d' ' -f1)
  ASSET_HASH="none"
  if grep -q "^${id} " "$ASSET_HASH_FILE" 2>/dev/null; then
    ASSET_HASH=$(grep "^${id} " "$ASSET_HASH_FILE" | cut -d' ' -f2)
  fi
  COMBINED="${HTML_HASH}_${ASSET_HASH}"

  # ── Skip if nothing changed ────────────────────────────────
  if [[ -f "$hash_file" ]] && [[ "$(cat "$hash_file")" == "$COMBINED" ]]; then
    rm -f "$TMP_HTML"
    echo "skipped" > "$JOBS_DIR/${id}.status"
    echo "{\"id\": \"$id\", \"name\": \"$name\", \"folder\": \"$folder_name\"}" > "$JOBS_DIR/${id}.json"
    return 0
  fi

  # ── Log ────────────────────────────────────────────────────
  if [[ -d "$game_dir" ]]; then
    echo "[~] Updated: $folder_name"
    echo "updated" > "$JOBS_DIR/${id}.status"
  else
    echo "[+] New: $name (id=$id) → $folder_name"
    echo "new" > "$JOBS_DIR/${id}.status"
  fi

  mkdir -p "$game_dir"

  # Remove old compressed files
  find "$game_dir" -type f -name "*.gz" -delete 2>/dev/null || true

  # Place new HTML
  mv "$TMP_HTML" "$file"

  # ── Copy assets ────────────────────────────────────────────
  local src="$ASSETS_DIR/$id"
  if [[ -d "$src" ]]; then
    echo "    ↳ assets for id $id"
    find "$src" -mindepth 1 -maxdepth 1 \
      ! -name "index.html" ! -name "cover.png" \
      -exec cp -a {} "$game_dir/" \;

    sed -i 's|<base href="[^"]*">|<base href="./">|gi' "$file"

    # Compress text-based asset files
    find "$game_dir" -type f -regextype posix-extended \
      -regex ".*\\.($COMPRESS_EXTS)" \
      ! -name "*.gz" \
      -exec gzip -9 {} \;
  fi

  # Gzip the HTML
  [[ -f "$file" ]] && gzip -9 "$file"

  # ── Download cover image ───────────────────────────────────
  if [[ ! -f "$game_dir/cover.png" ]]; then
    curl -fsSL "$COVERS_CDN/${id}.png" -o "$game_dir/cover.png" 2>/dev/null || true
  fi

  # Save hash
  echo "$COMBINED" > "$hash_file"

  echo "{\"id\": \"$id\", \"name\": \"$name\", \"folder\": \"$folder_name\"}" > "$JOBS_DIR/${id}.json"
}

export -f process_game

# ── Launch parallel workers using a job pool ─────────────────
RUNNING=0
while IFS= read -r entry; do
  # Spawn worker in background
  process_game "$entry" "$OUT_DIR" "$ASSETS_DIR" "$HTML_BASE" "$COVERS_CDN" "$JOBS_DIR" "$COMPRESS_EXTS" "$MAX_RETRIES" &

  RUNNING=$((RUNNING + 1))
  # Throttle: wait for one to finish when pool is full
  if [[ $RUNNING -ge $JOBS ]]; then
    wait -n 2>/dev/null || true
    RUNNING=$((RUNNING - 1))
  fi
done < <(jq -c '.[]' "$TMP_JSON")

# Wait for remaining workers
wait

# ── Collect results ──────────────────────────────────────────
SKIPPED=0; UPDATED=0; NEW_GAMES=0; FAILED=0
for sf in "$JOBS_DIR"/*.status; do
  [[ -f "$sf" ]] || continue
  case "$(cat "$sf")" in
    skipped)  SKIPPED=$((SKIPPED + 1)) ;;
    updated)  UPDATED=$((UPDATED + 1)) ;;
    new)      NEW_GAMES=$((NEW_GAMES + 1)) ;;
    failed)   FAILED=$((FAILED + 1)) ;;
  esac
done

# Merge manifest entries
GAMES_TMP="$JOBS_DIR/_manifest"
cat "$JOBS_DIR"/*.json > "$GAMES_TMP" 2>/dev/null || true

# ============================================================
#  Step 4: Cleanup stale uncompressed text files
# ============================================================
echo ""
echo "[*] Cleaning up stale uncompressed files…"
CLEANED=0
while IFS= read -r -d '' f; do
  if [[ -f "${f}.gz" ]]; then
    rm -f "$f"
    CLEANED=$((CLEANED + 1))
  else
    gzip -9 "$f"
    CLEANED=$((CLEANED + 1))
  fi
done < <(find "$OUT_DIR" -mindepth 2 -maxdepth 5 -type f -regextype posix-extended \
  -regex ".*\.($COMPRESS_EXTS)" \
  ! -name "*.gz" \
  ! -name "games.json" \
  -print0 2>/dev/null)
[[ $CLEANED -gt 0 ]] && echo "    Cleaned $CLEANED files" || echo "    Nothing to clean"

# ============================================================
#  Step 5: Build games.json manifest
# ============================================================
if [[ -f "$GAMES_TMP" && -s "$GAMES_TMP" ]]; then
  jq -s '.' "$GAMES_TMP" > "$MANIFEST"
  echo ""
  echo "[✓] Manifest: $(jq length "$MANIFEST") games"
else
  echo "[!] No games recorded"
  echo "[]" > "$MANIFEST"
fi

# Clean up empty dirs
find "$OUT_DIR" -maxdepth 1 -type d -empty -delete 2>/dev/null || true

echo ""
echo "════════════════════════════════════════"
echo "  ✓ DONE  ($JOBS parallel workers)"
echo "  New: $NEW_GAMES  Updated: $UPDATED  Skipped: $SKIPPED  Failed: $FAILED"
echo "  Games: $OUT_DIR"
echo "  Manifest: $MANIFEST"
echo "════════════════════════════════════════"
