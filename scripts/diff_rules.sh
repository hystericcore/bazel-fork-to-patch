#!/usr/bin/env bash
#
# diff_rules.sh — Diff local Bazel rules against official upstream
# and generate bzlmod-compatible patch files.
#
# Usage:
#   bash diff_rules.sh \
#     --local /path/to/your/local/rules \
#     --upstream <upstream_url_or_path> \
#     --upstream-tag <tag_or_commit> \
#     --output-dir <patch_output_directory> \
#     [--exclude-patterns <file_with_patterns>] \
#     [--dry-run]

set -euo pipefail

# ---------- defaults ----------
LOCAL_PATH=""
UPSTREAM_URL=""
UPSTREAM_TAG=""
OUTPUT_DIR="./patches"
EXCLUDE_PATTERNS=""
DRY_RUN=false
WORK_DIR=$(mktemp -d)

# ---------- parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)        LOCAL_PATH="$2"; shift 2 ;;
    --upstream)     UPSTREAM_URL="$2"; shift 2 ;;
    --upstream-tag) UPSTREAM_TAG="$2"; shift 2 ;;
    --output-dir)   OUTPUT_DIR="$2"; shift 2 ;;
    --exclude-patterns) EXCLUDE_PATTERNS="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: $0 --local <path> --upstream <url|path> --upstream-tag <tag> --output-dir <dir>"
      echo ""
      echo "Options:"
      echo "  --local            Path to your local rules directory"
      echo "  --upstream         Git URL or local path of official upstream rules"
      echo "  --upstream-tag     Tag or commit to compare against"
      echo "  --output-dir       Directory to write patch files (default: ./patches)"
      echo "  --exclude-patterns File containing additional exclude patterns (one per line)"
      echo "  --dry-run          Analyze only, don't write patches"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ---------- validate ----------
if [[ -z "$LOCAL_PATH" || -z "$UPSTREAM_URL" || -z "$UPSTREAM_TAG" ]]; then
  echo "Error: --local, --upstream, and --upstream-tag are required."
  echo "Run with --help for usage."
  exit 1
fi

if [[ ! -d "$LOCAL_PATH" ]]; then
  echo "Error: Local path does not exist: $LOCAL_PATH"
  exit 1
fi

UPSTREAM_BASENAME=$(basename "$UPSTREAM_URL" .git)

echo "============================================="
echo " Bazel Fork-to-Patch Diff Tool"
echo "============================================="
echo ""
echo "Local rules:   $LOCAL_PATH"
echo "Upstream:      $UPSTREAM_URL (tag: $UPSTREAM_TAG)"
echo "Output dir:    $OUTPUT_DIR"
echo "Work dir:      $WORK_DIR"
echo ""

# ---------- setup upstream ----------
UPSTREAM_DIR="$WORK_DIR/upstream"

if [[ -d "$UPSTREAM_URL" ]]; then
  echo "Copying local upstream path..."
  cp -r "$UPSTREAM_URL" "$UPSTREAM_DIR"
else
  echo "Cloning upstream..."
  git clone --quiet "$UPSTREAM_URL" "$UPSTREAM_DIR"
fi

echo "Checking out: $UPSTREAM_TAG"
cd "$UPSTREAM_DIR" && git checkout --quiet "$UPSTREAM_TAG" && cd - > /dev/null

# ---------- build exclude args ----------
DIFF_EXCLUDES=(
  --exclude='.git'
  --exclude='.github'
  --exclude='.gitignore'
  --exclude='.bazelci'
  --exclude='LICENSE'
  --exclude='CODEOWNERS'
  --exclude='CONTRIBUTORS'
  --exclude='CHANGELOG.md'
  --exclude='README.md'
)

if [[ -n "$EXCLUDE_PATTERNS" && -f "$EXCLUDE_PATTERNS" ]]; then
  while IFS= read -r pattern; do
    [[ -z "$pattern" || "$pattern" == \#* ]] && continue
    DIFF_EXCLUDES+=(--exclude="$pattern")
  done < "$EXCLUDE_PATTERNS"
fi

# ---------- generate diff ----------
echo ""
echo "============================================="
echo " DIFF: Local vs. upstream ($UPSTREAM_TAG)"
echo "============================================="
echo ""

FULL_DIFF="$WORK_DIR/full-diff.patch"
diff -ruN "$UPSTREAM_DIR" "$LOCAL_PATH" "${DIFF_EXCLUDES[@]}" > "$FULL_DIFF" || true

FILE_COUNT=$(grep -c "^diff " "$FULL_DIFF" || echo 0)
LINE_COUNT=$(wc -l < "$FULL_DIFF")

echo "Changed files: $FILE_COUNT"
echo "Diff lines:    $LINE_COUNT"

if [[ "$FILE_COUNT" -eq 0 ]]; then
  echo ""
  echo "No differences found. Local rules match upstream at $UPSTREAM_TAG."
  exit 0
fi

echo ""
echo "Changed files:"
grep "^diff " "$FULL_DIFF" | sed "s|$WORK_DIR/upstream/\||$LOCAL_PATH/||g" | while read -r line; do
  echo "  $line"
done

echo ""
echo "Changes by directory:"
grep "^diff " "$FULL_DIFF" \
  | sed "s|.*$WORK_DIR/upstream/||" \
  | sed 's|/[^/]*$||' \
  | sort | uniq -c | sort -rn | while read -r line; do
  echo "  $line"
done

# ---------- change analysis ----------
echo ""
echo "============================================="
echo " ANALYSIS"
echo "============================================="

CHANGE_LINES=$(grep "^[+-]" "$FULL_DIFF" | grep -v "^[+-][+-][+-]" | wc -l)
echo "Total changed lines: $CHANGE_LINES"

# Files only in local (new files)
ONLY_LOCAL=$(diff -rq "$UPSTREAM_DIR" "$LOCAL_PATH" "${DIFF_EXCLUDES[@]}" | grep "^Only in $LOCAL_PATH" | wc -l || true)
ONLY_UPSTREAM=$(diff -rq "$UPSTREAM_DIR" "$LOCAL_PATH" "${DIFF_EXCLUDES[@]}" | grep "^Only in $UPSTREAM_DIR" | wc -l || true)

if [[ "$ONLY_LOCAL" -gt 0 ]]; then
  echo ""
  echo "Files only in local ($ONLY_LOCAL):"
  diff -rq "$UPSTREAM_DIR" "$LOCAL_PATH" "${DIFF_EXCLUDES[@]}" | grep "^Only in $LOCAL_PATH" | sed "s|Only in $LOCAL_PATH|  |"
fi

if [[ "$ONLY_UPSTREAM" -gt 0 ]]; then
  echo ""
  echo "Files only in upstream ($ONLY_UPSTREAM):"
  diff -rq "$UPSTREAM_DIR" "$LOCAL_PATH" "${DIFF_EXCLUDES[@]}" | grep "^Only in $UPSTREAM_DIR" | sed "s|Only in $UPSTREAM_DIR|  |"
fi

# ---------- generate bzlmod patch ----------
echo ""
echo "============================================="
echo " GENERATING PATCHES"
echo "============================================="

# Rewrite paths for patch_strip=1
BZLMOD_PATCH="$WORK_DIR/bzlmod-full.patch"
sed "s|$UPSTREAM_DIR|a|g; s|$LOCAL_PATH|b|g" "$FULL_DIFF" > "$BZLMOD_PATCH"

# Split per file
PER_FILE_DIR="$WORK_DIR/per-file"
mkdir -p "$PER_FILE_DIR"
csplit -z -f "$PER_FILE_DIR/chunk_" -b "%03d.patch" \
  "$BZLMOD_PATCH" '/^diff /' '{*}' 2>/dev/null || true

PER_FILE_COUNT=$(ls "$PER_FILE_DIR"/*.patch 2>/dev/null | wc -l)
echo "Generated $PER_FILE_COUNT per-file patches"

# ---------- output ----------
if [[ "$DRY_RUN" == true ]]; then
  echo ""
  echo "=== Dry run — review files in $WORK_DIR/ ==="
  echo "  full-diff.patch    — raw diff"
  echo "  bzlmod-full.patch  — patch_strip=1 ready"
  echo "  per-file/          — individual file patches"
else
  mkdir -p "$OUTPUT_DIR"

  # Full combined patch
  cp "$BZLMOD_PATCH" "$OUTPUT_DIR/${UPSTREAM_BASENAME}_full.patch"

  # Per-file patches with descriptive names
  for chunk in "$PER_FILE_DIR"/*.patch; do
    CHANGED_FILE=$(head -1 "$chunk" | sed 's|^diff.*b/||')
    SAFE_NAME=$(echo "$CHANGED_FILE" | tr '/' '_' | sed 's/[^a-zA-Z0-9._-]/_/g')
    cp "$chunk" "$OUTPUT_DIR/${SAFE_NAME}.patch"
  done

  echo ""
  echo "Patches written to: $OUTPUT_DIR/"
  ls "$OUTPUT_DIR/"*.patch
fi

# ---------- next steps ----------
echo ""
echo "============================================="
echo " NEXT STEPS"
echo "============================================="
echo ""
echo "1. Review patches — drop changes upstream already includes"
echo ""
echo "2. Test patches apply cleanly:"
echo "   cd /tmp/upstream-rules && git checkout $UPSTREAM_TAG"
echo "   git apply --check <patch_file>"
echo ""
echo "3. Add to MODULE.bazel:"
echo ""
echo "   bazel_dep(name = \"$UPSTREAM_BASENAME\", version = \"$UPSTREAM_TAG\")"
echo "   single_version_override("
echo "       module_name = \"$UPSTREAM_BASENAME\","
echo "       version = \"$UPSTREAM_TAG\","
echo "       patches = [\"//patches:<patch_file>\"],"
echo "       patch_strip = 1,"
echo "   )"
echo ""
echo "Work directory (delete when done): $WORK_DIR"
