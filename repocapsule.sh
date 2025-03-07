#!/bin/bash

# RepoCapsule: Package a directory/repository into a single, portable Bash script for reproduction, LLM editing, and sharing
# Intent: This script transforms a directory (e.g., a code repository) into a self-contained Bash script (setup-<repo>.sh) that:
#   - Embeds all files in dual format: plain text for LLM readability and base64 for execution.
#   - Enables reproduction of the directory structure and contents on any compatible system under a single top-level directory.
#   - Supports LLM-driven updates by providing editable plain text sections, which can be re-encoded and executed.
#   - Facilitates sharing, version control, and incremental updates for collaborative development.
# Version: 1.0.3
# License: MIT
# Website: https://github.com/jeffrmorton/repocapsule
# "Pack it, script it, ship it!"

set -e

VERSION="1.0.3"
DEFAULT_OUTPUT="setup"
LOG_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/repocapsule.log"
CHUNK_SIZE=1000
COMPRESS_THRESHOLD=1048576 # 1MB in bytes
BANNER="RepoCapsule v$VERSION - Pack it, script it, ship it!"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

usage() {
    cat <<EOF
$BANNER
Usage: $0 [OPTIONS] <directory>
Package a directory/repo into a standalone Bash script for reproduction or LLM ingestion.

Options:
  -o, --output-dir DIR    Output directory (default: .)
  -b, --binary-support    Include binary files (needs base64)
  -c, --compress          Compress large files (>${COMPRESS_THRESHOLD} bytes, needs gzip, tar)
  -i, --incremental       Enable incremental updates in generated script
  -v, --verbose           Enable verbose logging to $LOG_FILE
  -h, --help              Show this help
  --version               Show version

Generated Script Usage:
  ./setup-<repo>.sh           # Reproduce the repo in ./<repo>
  ./setup-<repo>.sh --dump    # Dump contents for LLM
  ./setup-<repo>.sh --update  # Update existing repo
  ./setup-<repo>.sh --dry-run # Preview changes
  ./setup-<repo>.sh --verify  # Verify reproduced repo matches original
  ./setup-<repo>.sh --recalculate-hash  # Update source hash after changes
  ./setup-<repo>.sh --retry-failed  # Retry failed file creations
EOF
    exit 0
}

log() {
    local level="$1"
    local msg="$2"
    mkdir -p "$(dirname "$LOG_FILE")"
    if [ "$VERBOSE" = true ]; then
        [ "$level" = "ERROR" ] && echo -e "${RED}[$level] $msg${NC}" >&2 || echo "[$level] $msg" >&2
    fi
    echo "[$level] $(date -u +'%Y-%m-%d %H:%M:%S UTC') - $msg" >> "$LOG_FILE"
}

create_file() {
    local file="$1" rel_file="$2" perms="$3" output="$4" is_binary="$5" size="$6"
    local mtime=$(stat -c "%y" "$file" 2>/dev/null || stat -f "%Sm" "$file" 2>/dev/null || echo "unknown")
    # Strip the top-level REPO_NAME from rel_file if present
    rel_file=$(echo "$rel_file" | sed "s|^$BASENAME/||")
    # Skip if rel_file involves .git
    [[ "$rel_file" =~ ^\.git(/|$) ]] && return
    # Metadata
    echo "# LLM_UPDATE_SECTION: $rel_file" >> "$output"
    echo "# File: $rel_file" >> "$output"
    echo "# Permissions: $perms" >> "$output"
    echo "# Last Modified: $mtime" >> "$output"
    echo "# Size: $size bytes" >> "$output"
    
    # Plain text content for LLM readability
    if [ "$is_binary" = true ]; then
        echo "# Content: Binary file (base64 encoded below)" >> "$output"
    else
        echo "# Plain Text Content (for LLM readability):" >> "$output"
        echo ": <<'CONTENT_${rel_file//\//_}'" >> "$output"
        cat "$file" >> "$output"
        echo "CONTENT_${rel_file//\//_}" >> "$output"
    fi

    # Base64 content for execution with retry logic
    echo "for attempt in {1..3}; do" >> "$output"
    echo "    if [ \"\$VERIFY_MODE\" = false ] && { [ \"\$UPDATE_MODE\" = true ] && [ -f \"\$BASE_DIR/$rel_file\" ] && [ \"\$RECALCULATE_HASH\" = false ] && [ \"\$RETRY_FAILED\" = false ]; } || [ \"\$DRY_RUN\" = true ]; then" >> "$output"
    echo "        [ \"\$DRY_RUN\" = true ] && echo \"Would create \$BASE_DIR/$rel_file\" >&2 || echo \"Skipping existing \$BASE_DIR/$rel_file...\" >&2" >> "$output"
    echo "    else" >> "$output"
    echo "        echo \"Creating \$BASE_DIR/$rel_file (attempt \$attempt)...\" >&2" >> "$output"
    echo "        mkdir -p \"\$BASE_DIR/\$(dirname \"$rel_file\")\" || { echo \"Failed to create dir for \$BASE_DIR/$rel_file\" >&2; exit 1; }" >> "$output"
    if [ "$is_binary" = true ]; then
        echo "        if base64 -d <<'BASE64_${rel_file//\//_}' > \"\$BASE_DIR/$rel_file\"; then" >> "$output"
        base64 "$file" >> "$output"
        echo "BASE64_${rel_file//\//_}" >> "$output"
    else
        echo "        if tr -d '\r' <<'BASE64_${rel_file//\//_}' | base64 -d > \"\$BASE_DIR/$rel_file\"; then" >> "$output"
        base64 "$file" | tr -d '\r' >> "$output"  # Apply tr during encoding for text files
        echo "BASE64_${rel_file//\//_}" >> "$output"
    fi
    echo "            chmod $perms \"\$BASE_DIR/$rel_file\" 2>/dev/null || echo \"Warning: Failed to set permissions on \$BASE_DIR/$rel_file\" >&2" >> "$output"
    echo "            break" >> "$output"
    echo "        else" >> "$output"
    echo "            echo \"Failed to create \$BASE_DIR/$rel_file on attempt \$attempt\" >&2" >> "$output"
    echo "            [ \"\$attempt\" -lt 3 ] && sleep 2 || { echo \"Giving up on \$BASE_DIR/$rel_file after 3 attempts\" >&2; exit 1; }" >> "$output"
    echo "        fi" >> "$output"
    echo "    fi" >> "$output"
    echo "done" >> "$output"
}

process_file() {
    local file="$1" output="$2"
    local rel_file="${file#$REPO_PATH/}"
    local perms=$(stat -c "%a" "$file" 2>/dev/null || stat -f "%A" "$file" 2>/dev/null || echo "644")
    local size=$(stat -c "%s" "$file" 2>/dev/null || stat -f "%z" "$file" 2>/dev/null || echo "unknown")
    local is_binary=false

    if [ -z "$file" ] || [ -z "$rel_file" ]; then
        log "ERROR" "Invalid file path or relative file name (file: '$file', rel_file: '$rel_file')"
        echo -e "${RED}Error: Invalid file path or relative file name${NC}" >&2
        exit 1
    fi

    # Skip if rel_file involves .git
    [[ "$rel_file" =~ ^\.git(/|$) ]] && return

    if ! grep -q "text" <(file -b "$file") && [ "$BINARY_SUPPORT" = true ]; then
        is_binary=true
    fi

    echo "echo \"Processing $rel_file...\" >&2" >> "$output"
    echo "FILE_COUNT=\$((FILE_COUNT + 1))" >> "$output"
    if [ "$is_binary" = true ]; then
        echo "if [ \"\$DUMP_MODE\" = true ]; then echo \"=== $rel_file === (binary omitted)\" >&2; fi" >> "$output"
    else
        echo "if [ \"\$DUMP_MODE\" = true ]; then" >> "$output"
        echo "    echo \"=== $rel_file ===\" >&2" >> "$output"
        echo "    cat <<'CONTENT_${rel_file//\//_}'" >> "$output"
        cat "$file" >> "$output"
        echo "CONTENT_${rel_file//\//_}" >> "$output"
        echo "fi" >> "$output"
    fi
    echo "if [ \"\$VERIFY_MODE\" = false ]; then" >> "$output"
    create_file "$file" "$rel_file" "$perms" "$output" "$is_binary" "$size"
    echo "fi" >> "$output"
}

VERBOSE=false
BINARY_SUPPORT=false
COMPRESS=false
INCREMENTAL=false
OUTPUT_DIR="."
REPO_PATH=""

echo "DEBUG: Initial args: $@" >&2
while [[ $# -gt 0 ]]; do
    echo "DEBUG: Processing arg: $1" >&2
    case "$1" in
        -o|--output-dir) OUTPUT_DIR="$2"; echo "DEBUG: Set OUTPUT_DIR=$OUTPUT_DIR" >&2; shift 2 ;;
        -b|--binary-support) BINARY_SUPPORT=true; echo "DEBUG: Enabled BINARY_SUPPORT" >&2; shift ;;
        -c|--compress) COMPRESS=true; echo "DEBUG: Enabled COMPRESS" >&2; shift ;;
        -i|--incremental) INCREMENTAL=true; echo "DEBUG: Enabled INCREMENTAL" >&2; shift ;;
        -v|--verbose) VERBOSE=true; echo "DEBUG: Enabled VERBOSE" >&2; shift ;;
        -h|--help) usage ;;
        --version) echo "$BANNER"; exit 0 ;;
        -*) echo -e "${RED}Unknown option: $1${NC}" >&2; usage ;;
        *) REPO_PATH="$1"; echo "DEBUG: Set REPO_PATH=$REPO_PATH" >&2; shift ;;
    esac
done

if [ -z "$REPO_PATH" ]; then
    log "ERROR" "No directory provided"
    echo -e "${RED}Error: No directory provided${NC}" >&2
    usage
fi

if [ ! -d "$REPO_PATH" ]; then
    log "ERROR" "Directory '$REPO_PATH' does not exist"
    echo -e "${RED}Error: Directory '$REPO_PATH' does not exist${NC}" >&2
    exit 1
fi

# Normalize REPO_PATH by removing trailing slash
REPO_PATH="${REPO_PATH%/}"

BASENAME=$(basename "$REPO_PATH")
OUTPUT_SCRIPT="$OUTPUT_DIR/$DEFAULT_OUTPUT-$BASENAME.sh"
FILE_COUNT=$(find "$REPO_PATH" -type f -not -path "$REPO_PATH/.git/*" -not -path "$REPO_PATH/.git" | wc -l)
if [ "$FILE_COUNT" -eq 0 ]; then
    log "ERROR" "No files found in '$REPO_PATH' to process"
    echo -e "${RED}Error: No files found in '$REPO_PATH' to process${NC}" >&2
    exit 1
fi
SOURCE_HASH=$(find "$REPO_PATH" -type f -not -path "$REPO_PATH/.git/*" -not -path "$REPO_PATH/.git" -exec cat {} + 2>/dev/null | tr -d '\r' | md5sum | cut -d' ' -f1 || find "$REPO_PATH" -type f -not -path "$REPO_PATH/.git/*" -not -path "$REPO_PATH/.git" -exec cat {} + | tr -d '\r' | md5 -r | cut -d' ' -f1)
TOTAL_SIZE=$(du -sb "$REPO_PATH" | cut -f1 2>/dev/null || du -sk "$REPO_PATH" | cut -f1)
GIT_COMMIT=$(cd "$REPO_PATH" && git rev-parse HEAD 2>/dev/null || echo "N/A")

echo "DEBUG: REPO_PATH=$REPO_PATH, BASENAME=$BASENAME, OUTPUT_SCRIPT=$OUTPUT_SCRIPT" >&2
echo "DEBUG: SOURCE_HASH=$SOURCE_HASH, FILE_COUNT=$FILE_COUNT, TOTAL_SIZE=$TOTAL_SIZE, GIT_COMMIT=$GIT_COMMIT" >&2

if [ ! -d "$OUTPUT_DIR" ]; then
    log "ERROR" "Output directory '$OUTPUT_DIR' does not exist"
    echo -e "${RED}Error: Output directory '$OUTPUT_DIR' does not exist${NC}" >&2
    exit 1
fi

if [ "$BINARY_SUPPORT" = true ] && ! command -v base64 >/dev/null 2>&1; then
    log "ERROR" "base64 not found, required for binary support"
    echo -e "${RED}Error: base64 not found (required for -b option)${NC}" >&2
    exit 1
fi

if [ "$COMPRESS" = true ] && { ! command -v gzip >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; }; then
    log "ERROR" "gzip or tar not found, required for compression"
    echo -e "${RED}Error: gzip or tar not found (required for -c option)${NC}" >&2
    exit 1
fi

log "INFO" "Starting RepoCapsule v$VERSION for '$REPO_PATH'"

TEMP_SCRIPT=$(mktemp)
cat <<'EOF' > "$TEMP_SCRIPT"
#!/bin/bash

# RepoCapsule Generated Script
# Repo: REPO_NAME_PLACEHOLDER
# Version: REPO_VERSION_PLACEHOLDER
# Created: CREATED_DATE_PLACEHOLDER
# Source Hash: SOURCE_HASH_PLACEHOLDER
# File Count: FILE_COUNT_PLACEHOLDER
# Total Size: TOTAL_SIZE_PLACEHOLDER bytes
# Git Commit: GIT_COMMIT_PLACEHOLDER
# Docs: https://github.com/jeffrmorton/repocapsule
# Changelog:
# - Initial creation (RepoCapsule v1.0.3, CREATED_DATE_PLACEHOLDER)

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "Error: Bash 4.0 or higher required" >&2
    exit 1
fi

set -e
trap 'echo "Error occurred at line $LINENO, cleaning up..."; rm -rf "$BASE_DIR"; exit 1' ERR

REPO_NAME="REPO_NAME_PLACEHOLDER"
REPO_VERSION="REPO_VERSION_PLACEHOLDER"
SOURCE_HASH="SOURCE_HASH_PLACEHOLDER"
DUMP_MODE=false
UPDATE_MODE=false
DRY_RUN=false
VERIFY_MODE=false
RECALCULATE_HASH=false
RETRY_FAILED=false
TOTAL_FILES=FILE_COUNT_PLACEHOLDER
FILE_COUNT=0

verify_hash() {
    local computed_hash
    if [ ! -d "$REPO_NAME" ]; then
        echo "Error: Directory $REPO_NAME does not exist for verification" >&2
        exit 1
    fi
    if command -v md5sum >/dev/null 2>&1; then
        computed_hash=$(find "$REPO_NAME" -type f -exec cat {} + 2>/dev/null | md5sum | cut -d' ' -f1)
    elif command -v md5 >/dev/null 2>&1; then
        computed_hash=$(find "$REPO_NAME" -type f -exec cat {} + 2>/dev/null | md5 -r | cut -d' ' -f1)
    else
        echo "Error: md5sum or md5 required for verification" >&2
        exit 1
    fi
    if [ "$computed_hash" = "$SOURCE_HASH" ]; then
        echo "Verification successful: Hash matches ($SOURCE_HASH)" >&2
    else
        echo "Verification failed: Reproduced hash ($computed_hash) != original ($SOURCE_HASH)" >&2
        exit 1
    fi
}

recalculate_hash() {
    local new_hash
    if command -v md5sum >/dev/null 2>&1; then
        new_hash=$(find "$REPO_NAME" -type f -exec cat {} + 2>/dev/null | md5sum | cut -d' ' -f1)
    elif command -v md5 >/dev/null 2>&1; then
        new_hash=$(find "$REPO_NAME" -type f -exec cat {} + 2>/dev/null | md5 -r | cut -d' ' -f1)
    else
        echo "Error: md5sum or md5 required for hash recalculation" >&2
        exit 1
    fi
    echo "Old hash: $SOURCE_HASH" >&2
    echo "New hash: $new_hash" >&2
    sed -i "s/SOURCE_HASH=\".*\"/SOURCE_HASH=\"$new_hash\"/" "$0"
    echo "Hash updated in script to $new_hash" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dump) DUMP_MODE=true; shift ;;
        --update) UPDATE_MODE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --verify) VERIFY_MODE=true; shift ;;
        --recalculate-hash) RECALCULATE_HASH=true; shift ;;
        --retry-failed) RETRY_FAILED=true; shift ;;
        *) echo "Unknown option: $1" >&2; echo "Usage: $0 [--dump|--update|--dry-run|--verify|--recalculate-hash|--retry-failed]" >&2; exit 1 ;;
    esac
done

if [ "$DUMP_MODE" = true ]; then
    echo "Dumping contents of $REPO_NAME..." >&2
elif [ "$DRY_RUN" = true ]; then
    echo "Dry run: Previewing changes for $REPO_NAME" >&2
elif [ "$VERIFY_MODE" = true ]; then
    echo "Verifying repository: $REPO_NAME" >&2
elif [ "$RECALCULATE_HASH" = true ]; then
    echo "Recalculating hash for $REPO_NAME..." >&2
elif [ "$RETRY_FAILED" = true ]; then
    echo "Retrying failed file creations for $REPO_NAME..." >&2
else
    echo "Reproducing repository: $REPO_NAME (version $REPO_VERSION)" >&2
fi

BASE_DIR="$REPO_NAME"
if [ "$COMPRESS" = true ] && [ "$DUMP_MODE" = false ] && [ "$VERIFY_MODE" = false ] && [ "$RECALCULATE_HASH" = false ]; then
    mkdir -p "$BASE_DIR" || { echo "Failed to create $BASE_DIR" >&2; exit 1; }
    echo "echo 'Ensuring directory $BASE_DIR exists before decompression...' >&2" >> "$OUTPUT_SCRIPT"
fi
if [ "$DUMP_MODE" = false ] && [ "$VERIFY_MODE" = false ] && [ "$RECALCULATE_HASH" = false ]; then
    mkdir -p "$BASE_DIR" || { echo "Failed to create $BASE_DIR" >&2; exit 1; }
fi

# Dependency setup instructions
DEPS=""
[ -f "$BASE_DIR/package.json" ] && ! command -v npm >/dev/null 2>&1 && DEPS="$DEPS\n  - Node.js: Install with 'curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - && sudo apt-get install -y nodejs' then 'npm install'"
[ -f "$BASE_DIR/package.json" ] && command -v npm >/dev/null 2>&1 && DEPS="$DEPS\n  - Node.js: Run 'npm install'"
[ -f "$BASE_DIR/requirements.txt" ] && ! command -v pip >/dev/null 2>&1 && DEPS="$DEPS\n  - Python: Install with 'sudo apt-get install -y python3-pip' then 'pip install -r requirements.txt'"
[ -f "$BASE_DIR/requirements.txt" ] && command -v pip >/dev/null 2>&1 && DEPS="$DEPS\n  - Python: Run 'pip install -r requirements.txt'"
[ -n "$DEPS" ] && echo "echo 'Dependencies detected:$DEPS' >&2"
EOF

cat "$TEMP_SCRIPT" | \
    sed "s|REPO_NAME_PLACEHOLDER|$BASENAME|g" | \
    sed "s|REPO_VERSION_PLACEHOLDER|1.0-$SOURCE_HASH|g" | \
    sed "s|CREATED_DATE_PLACEHOLDER|$(date -u +'%Y-%m-%d %H:%M:%S UTC')|g" | \
    sed "s|SOURCE_HASH_PLACEHOLDER|$SOURCE_HASH|g" | \
    sed "s|FILE_COUNT_PLACEHOLDER|$FILE_COUNT|g" | \
    sed "s|TOTAL_SIZE_PLACEHOLDER|$TOTAL_SIZE|g" | \
    sed "s|GIT_COMMIT_PLACEHOLDER|$GIT_COMMIT|g" > "$OUTPUT_SCRIPT"

rm "$TEMP_SCRIPT"

# Directory structure - Use array to handle spaces and dots properly
if [ "$COMPRESS" = false ] || [ "$COMPRESS" = true ]; then
    mapfile -t DIR_ARRAY < <(find "$REPO_PATH" -type d -not -path "$REPO_PATH/.git/*" -not -path "$REPO_PATH/.git" -not -path "$REPO_PATH" | sed "s|^$REPO_PATH/||" | grep -v '^\.git$')
    if [ ${#DIR_ARRAY[@]} -gt 0 ]; then
        echo "if [ \"\$DUMP_MODE\" = false ] && [ \"\$DRY_RUN\" = false ] && [ \"\$VERIFY_MODE\" = false ] && [ \"\$RECALCULATE_HASH\" = false ]; then" >> "$OUTPUT_SCRIPT"
        printf '    mkdir -p "%s/"{%s} || { echo "Failed to create directories" >&2; exit 1; }\n' "\$BASE_DIR" "$(IFS=','; echo "${DIR_ARRAY[*]}")" >> "$OUTPUT_SCRIPT"
        echo "elif [ \"\$DRY_RUN\" = true ]; then" >> "$OUTPUT_SCRIPT"
        printf '    echo "Would create directories: %s/"{%s}\n' "\$BASE_DIR" "$(IFS=','; echo "${DIR_ARRAY[*]}")" >> "$OUTPUT_SCRIPT"
        echo "fi" >> "$OUTPUT_SCRIPT"
    fi
fi

# Debug: List files being processed
log "INFO" "Files to be processed for compression (>=$COMPRESS_THRESHOLD bytes):"
find "$(pwd)/$REPO_PATH" -type f -not -path "$(pwd)/$REPO_PATH/.git/*" -not -path "$(pwd)/$REPO_PATH/.git" -size +${COMPRESS_THRESHOLD}c -exec ls -l {} \; | while read -r line; do log "INFO" "$line"; done
log "INFO" "Files to be processed without compression (<$COMPRESS_THRESHOLD bytes):"
find "$REPO_PATH" -type f -not -path "$REPO_PATH/.git/*" -not -path "$REPO_PATH/.git" -size -${COMPRESS_THRESHOLD}c -exec ls -l {} \; | while read -r line; do log "INFO" "$line"; done

# File processing
if [ "$COMPRESS" = true ]; then
    echo "if [ \"\$DUMP_MODE\" = false ] && [ \"\$VERIFY_MODE\" = false ] && [ \"\$RECALCULATE_HASH\" = false ]; then" >> "$OUTPUT_SCRIPT"
    echo "    echo 'Ensuring directory $BASE_DIR exists before decompression...' >&2" >> "$OUTPUT_SCRIPT"
    echo "    mkdir -p \"\$BASE_DIR\" || { echo \"Failed to create \$BASE_DIR for decompression\" >&2; exit 1; }" >> "$OUTPUT_SCRIPT"
    echo "    echo 'Decompressing large files (>1MB)...' >&2" >> "$OUTPUT_SCRIPT"
    echo "    base64 -d <<'EOF' | gzip -d | tar -x -C \"\$BASE_DIR\" --strip-components=1" >> "$OUTPUT_SCRIPT"
    # Use absolute paths and filter only large files
    find "$(pwd)/$REPO_PATH" -type f -not -path "$(pwd)/$REPO_PATH/.git/*" -not -path "$(pwd)/$REPO_PATH/.git" -size +${COMPRESS_THRESHOLD}c -print0 | xargs -0 -I {} tar -czf - -C "$(dirname "{}")" "$(basename "{}")" | base64 >> "$OUTPUT_SCRIPT"
    echo "EOF" >> "$OUTPUT_SCRIPT"
    echo "    echo 'Decompression complete.' >&2" >> "$OUTPUT_SCRIPT"
    echo "fi" >> "$OUTPUT_SCRIPT"
    log "INFO" "Embedding uncompressed files..."
    # Ensure all small files are captured, including those not compressed
    find "$REPO_PATH" -type f -not -path "$REPO_PATH/.git/*" -not -path "$REPO_PATH/.git" -size -${COMPRESS_THRESHOLD}c > "$TEMP_SCRIPT.files"
else
    log "INFO" "Embedding all files..."
    find "$REPO_PATH" -type f -not -path "$REPO_PATH/.git/*" -not -path "$REPO_PATH/.git" > "$TEMP_SCRIPT.files"
fi

split -l "$CHUNK_SIZE" "$TEMP_SCRIPT.files" chunk_
for chunk in chunk_*; do
    if [ -f "$chunk" ]; then
        while read -r file; do
            process_file "$file" "$OUTPUT_SCRIPT" || { echo "Failed to process $file" >&2; exit 1; }
        done < "$chunk"
        rm "$chunk"
    fi
done
rm "$TEMP_SCRIPT.files"

# Finalize script
cat <<'EOF' >> "$OUTPUT_SCRIPT"
if [ "$RECALCULATE_HASH" = true ]; then
    recalculate_hash
elif [ "$DUMP_MODE" = true ]; then
    echo "Contents dumped above." >&2
elif [ "$DRY_RUN" = true ]; then
    echo "Dry run complete." >&2
elif [ "$VERIFY_MODE" = true ]; then
    verify_hash
elif [ "$RETRY_FAILED" = true ]; then
    echo "Retrying failed files completed." >&2
else
    echo "Repository reproduction complete (version $REPO_VERSION)." >&2
    echo "You are now in $PWD" >&2
    echo "Run './setup-$REPO_NAME.sh --verify' to check integrity, '--recalculate-hash' to update hash, or '--retry-failed' for failed files." >&2
fi
exit 0
EOF

chmod +x "$OUTPUT_SCRIPT"
log "INFO" "Generated script: $OUTPUT_SCRIPT"
echo -e "${GREEN}Success! Generated: $OUTPUT_SCRIPT${NC}"
echo "Run it with: ./setup-$BASENAME.sh [--dump|--update|--dry-run|--verify|--recalculate-hash|--retry-failed]"
log "INFO" "Process completed successfully."