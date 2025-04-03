#!/bin/bash

# RepoCapsule v1.0.0 # <--- VERSION CHANGE HERE
# Author: Jeff Morton (Original), Modifications for LLM Focus
# License: MIT
# Docs: See README.md

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# The return value of a pipeline is the status of the last command to exit with a non-zero status,
# or zero if no command exited with a non-zero status.
set -o pipefail

# --- Dependency Checks ---
# Ensure all required external commands are available in the PATH.
for cmd in bash date stat find cat sed mkdir chmod base64 shasum tr diff mktemp grep awk sort xargs pwd dirname basename printf uname cd file head realpath; do
    # coreutils is not a command itself, skip check
    if [[ "$cmd" == "coreutils" ]]; then continue; fi
    # Check if command exists
    if ! command -v "$cmd" >/dev/null 2>&1; then
        # Special handling for realpath on macOS (might be grealpath via coreutils)
        if [[ "$cmd" == "realpath" ]] && command -v grealpath >/dev/null 2>&1; then
             echo "[INFO] 'realpath' not found, but 'grealpath' found (likely macOS with coreutils)." >&2
        else
            # Standard error message if command is missing
            echo "Error: Required command '$cmd' not found in PATH." >&2
            exit 1
        fi
    fi
done
# uuidgen is optional, provide a warning if not found
if ! command -v uuidgen >/dev/null 2>&1; then echo "Warning: 'uuidgen' not found. Using less unique delimiters (date+random)." >&2; fi
# Check for minimum required Bash version (4.0+)
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then echo "Error: Bash 4.0 or higher required (you have ${BASH_VERSION})" >&2; exit 1; fi

# --- Default configurations ---
VERBOSE=false                 # Flag for verbose output during generation
FORCE=false                   # Flag to force overwrite of existing output script
CREATE_INDEX=false            # Flag to generate a separate index file
OUTPUT_DIR="."                # Default output directory for the generated script
REPO_NAME=""                  # Repository name (defaults to source directory basename)
REPO_VERSION="1.0.0"          # Default repository version
EXCLUDE_GIT=true              # Flag to exclude .git directory and related files by default
# Default patterns to exclude (used if EXCLUDE_GIT is true)
DEFAULT_EXCLUDES=( ".git" ".gitignore" "*.md" "LICENSE" ".DS_Store" )
USER_EXCLUDES=()              # Array to hold user-specified exclusion patterns
METADATA_LINES=()             # Array to hold custom metadata lines for the LLM
SOURCE_DIR=""                 # Source directory to be packaged (set during argument parsing)
declare -A FILE_INFO_MAP      # Associative array to store file metadata (size, perms, binary flag)

# --- OS Detection & realpath command selection ---
REALPATH_CMD=""
# Prefer grealpath if available (often from GNU coreutils on macOS)
if command -v grealpath >/dev/null 2>&1; then REALPATH_CMD="grealpath -L";
# Check if standard realpath supports -L (resolve symlinks logically)
elif command -v realpath >/dev/null 2>&1 && realpath -L . >/dev/null 2>&1; then REALPATH_CMD="realpath -L";
# Fallback to realpath -P (resolve symlinks physically) if -L is not supported
elif command -v realpath >/dev/null 2>&1 && realpath -P . >/dev/null 2>&1; then echo "[WARN] realpath -L not supported, falling back to -P." >&2; REALPATH_CMD="realpath -P";
# Error if no working realpath command is found
else echo "Error: Cannot find a working 'realpath' or 'grealpath' command." >&2; exit 1; fi
# Debug output for the selected realpath command
[[ "$VERBOSE" = true ]] && echo "[DEBUG] Using realpath command: $REALPATH_CMD" >&2

# --- Usage message ---
# Function to display help text
usage() {
    # Use a heredoc for the usage message
    cat <<EOF
Usage: $0 [OPTIONS] <source_directory>
Create a self-contained Bash script to reproduce a directory, optimized for LLM interaction.

Options:
  -v, --verbose           Enable verbose output during generation.
  -f, --force             Overwrite existing output script without prompting.
  -i, --create-index      Generate a separate '.index' file mapping file paths to line numbers.
  -o, --output-dir DIR    Directory to save the generated script (default: current directory).
  -n, --name NAME         Repository name (default: basename of source_directory).
  -V, --version VER       Repository version (default: 1.0.0).
  -g, --include-git       Include .git directory and common git files (overrides defaults).
  -e, --exclude PATTERN   Add a find pattern to exclude files/dirs (can be used multiple times).
  -m, --metadata "INFO"   Add a line of custom metadata for the LLM (can be used multiple times).
  -h, --help              Show this help message and exit.

<source_directory>       The directory to package into the script.

Generated Script Features (\$(basename \$OUTPUT_SCRIPT)): See its --help option and README.md.
Key features include standard system prompt, direct text editing, TOC, markers, --diff, --verify.
EOF
    # Exit after displaying help
    exit 0
}

# --- Argument Parsing ---
# Loop through command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose)       VERBOSE=true; shift ;;
        -f|--force)         FORCE=true; shift ;;
        -i|--create-index)  CREATE_INDEX=true; shift ;;
        -o|--output-dir)    OUTPUT_DIR="$2"; shift 2 ;; # Option takes an argument
        -n|--name)          REPO_NAME="$2"; shift 2 ;;   # Option takes an argument
        -V|--version)       REPO_VERSION="$2"; shift 2 ;; # Option takes an argument
        -g|--include-git)   EXCLUDE_GIT=false; shift ;;
        -e|--exclude)       USER_EXCLUDES+=("$2"); shift 2 ;; # Option takes an argument, can be repeated
        -m|--metadata)      METADATA_LINES+=("$2"); shift 2 ;; # Option takes an argument, can be repeated
        -h|--help)          usage ;; # Display help and exit
        -*)                 # Handle unknown options
            echo "Error: Unknown option '$1'" >&2
            usage # Display help and exit with error
            ;;
        *)                  # Handle positional arguments (the source directory)
            if [[ -z "$SOURCE_DIR" ]]; then
                SOURCE_DIR="$1"; shift; # Assign the first non-option argument to SOURCE_DIR
            else
                # Error if more than one source directory is specified
                echo "Error: Multiple source directories specified ('$SOURCE_DIR' and '$1')" >&2
                usage # Display help and exit with error
            fi
            ;;
    esac
done

# --- Input Validation ---
# Function to get a robust absolute path, handling various edge cases
# This function aims for portability by using basic commands like cd and pwd
# rather than relying solely on potentially non-standard realpath options like -m.
get_absolute_path() {
    local target_path="$1"
    local abs_path=""
    local original_dir
    # Store the current directory to return later
    original_dir=$(pwd)
    # Check if the target path is an existing directory
    if [[ -d "$target_path" ]]; then
        # Try changing to the directory
        if ! cd "$target_path"; then
            echo "Error: cd to '$target_path' failed." >&2
            # Attempt to return to the original directory
            cd "$original_dir" &>/dev/null
            return 1
        fi
        # Get the absolute path using pwd -P (physical path)
        abs_path=$(pwd -P)
        # Return to the original directory, suppress errors if it fails (e.g., deleted)
        cd "$original_dir" &>/dev/null || true
    # Check if the target path exists but is not a directory (e.g., a file)
    elif [[ -e "$target_path" ]]; then
        echo "Error: Path '$target_path' is not a directory." >&2
        return 1
    # Handle cases where the target path does not exist
    else
        local parent_dir
        parent_dir=$(dirname "$target_path") || return 1 # Get the parent directory name
        local base_name
        base_name=$(basename "$target_path") || return 1 # Get the base name
        # Check if the parent directory exists
        if [[ ! -d "$parent_dir" ]]; then
            # Allow '.' as a non-existent parent (relative to current dir)
            if [[ "$parent_dir" != "." ]]; then
                echo "Error: Parent directory '$parent_dir' does not exist." >&2
                return 1
            fi
        fi
        # Try changing to the parent directory
        if ! cd "$parent_dir"; then
            echo "Error: cd to parent '$parent_dir' failed." >&2
            cd "$original_dir" &>/dev/null
            return 1
        fi
        local parent_abs_path
        parent_abs_path=$(pwd -P) # Get the absolute path of the parent
        # Return to the original directory
        cd "$original_dir" &>/dev/null || true
        # Construct the absolute path for the non-existent target
        # Handle parent being '.' -> current directory's abs path
        if [[ "$parent_abs_path" == "/" ]]; then
             abs_path="/$base_name"
        else
             abs_path="$parent_abs_path/$base_name"
        fi
    fi
    # Final validation: ensure the path is not empty and starts with '/'
    if [[ -z "$abs_path" || "$abs_path" != /* ]]; then
        echo "Error: Failed valid absolute path for '$target_path'." >&2
        return 1
    fi
    # Print the absolute path
    echo "$abs_path"
    return 0
}

# Ensure source directory was specified
if [[ -z "$SOURCE_DIR" ]]; then echo "Error: Source directory not specified." >&2; usage; fi
# Ensure source directory exists and is a directory
if [[ ! -d "$SOURCE_DIR" ]]; then echo "Error: Source '$SOURCE_DIR' is not a valid directory." >&2; exit 1; fi
# Get the absolute path of the source directory using the selected realpath command
SOURCE_DIR_ABS=$($REALPATH_CMD "$SOURCE_DIR") || { echo "Error: Failed to resolve realpath for source directory '$SOURCE_DIR'."; exit 1; }
# Ensure output path, if it exists, is a directory
if [[ -e "$OUTPUT_DIR" && ! -d "$OUTPUT_DIR" ]]; then echo "Error: Output path '$OUTPUT_DIR' exists but is not a directory." >&2; exit 1; fi
# Get the absolute path of the output directory using the custom helper function
OUTPUT_DIR_ABS=$(get_absolute_path "$OUTPUT_DIR") || { echo "Error: Failed to resolve absolute path for output directory '$OUTPUT_DIR'."; exit 1; }
# Update SOURCE_DIR and OUTPUT_DIR with their absolute paths
SOURCE_DIR="$SOURCE_DIR_ABS"; OUTPUT_DIR="$OUTPUT_DIR_ABS"
# Set default repository name if not provided
if [[ -z "$REPO_NAME" ]]; then REPO_NAME=$(basename "$SOURCE_DIR"); fi
# Define the full paths for the output script and index file
OUTPUT_SCRIPT="$OUTPUT_DIR/setup-$REPO_NAME.sh"; OUTPUT_INDEX_FILE="$OUTPUT_SCRIPT.index"
# Check for existing output script and prompt for overwrite if --force is not used
if [[ -f "$OUTPUT_SCRIPT" ]] && [[ "$FORCE" != true ]]; then read -p "Output script '$OUTPUT_SCRIPT' already exists. Overwrite? (y/N) " -n 1 -r REPLY; echo; if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then echo "Aborted." >&2; exit 1; fi; fi
# Check for existing index file and prompt for overwrite if --force is not used
if [[ "$CREATE_INDEX" == true && -f "$OUTPUT_INDEX_FILE" ]] && [[ "$FORCE" != true ]]; then read -p "Index file '$OUTPUT_INDEX_FILE' already exists. Overwrite? (y/N) " -n 1 -r REPLY; echo; if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then echo "Aborted." >&2; exit 1; fi; fi

# Create the output directory if it doesn't exist
if [[ ! -d "$OUTPUT_DIR" ]]; then
    echo "[INFO] Creating output directory: $OUTPUT_DIR" >&2
    mkdir -p "$OUTPUT_DIR" || { echo "[ERROR] Failed to create output directory '$OUTPUT_DIR'." >&2; exit 1; }
fi

# Create a temporary file for building the script
TEMP_SCRIPT=$(mktemp "${OUTPUT_DIR}/repocapsule_temp.XXXXXX") || { echo "Error: Failed to create temporary file in '$OUTPUT_DIR'." >&2; exit 1; }
# Set up a trap to remove the temporary file on exit, error, or specific signals
trap 'rm -f "$TEMP_SCRIPT" "$TEMP_SCRIPT.bak"* "$TEMP_SCRIPT.sedtest"*' EXIT ERR SIGINT SIGTERM # Added sedtest cleanup

# --- Helper Functions ---
# Function to determine if a file is likely binary
is_binary() {
    # Revised logic for robustness
    local file="$1"

    # Basic read checks
    if [[ ! -r "$file" ]]; then echo "[WARN] Cannot read file '$file' for binary check. Assuming text." >&2; return 1; fi
    # Check if file is empty
    if [[ ! -s "$file" ]]; then return 1; fi # Empty files are not binary
    # Check if head fails on a non-empty file (could indicate device file or similar)
    # Allow head to fail gracefully in case of unusual files/permissions
    if ! head -c 1 "$file" > /dev/null 2>&1; then
        echo "[WARN] Cannot read head of non-empty file '$file'. Assuming binary." >&2;
        return 0;
    fi

    # 1. Primary check: Null byte detection (most reliable)
    # Use LC_ALL=C for grep to ensure byte-wise operation
    if head -c 1024 "$file" | LC_ALL=C grep -q '\x00'; then
        [[ "$VERBOSE" = true ]] && echo "[DEBUG] Detected null byte in '$file'. Assuming BINARY." >&2
        return 0 # Binary
    fi

    # 2. Secondary check: Use `file` command if available
    if command -v file >/dev/null 2>&1; then
        # Use LC_ALL=C for file command for consistent output
        local file_mime_type; file_mime_type=$(LC_ALL=C file --brief --mime-type "$file" 2>/dev/null) || file_mime_type="" # Use --mime-type, handle errors
        [[ "$VERBOSE" = true ]] && echo "[DEBUG] 'file --mime-type' output for '$file': $file_mime_type" >&2

        # Check for text MIME types first
        if echo "$file_mime_type" | grep -q -E '^text/'; then
            [[ "$VERBOSE" = true ]] && echo "[DEBUG] Detected text MIME type in '$file'. Assuming TEXT." >&2
             # Check for charset=binary which indicates non-text despite text/* MIME
             local file_mime_full; file_mime_full=$(LC_ALL=C file --brief --mime "$file" 2>/dev/null) || file_mime_full="" # Handle errors
             if echo "$file_mime_full" | grep -q 'charset=binary'; then
                 [[ "$VERBOSE" = true ]] && echo "[DEBUG] MIME type is text/* but charset=binary found for '$file'. Overriding to BINARY." >&2
                 return 0 # Binary despite text/*
             else
                 return 1 # Text
             fi
        fi

        # Check for common binary MIME types
        if echo "$file_mime_type" | grep -q -E '^(application|image|audio|video|font)/'; then
            # Check for specific application types known to be text-based
            # Added common web/config formats
            if echo "$file_mime_type" | grep -q -E 'application/(json|xml|javascript|xhtml\+xml|rss\+xml|atom\+xml|yaml|toml|csv|x-sh|x-shellscript|x-httpd-php|x-perl|x-python|x-ruby|sql|markdown|ld\+json|svg\+xml)'; then
                [[ "$VERBOSE" = true ]] && echo "[DEBUG] Detected text-based application MIME type in '$file'. Assuming TEXT." >&2
                return 1 # Text
            else
                # Assume other application/* types are binary unless proven otherwise
                [[ "$VERBOSE" = true ]] && echo "[DEBUG] Detected binary application/media MIME type in '$file'. Assuming BINARY." >&2
                return 0 # Binary
            fi
        fi

        # If MIME type is inconclusive (e.g., inode/x-empty), check file description
        local file_desc; file_desc=$(LC_ALL=C file --brief "$file" 2>/dev/null) || file_desc="" # Handle errors
        [[ "$VERBOSE" = true ]] && echo "[DEBUG] 'file --brief' output (fallback) for '$file': $file_desc" >&2
        # Check for common text descriptions (expanded list)
        if echo "$file_desc" | grep -q -E '(ASCII|UTF-8|ISO-8859) text|shell script|JSON data|XML.* text|empty|source code|HTML document|CSS stylesheet|CSV text|YAML document|TOML document|configuration file|data|script text'; then
             [[ "$VERBOSE" = true ]] && echo "[DEBUG] Detected text keywords in description for '$file'. Assuming TEXT." >&2
             return 1 # Text
        fi

        # If still inconclusive after checking description, assume binary
        [[ "$VERBOSE" = true ]] && echo "[DEBUG] Could not determine type from 'file' command for '$file'. Assuming BINARY." >&2
        return 0 # Binary
    fi

    # 3. Fallback check: Non-printable characters (if `file` command is missing)
    echo "[WARN] 'file' command not found. Using fallback non-printable character check for '$file'." >&2
    # Ensure LC_ALL=C for tr and grep for consistent byte processing
    # Check first 1024 bytes for non-printable/non-tab/non-newline/non-CR characters
    if head -c 1024 "$file" | LC_ALL=C tr -d '\t\n\r\f\v' | LC_ALL=C grep -q '[^[:print:]]'; then
        [[ "$VERBOSE" = true ]] && echo "[DEBUG] Fallback detected non-printable chars in '$file'. Assuming BINARY." >&2
        return 0 # Binary
    else
        [[ "$VERBOSE" = true ]] && echo "[DEBUG] Fallback did not detect non-printable chars in '$file'. Assuming TEXT." >&2
        return 1 # Text
    fi
}


# Function to sanitize a filename for use in delimiters (replace non-alphanumeric with underscore)
sanitize_filename() {
    local sanitized
    # Use parameter expansion for efficiency and portability
    sanitized="${1//[^a-zA-Z0-9_]/_}"
    # Ensure it doesn't start with a number (problematic for some shells/vars)
    if [[ "$sanitized" =~ ^[0-9] ]]; then
        sanitized="_$sanitized"
    fi
    # Ensure it's not empty after sanitization
    if [[ -z "$sanitized" ]]; then
        sanitized="file"
    fi
    echo "$sanitized"
}

# Function to generate a unique delimiter string for heredocs
generate_delimiter() {
    local prefix="EOF"
    local sanitized_name="$1"
    # Use uuidgen for high uniqueness if available
    if command -v uuidgen > /dev/null 2>&1; then
        echo "${prefix}_$(uuidgen)_${sanitized_name}"
    # Fallback to date (nanoseconds) + random number
    else
        local dt; dt=$(date +%s%N) # Capture date output
        echo "${prefix}_${dt}_${RANDOM}_${sanitized_name}"
    fi
}

# Function to get file permissions in octal format (e.g., 644, 755)
get_perms() {
    local file="$1"
    local perms=""
    # Try GNU stat format
    if stat -c %a "$file" > /dev/null 2>&1; then
        perms=$(stat -c %a "$file")
    # Try BSD stat format
    elif stat -f %Lp "$file" > /dev/null 2>&1; then
        perms=$(stat -f %Lp "$file")
    # Warn and default if permissions cannot be determined
    else
        echo "[WARN] Cannot determine permissions for '$file'. Using 644." >&2
        perms="644"
    fi
    # Validate the obtained permissions format (3 or 4 octal digits)
    if [[ "$perms" =~ ^[0-7]{3,4}$ ]]; then
        echo "$perms"
    # Warn and default if the format is unexpected
    else
        echo "[WARN] Bad permission format '$perms' for '$file'. Using 644." >&2
        echo "644"
    fi
}

# Function to get file size in bytes
get_size() {
    local file="$1"
    local size=""
    # Try GNU stat format
    if stat -c %s "$file" > /dev/null 2>&1; then
        size=$(stat -c %s "$file")
    # Try BSD stat format
    elif stat -f %z "$file" > /dev/null 2>&1; then
        size=$(stat -f %z "$file")
    # Warn and default to 0 if size cannot be determined
    else
        echo "[WARN] Cannot determine size for '$file'. Using 0." >&2
        size="0"
    fi
    # Validate size is a non-negative integer
    if [[ "$size" =~ ^[0-9]+$ ]]; then
        echo "$size"
    else
        echo "[WARN] Bad size format '$size' for '$file'. Using 0." >&2
        echo "0"
    fi
}

# --- File Processing and Embedding Function ---
# This function generates the Bash code block within the output script
# that will recreate a single file.
create_file_embedding() {
    local abs_file="$1"        # Absolute path to the source file
    local rel_file="$2"        # Relative path (used for target and markers)
    local size="$3"            # File size
    local perms="$4"           # File permissions (octal)
    local is_binary_flag="$5"  # Boolean flag: true if binary, false if text
    local unique_delimiter

    # Generate a unique delimiter for the heredoc
    unique_delimiter=$(generate_delimiter "$(sanitize_filename "$rel_file")")

    # Verbose logging during generation
    [[ "$VERBOSE" = true ]] && echo "Embedding: $rel_file ($size bytes, perms: $perms, binary: $is_binary_flag)" >&2

    # Sanity check: Ensure the temporary script file still exists
    if [[ ! -f "$TEMP_SCRIPT" ]]; then
        echo "[ERROR] Temporary script '$TEMP_SCRIPT' lost before embedding '$rel_file'." >&2
        exit 1
    fi

    # Use separate appends for clarity and to avoid complex quoting within a single heredoc.

    # Start marker and setup code block (common to both binary and text)
    cat <<EOF >> "$TEMP_SCRIPT"

# <<< BEGIN FILE: $rel_file >>>
# Metadata: Size: $size bytes, Perms: $perms, Binary: $is_binary_flag
echo "[INFO] Processing: \$TARGET_DIR_ABS/$rel_file"
# Create the parent directory if it doesn't exist
mkdir -p "\$(dirname "\$TARGET_DIR_ABS/$rel_file")" || { echo "[ERROR] Failed to create directory for \$TARGET_DIR_ABS/$rel_file" >&2; FAILED_FILES+=("\$TARGET_DIR_ABS/$rel_file"); return 1; }

EOF

    # Handle binary file embedding
    if [[ "$is_binary_flag" == true ]]; then
        # Generate base64 content first to avoid syntax issues with command substitution in heredoc.
        # Use input redirection for base64 compatibility (BSD vs GNU).
        # Add error handling for base64 command itself.
        local base64_content
        if ! base64_content=$(base64 < "$abs_file"); then
             echo "[ERROR] base64 encoding failed for '$abs_file'. Skipping embedding." >&2
             # Add a placeholder in the script indicating failure
             cat <<EOF >> "$TEMP_SCRIPT"
# Content: [ERROR] Base64 encoding failed during script generation for this file. Content omitted.
echo "[ERROR] Content for \$TARGET_DIR_ABS/$rel_file was omitted due to generation error." >&2
FAILED_FILES+=("\$TARGET_DIR_ABS/$rel_file");
# <<< END FILE: $rel_file >>>

EOF
             return # Skip the rest of this file's embedding
        fi

        # Append the if/heredoc structure with the content embedded
        cat <<EOF >> "$TEMP_SCRIPT"
# Content: Binary file embedded using base64. LLMs should NOT EDIT this section.
if echo "Decoding base64 for \$TARGET_DIR_ABS/$rel_file..." >&2 && base64 --decode <<'$unique_delimiter' > "\$TARGET_DIR_ABS/$rel_file"; then
${base64_content}
$unique_delimiter
    # Set permissions after successful decoding
    chmod "$perms" "\$TARGET_DIR_ABS/$rel_file" || echo "[WARN] Failed permissions $perms on \$TARGET_DIR_ABS/$rel_file" >&2
    # Increment counters
    FILE_COUNT_RUN=\$((FILE_COUNT_RUN + 1)); TOTAL_FILES_CREATED=\$((TOTAL_FILES_CREATED + 1))
    echo "[ OK ] \$FILE_COUNT_RUN/\$TOTAL_FILES_EXPECTED: Created \$TARGET_DIR_ABS/$rel_file (binary)"
else
    # Handle decoding/writing errors
    echo "[ERROR] Failed decode/write \$TARGET_DIR_ABS/$rel_file" >&2; FAILED_FILES+=("\$TARGET_DIR_ABS/$rel_file"); rm -f "\$TARGET_DIR_ABS/$rel_file"
fi
# <<< END FILE: $rel_file >>>

EOF
    # Handle text file embedding
    else
        # Append code to write text content using a heredoc
        # shellcheck disable=SC2129
        cat <<EOF >> "$TEMP_SCRIPT"
# Content: Plain text. LLMs can safely edit the content below this line,
#          up to the '$unique_delimiter' marker.
if echo "Writing text content for \$TARGET_DIR_ABS/$rel_file..." >&2 && cat <<'$unique_delimiter' > "\$TARGET_DIR_ABS/$rel_file"; then
EOF
        # Append the actual file content, properly escaped for the heredoc.
        # Use LC_ALL=C for sed consistency. Escape backslash and dollar sign.
        # Handle potential sed errors.
        if ! LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/\$/\\$/g' "$abs_file" >> "$TEMP_SCRIPT"; then
             echo "[ERROR] sed escaping failed for '$abs_file'. Aborting script generation." >&2
             # Clean up the partial heredoc start and add placeholder content
             # Use command grouping for redirects (SC2129 fix)
             {
                 echo "[ERROR] Content for $rel_file omitted due to sed error during generation"
                 echo "$unique_delimiter" # Close the heredoc syntactically
                 # Add error handling logic within generated script
                 cat <<EOF_SED_ERROR
else
    # Handle writing errors or generation errors
    echo "[ERROR] Failed write heredoc (or content omitted due to generation error) for \$TARGET_DIR_ABS/$rel_file" >&2; FAILED_FILES+=("\$TARGET_DIR_ABS/$rel_file"); rm -f "\$TARGET_DIR_ABS/$rel_file"
fi
# <<< END FILE: $rel_file >>>

EOF_SED_ERROR
             } >> "$TEMP_SCRIPT"

             return # Stop processing this file if sed failed
        fi

        # Append the closing delimiter and post-creation logic
        # shellcheck disable=SC2129
        cat <<EOF >> "$TEMP_SCRIPT"
$unique_delimiter
    # Set permissions after successful writing
    chmod "$perms" "\$TARGET_DIR_ABS/$rel_file" || echo "[WARN] Failed permissions $perms on \$TARGET_DIR_ABS/$rel_file" >&2
    # Increment counters
    FILE_COUNT_RUN=\$((FILE_COUNT_RUN + 1)); TOTAL_FILES_CREATED=\$((TOTAL_FILES_CREATED + 1))
    echo "[ OK ] \$FILE_COUNT_RUN/\$TOTAL_FILES_EXPECTED: Created \$TARGET_DIR_ABS/$rel_file (text)"
else
    # Handle writing errors
    echo "[ERROR] Failed write heredoc \$TARGET_DIR_ABS/$rel_file" >&2; FAILED_FILES+=("\$TARGET_DIR_ABS/$rel_file"); rm -f "\$TARGET_DIR_ABS/$rel_file"
fi
# <<< END FILE: $rel_file >>>

EOF
    fi
}


# --- Start Generating the Output Script ---
# Record generation timestamp
CREATED_DATE=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
GIT_COMMIT="N/A" # Default Git commit value
# Try to get the current Git commit hash if .git exists and is included
if [[ -d "$SOURCE_DIR/.git" ]] && [[ "$EXCLUDE_GIT" != true ]]; then
    # Use subshell to avoid changing the script's directory
    # Redirect stderr to /dev/null to suppress git errors if not a repo or no commits
    GIT_COMMIT=$( (cd "$SOURCE_DIR" && git rev-parse --short HEAD 2>/dev/null) ) || GIT_COMMIT="N/A (git error or no commit)"
fi

# --- Single Pass: Collect File Info ---
echo "[INFO] Scanning source directory and collecting file metadata..." >&2
TOTAL_SIZE_GEN=0    # Initialize total size counter for generation
FILE_COUNT_GEN=0    # Initialize file count for generation
# Ensure FILE_INFO_MAP is explicitly declared as associative (redundant due to earlier declare -A, but safe)
declare -A FILE_INFO_MAP

# Build the list of active exclusion patterns
declare -a ACTIVE_EXCLUDES
if [[ "$EXCLUDE_GIT" = true ]]; then
    # Add default excludes if EXCLUDE_GIT is true
    ACTIVE_EXCLUDES+=( "${DEFAULT_EXCLUDES[@]}" )
fi
# Add any user-specified excludes
ACTIVE_EXCLUDES+=( "${USER_EXCLUDES[@]}" )

# Prepare arguments for the 'find' command's exclusion logic
declare -a FIND_EXCLUDE_ARGS=()         # Array for find command arguments (absolute paths for scanning)
declare -a FIND_EXCLUDE_ARGS_STRINGS=() # Array to store string representation for runtime hash (relative paths)
if [[ ${#ACTIVE_EXCLUDES[@]} -gt 0 ]]; then
    FIND_EXCLUDE_ARGS+=(\() # Start grouping parentheses for exclusions
    needs_or=false          # Flag to track if '-o' (OR) is needed between patterns
    for pattern in "${ACTIVE_EXCLUDES[@]}"; do
        # Add '-o' before the second and subsequent patterns
        if $needs_or; then FIND_EXCLUDE_ARGS+=(-o); FIND_EXCLUDE_ARGS_STRINGS+=("-o"); fi
        # Use '-path' for patterns containing '/' or exactly ".git" (matches full path relative to start)
        # Use '-prune' to prevent descending into excluded directories matching path
        # Runtime paths should be relative (e.g., './.git')
        if [[ "$pattern" == */* ]] || [[ "$pattern" == ".git" ]]; then
            FIND_EXCLUDE_ARGS+=(-path "$SOURCE_DIR/$pattern" -prune )
            # Store relative path prefixed with './' for runtime find consistency
            FIND_EXCLUDE_ARGS_STRINGS+=("-path" "./$pattern" "-prune")
        # Use '-name' for simple filename patterns
        else
            FIND_EXCLUDE_ARGS+=(-name "$pattern" )
            FIND_EXCLUDE_ARGS_STRINGS+=("-name" "$pattern") # Store pattern for runtime (already relative)
        fi
        needs_or=true # Set flag for the next iteration
    done
    FIND_EXCLUDE_ARGS+=(\)) # End grouping parentheses
fi

# Construct the final 'find' command array for the initial scan (using absolute paths)
# Scan starts from SOURCE_DIR, finds files (-type f), excluding specified patterns.
# Exclusions need '-prune' to stop descending, and '-o' connects the prune logic with the desired find action.
declare -a find_cmd_scan_array=()
find_cmd_scan_array=(find "$SOURCE_DIR") # Start with source directory

if [[ ${#FIND_EXCLUDE_ARGS[@]} -gt 0 ]]; then
    # If there are exclusions: find <source> \( <exclusions> \) -prune -o -type f -print0
    # The structure is: find path [ \( expr \) -prune ] -o [ condition_to_print ]
    find_cmd_scan_array+=( "${FIND_EXCLUDE_ARGS[@]}" -o )
fi
# Add the condition for files to print after exclusion logic
find_cmd_scan_array+=( -type f -print0 )

# Debug output for the find command
[[ "$VERBOSE" = true ]] && echo "[DEBUG] Executing find command for scan: ${find_cmd_scan_array[*]}" >&2

# Process the files found by the 'find' command
# Uses process substitution and null delimiters for safe filename handling
# Redirect stderr of find to /dev/null to suppress permission errors, handle file errors below
while IFS= read -r -d $'\0' file; do
    # Verbose logging for each file found
    [[ "$VERBOSE" = true ]] && echo "[DEBUG] Find loop read file: $file" >&2

    # Check if file is readable before processing further
    if [[ ! -r "$file" ]]; then
        echo "[WARN] Skipping unreadable file found by find: $file" >&2
        continue
    fi

    # Calculate the relative path by removing the source directory prefix
    rel_file="${file#"$SOURCE_DIR"/}"
    # Ensure rel_file doesn't start with / if SOURCE_DIR was /
    rel_file="${rel_file#\/}"
    abs_file="$file" # Absolute path is the direct output from find

    [[ "$VERBOSE" = true ]] && echo "[DEBUG] Calculated relative path: $rel_file" >&2

    # Get file metadata using helper functions
    size_val=$(get_size "$abs_file")
    perms_val=$(get_perms "$abs_file")
    is_binary_flag=false
    # Use subshell to isolate is_binary call and capture its return status
    if (is_binary "$abs_file"); then is_binary_flag=true; fi

    # Store metadata in the associative map, keyed by relative path
    FILE_INFO_MAP["$rel_file"]="size=$size_val perms=$perms_val binary=$is_binary_flag"

    # Update total size and file count
    TOTAL_SIZE_GEN=$((TOTAL_SIZE_GEN + size_val))
    FILE_COUNT_GEN=$((FILE_COUNT_GEN + 1))
done < <( LC_ALL=C "${find_cmd_scan_array[@]}" 2>/dev/null ) # Feed find output into the loop, force C locale, ignore find's stderr

echo "[INFO] Found $FILE_COUNT_GEN files, total size $TOTAL_SIZE_GEN bytes." >&2

# --- Write Generated Script Header ---
# Use a heredoc to write the initial part of the generated script to the temporary file
# Use single quotes around the delimiter to prevent expansion of variables like $0
# Add shellcheck directives to ignore expected "unused variable" warnings in generated script
cat <<'EOF_GENERATED_SCRIPT_HEADER' > "$TEMP_SCRIPT"
#!/bin/bash
# --- RepoCapsule Generated Script (v1.0.0) --- # <--- VERSION CHANGE HERE
# Generated by RepoCapsule v1.0.0 (LLM-Optimized Workflow) # <--- VERSION CHANGE HERE
# Generation Date: CREATED_DATE_PLACEHOLDER
# Source Git Commit: GIT_COMMIT_PLACEHOLDER

# ==============================================================================
# <<< RECOMMENDED LLM SYSTEM PROMPT >>>
# You are an expert software developer assisting with code generation and modification.
# You will be given a single Bash script generated by RepoCapsule. This script *contains*
# an entire directory structure and its file contents. Your primary goal is to modify
# the *text file content embedded within this script* as requested by the user.

# KEY INSTRUCTIONS:
# 1.  **Identify Files:** Locate files using the markers: `# <<< BEGIN FILE: path/to/file >>>`.
# 2.  **Edit Text Content ONLY:**
#     *   For files marked `# Content: Plain text.`, you can safely edit the lines *between* the `cat <<'EOF_...` line and its corresponding `EOF_...` delimiter line.
#     *   **DO NOT** edit lines outside of these text content blocks unless specifically asked.
#     *   **DO NOT** edit the `# <<< BEGIN FILE: ... >>>` or `# <<< END FILE: ... >>>` markers.
#     *   **DO NOT** edit blocks marked `# Content: Binary file embedded using base64.`. These are base64 encoded and must not be changed. Ensure the base64 block and its delimiter are unmodified.
#     *   **DO NOT** change the unique `EOF_...` delimiters themselves.
# 3.  **Preserve Structure:** Maintain the script's overall Bash syntax and structure. Do not change variable names (`$TARGET_DIR_ABS`, `$perms`, etc.) or the control flow logic (loops, conditionals) unless the user's request *explicitly* targets the script's runtime behavior itself.
# 4.  **Respect Delimiters:** Ensure the unique `EOF_...` delimiters for each file remain on their own lines and are unchanged.
# 5.  **Output Format:** Your output should be the *entire modified Bash script*, maintaining its original structure and formatting (indentation, comments, etc.). Do not just output the changed code snippets.
# 6.  **Context:** Use the `# --- Custom Project Metadata ---` section and the Table of Contents (`# --- Table of Contents ---`) for context about the project if needed.
# 7.  **Verification:** The user can verify your changes using the script's `--diff` and `--verify` options against the original source or a previously known state. The `SOURCE_HASH` value is critical for this verification. *Do not change the `SOURCE_HASH` value*. If your modifications are accepted, the user will run `--recalculate-hash` themselves.
# <<< END RECOMMENDED LLM SYSTEM PROMPT >>>
# ==============================================================================

# --- Script Metadata (Generated) ---
# shellcheck disable=SC2034
REPO_NAME="REPO_NAME_PLACEHOLDER"
# shellcheck disable=SC2034
REPO_VERSION="REPO_VERSION_PLACEHOLDER"
SOURCE_HASH="SOURCE_HASH_PLACEHOLDER" # SHA256 hash of original combined file contents
TOTAL_FILES_EXPECTED=FILE_COUNT_PLACEHOLDER # Expected number of files to create
# shellcheck disable=SC2034
TOTAL_SIZE_ORIGINAL=TOTAL_SIZE_PLACEHOLDER  # Original total size in bytes
# Store original exclusion args (relative paths) for runtime hash consistency
# These arguments are used by the 'calculate_dir_hash' function at runtime.
# Note: This is a space-separated string representation of the find arguments.
FIND_EXCLUDE_ARGS_ORIGINAL_STR="FIND_EXCLUDE_ARGS_STRINGS_PLACEHOLDER"

# --- Custom Project Metadata (Provided during generation) ---
# LLM Instructions: Use this metadata for context about the project.
EOF_GENERATED_SCRIPT_HEADER

# Append custom metadata lines provided by the user via -m option
if [[ ${#METADATA_LINES[@]} -gt 0 ]]; then
    for line in "${METADATA_LINES[@]}"; do
        # Escape potential shell metacharacters (\, ", $, `) in the metadata line
        # before adding it as a comment to prevent script errors.
        escaped_line=$(printf '%s\n' "$line" | sed 's/[\\"$`]/\\&/g')
        echo "# $escaped_line" >> "$TEMP_SCRIPT"
    done
else
    # Add a placeholder comment if no custom metadata was provided
    echo "# (No custom metadata provided)" >> "$TEMP_SCRIPT"
fi

# Append the start of the Table of Contents section
cat <<'EOF_TOC' >> "$TEMP_SCRIPT"

# --- Table of Contents (Files Embedded in this Script) ---
# Use the markers "<<< BEGIN FILE: path/to/file >>>" to navigate.
EOF_TOC

# Generate the Table of Contents by iterating through the collected file info
# Use FILE_COUNT_GEN as primary check before accessing FILE_INFO_MAP keys
declare -a sorted_files=() # Initialize array

# Only attempt to build TOC if files were actually found
if [[ "$FILE_COUNT_GEN" -gt 0 ]]; then
    # Populate and sort the array of filenames (keys from the map)
    # Ensure keys with newlines are handled correctly by printf/sort/xargs
    if ! mapfile -t sorted_files < <(printf '%s\0' "${!FILE_INFO_MAP[@]}" | sort -z | xargs -0 -n1); then
         echo "[WARN] mapfile command failed during TOC generation. TOC may be incomplete." >&2
         sorted_files=() # Ensure it's empty on failure
    fi

    # Loop through sorted filenames IF mapfile succeeded and array is populated
    if [[ ${#sorted_files[@]} -gt 0 ]]; then
        for rel_file in "${sorted_files[@]}"; do
            # Ensure rel_file is not empty and the key exists in the original map
            if [[ -n "$rel_file" && -v FILE_INFO_MAP["$rel_file"] ]]; then
                info_str="${FILE_INFO_MAP[$rel_file]}" # Get metadata string
                size_display=""; perms_display=""; binary_display=""
                # Extract metadata values using parameter expansion
                size_display="${info_str##*size=}"; size_display="${size_display%% *}"
                perms_display="${info_str##*perms=}"; perms_display="${perms_display%% *}"
                binary_display="${info_str##*binary=}"; binary_display="${binary_display%% *}"
                # Append the TOC entry comment
                echo "# - ${rel_file} (Size: ${size_display:-N/A} bytes, Perms: ${perms_display:-N/A}, Binary: ${binary_display:-N/A})" >> "$TEMP_SCRIPT"
            else
                 # This case should ideally not happen if mapfile worked correctly and keys are valid
                 echo "# - [WARN] Invalid key found during TOC generation: '${rel_file}'" >> "$TEMP_SCRIPT"
            fi
        done
    else
         # Mapfile failed or produced empty array despite FILE_COUNT_GEN > 0
         echo "# [WARN] Failed to generate file list for TOC." >> "$TEMP_SCRIPT"
    fi
else
    # Add placeholder comment if no files were found/embedded
    echo "# (No files found or embedded)" >> "$TEMP_SCRIPT"
fi


# --- Write Generated Script Body ---
# Append the main runtime logic structure using another heredoc
# This includes usage instructions for the *generated* script, the workflow guide,
# runtime setup, option parsing, helper functions, and the definition
# of the `reconstruct_files` function which will contain the embedded data.
# Use single quotes for EOF marker to prevent expansions within this heredoc
cat <<'EOF_GENERATED_SCRIPT_BODY' >> "$TEMP_SCRIPT"

# --- Script Usage ---
# ./setup-REPO_NAME_PLACEHOLDER.sh [OPTIONS]
#
# Options:
#   (no args)         Reproduce the repository in TARGET_DIR (default: ./REPO_NAME_PLACEHOLDER).
#   --help            Show this help message.
#   --dump [pattern]  Print file markers and metadata. Optionally filter by POSIX ERE pattern in filepath.
#   --update          Allow overwriting/updating files in an existing TARGET_DIR.
#   --dry-run         Show files that would be created without actually writing them.
#   --verify          After creation (or if TARGET_DIR exists), verify contents against embedded hash.
#   --recalculate-hash Update the SOURCE_HASH in *this* script to match TARGET_DIR (prompts).
#   --retry-failed    Attempt to create files listed in FAILED_FILES array (if previous run failed).
#   --target-dir DIR  Specify a different target directory.
#   --diff ORIG_DIR [pattern] Compare embedded content against an existing directory ORIG_DIR.
#                     Pattern is currently informational only for the diff command itself.

# --- LLM Development Workflow Guide ---
# 0. Read the <<< RECOMMENDED LLM SYSTEM PROMPT >>> above and provide it to your LLM. This is critical.
# 1. Generate: Create this script from your source code (`repocapsule.sh ...`).
# 2. Edit: Give this script to the LLM with your specific task request (e.g., "Refactor the function X in file Y.py").
# 3. Review: Use `./setup-REPO_NAME_PLACEHOLDER.sh --diff /path/to/original/repo` to review the changes made by the LLM.
# 4. Apply: If changes look good, either manually merge them or use the modified script with `--update` on a clean checkout/target directory.
# 5. Verify Code: Test the functionality of the code in the target directory. Run linters, build steps, unit tests, etc.
# 6. Update Hash: If tests pass and changes are accepted, run `./setup-REPO_NAME_PLACEHOLDER.sh --recalculate-hash` against the verified target directory (confirm 'y'). This updates the SOURCE_HASH inside this script.
# 7. Commit: Commit the modified `setup-REPO_NAME_PLACEHOLDER.sh` script (with the updated hash) to your version control.

# --- Runtime Setup ---
set -e # Exit immediately if a command exits with a non-zero status.
# Use set -u after runtime variables are declared/initialized
# set -o pipefail # Ensure pipeline errors are caught (Consider implications carefully)
# Check Bash version at runtime as well
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then echo "[ERROR] Bash 4.0+ required." >&2; exit 1; fi

# --- Runtime Options ---
# Initialize variables for runtime options
DUMP_MODE=false; DUMP_PATTERN=""; UPDATE_MODE=false; DRY_RUN=false; VERIFY_MODE=false; RECALCULATE_HASH=false; RETRY_FAILED=false
DIFF_MODE=false; DIFF_ORIG_DIR=""; DIFF_ORIG_DIR_ABS="" ; DIFF_PATTERN=""
# Default target directory uses the placeholder name
TARGET_DIR="./REPO_NAME_PLACEHOLDER"
# Runtime verbose flag, not user-settable via documented option but useful for debugging
VERBOSE=false

# --- Runtime State ---
# Array to track files that failed during reconstruction
declare -a FAILED_FILES=()
# Counters for files processed during a run
FILE_COUNT_RUN=0; TOTAL_FILES_CREATED=0
# Variable to hold the absolute path of the target directory
TARGET_DIR_ABS=""
# Array to hold reconstructed find exclude arguments
declare -a FIND_EXCLUDE_ARGS_RUNTIME=()

# --- Activate stricter settings *after* variable initialization ---
set -u # Treat unset variables as error
set -o pipefail # Catch pipeline errors

# --- Define reconstruct_files (Contains embedded data) ---
# This function will contain all the file embedding blocks generated earlier.
reconstruct_files() {
# ==============================================================================
# <<< BEGIN FILE EMBEDDING DATA >>>
# LLM: Do not edit structure outside text blocks between here and END FILE EMBEDDING DATA
# ==============================================================================
EOF_GENERATED_SCRIPT_BODY
# Note: The actual file embedding blocks will be inserted here.

# --- Embed Files ---
echo "[INFO] Generating file embedding blocks..." >&2
# Check if there are files to embed
if [[ ${#sorted_files[@]} -gt 0 ]]; then
    # Loop through the sorted list of files found earlier
    for rel_file in "${sorted_files[@]}"; do
         # Check if key exists before proceeding
        if [[ -v FILE_INFO_MAP["$rel_file"] ]]; then
            abs_file="$SOURCE_DIR/$rel_file" # Construct absolute path
            info_str="${FILE_INFO_MAP[$rel_file]}" # Get metadata string
            # Extract metadata values
            size_val="${info_str##*size=}"; size_val="${size_val%% *}"
            perms_val="${info_str##*perms=}"; perms_val="${perms_val%% *}"
            is_binary_flag_val="${info_str##*binary=}"; is_binary_flag_val="${is_binary_flag_val%% *}"

            # Check if extracted values are valid before embedding
            if [[ -z "$size_val" || -z "$perms_val" || -z "$is_binary_flag_val" ]]; then
                 echo "[WARN] Incomplete metadata extracted for '$rel_file'. Skipping embedding." >&2
                 continue
            fi
             # Check if source file still exists before trying to embed
            if [[ ! -f "$abs_file" ]]; then
                echo "[WARN] Source file '$abs_file' disappeared before embedding. Skipping." >&2
                continue
            fi
            # Call the embedding function to append the block to TEMP_SCRIPT
            create_file_embedding "$abs_file" "$rel_file" "$size_val" "$perms_val" "$is_binary_flag_val"
        else
            echo "[WARN] Metadata key '$rel_file' not found during embedding loop. Skipping." >&2
        fi
    done
else
    # Log if no files are being embedded
    echo "[INFO] No files found matching criteria to embed." >&2
fi
# If no files were embedded, the reconstruct_files function body would be empty,
# causing a syntax error. Add a null command ':' to prevent this.
if [[ $FILE_COUNT_GEN -eq 0 ]]; then
    echo ":" >> "$TEMP_SCRIPT"
    [[ "$VERBOSE" = true ]] && echo "[DEBUG] Added null command to empty reconstruct_files function body." >&2
fi

# --- Add closing brace for reconstruct_files and the rest of the runtime logic ---
# Append the closing brace for the function and the remaining runtime code.
# Use single quotes for EOF marker to prevent expansions within this heredoc
cat <<'EOF_GENERATED_SCRIPT_REST' >> "$TEMP_SCRIPT"
# ==============================================================================
# <<< END FILE EMBEDDING DATA >>>
# ==============================================================================
} # End of the reconstruct_files function definition

# --- Helper Functions (Runtime) ---
# Define helper functions needed by the generated script at runtime.

# Runtime version of get_absolute_path (slightly simplified)
# Duplicated from generator for self-containment. Checks required commands at runtime.
get_absolute_path() {
    local target_path="$1"; local abs_path=""; local original_dir;
    original_dir=$(pwd);
    # Runtime dependency check for this function
    for cmd_rt_func in pwd dirname basename cd; do if ! command -v "$cmd_rt_func" > /dev/null 2>&1; then echo "[ERROR] Runtime helper get_absolute_path needs '$cmd_rt_func'." >&2; return 1; fi; done;

    if [[ -d "$target_path" ]]; then
        # Handle potential permission error on cd
        if ! cd "$target_path" 2>/dev/null; then echo "[ERROR] cd to existing directory '$target_path' failed (permissions?)." >&2; cd "$original_dir" &>/dev/null; return 1; fi;
        abs_path=$(pwd -P); cd "$original_dir" &>/dev/null || true;
    elif [[ -e "$target_path" ]]; then
        echo "[ERROR] Path '$target_path' exists but is not a directory." >&2; return 1;
    else # Path does not exist
        local parent_dir; parent_dir=$(dirname "$target_path") || { echo "[ERROR] dirname failed for '$target_path'." >&2; return 1; }
        local base_name; base_name=$(basename "$target_path") || { echo "[ERROR] basename failed for '$target_path'." >&2; return 1; }
        # If parent is '.', resolve based on current directory
        if [[ "$parent_dir" == "." ]]; then
             parent_dir=$(pwd -P) || { echo "[ERROR] pwd failed for '.' parent." >&2; return 1; }
        # Check if parent directory exists
        elif [[ ! -d "$parent_dir" ]]; then
             echo "[ERROR] Parent directory '$parent_dir' for non-existent path '$target_path' does not exist." >&2; return 1;
        fi
        # Try changing to the parent directory
        if ! cd "$parent_dir" 2>/dev/null; then echo "[ERROR] cd to parent '$parent_dir' failed (permissions?)." >&2; cd "$original_dir" &>/dev/null; return 1; fi;
        local parent_abs_path; parent_abs_path=$(pwd -P); cd "$original_dir" &>/dev/null || true;
        # Construct the absolute path for the non-existent target
        # Handle base_name being '.' or '/' appropriately (though likely edge cases)
        if [[ "$base_name" == "." ]]; then
            abs_path="$parent_abs_path"
        elif [[ "$parent_abs_path" == "/" ]]; then
             abs_path="/$base_name" # Avoid //
        else
             abs_path="$parent_abs_path/$base_name"
        fi
    fi;
    if [[ -z "$abs_path" || "$abs_path" != /* ]]; then echo "[ERROR] Failed to determine a valid absolute path for '$target_path'. Result: '$abs_path'" >&2; return 1; fi;
    echo "$abs_path"; return 0;
}

# Runtime usage function: Extracts usage comments from the script itself
usage_runtime() {
    # Use grep to find comment lines starting with '# ' within specific sections
    # Uses awk for more precise section extraction based on header lines
    awk '
        BEGIN { in_section=0; }
        /^# =+/{next} # Skip separator lines
        /^# <<< RECOMMENDED LLM SYSTEM PROMPT >>>/ { in_section=1; print ""; print $0; next; }
        /^# <<< END RECOMMENDED LLM SYSTEM PROMPT >>>/ { in_section=0; print $0; print ""; next; }
        /^# --- Script Usage ---/ { in_section=1; print $0; next; }
        /^# Options:/ { if(in_section) print $0; next; }
        /^#   --/ { if(in_section) print $0; next; } # Print option lines
        /^# --- LLM Development Workflow Guide ---/ { in_section=1; print ""; print $0; next; }
        # Stop printing regular comments if we hit another major section header
        /^# --- Runtime Setup ---/ { in_section=0; next; }
        # Print lines within active sections, removing the leading '# '
        { if(in_section && /^# /) { sub(/^# /, ""); print; } }
    ' "$0"
    exit 0
}

# Function to parse the stored FIND_EXCLUDE_ARGS_ORIGINAL_STR into the FIND_EXCLUDE_ARGS_RUNTIME array
parse_exclude_args_string() {
    # Check if string is empty or just whitespace
    if [[ -z "${FIND_EXCLUDE_ARGS_ORIGINAL_STR// /}" ]]; then
        FIND_EXCLUDE_ARGS_RUNTIME=()
        [[ "$VERBOSE" = true ]] && echo "[DEBUG] No exclusion arguments stored." >&2
        return 0
    fi

    # Use eval carefully to reconstruct the array from the string.
    # This assumes the string was correctly constructed during generation
    # (i.e., arguments properly quoted if they contained spaces, although
    # current generator logic avoids spaces in patterns themselves).
    # We add validation checks after eval.
    local eval_str="FIND_EXCLUDE_ARGS_RUNTIME=( ${FIND_EXCLUDE_ARGS_ORIGINAL_STR} )"
    [[ "$VERBOSE" = true ]] && echo "[DEBUG] Evaluating exclude args string: $eval_str" >&2
    if ! eval "$eval_str"; then
        echo "[ERROR] Failed to evaluate stored exclusion arguments string." >&2
        echo "[DEBUG] String was: $FIND_EXCLUDE_ARGS_ORIGINAL_STR" >&2
        return 1
    fi

    # Basic validation: Check if array is non-empty and first element looks reasonable
    if [[ ${#FIND_EXCLUDE_ARGS_RUNTIME[@]} -eq 0 ]]; then
         echo "[ERROR] Evaluation of exclusion args resulted in an empty array, but string was not empty." >&2
         echo "[DEBUG] String was: $FIND_EXCLUDE_ARGS_ORIGINAL_STR" >&2
         return 1
    fi
    # Further validation could check pairs (e.g., -path needs an argument) but might be overly complex.
    [[ "$VERBOSE" = true ]] && echo "[DEBUG] Parsed ${#FIND_EXCLUDE_ARGS_RUNTIME[@]} exclude arguments." >&2
    return 0
}


# Function to calculate the SHA256 hash of the directory contents
# Uses the same exclusion logic as the generation script for consistency.
calculate_dir_hash() {
    local dir="$1"
    local hash_cmd="shasum -a 256" # Command for hashing

    # Runtime dependency check
    for cmd_rt_hash in shasum sed find sort xargs awk cd printf head wc; do
      if ! command -v "$cmd_rt_hash" >/dev/null 2>&1; then echo "[ERROR] Runtime calculate_dir_hash needs '$cmd_rt_hash'." >&2; return 1; fi
    done
    if [[ ! -d "$dir" ]]; then echo "[ERROR] Directory '$dir' not found for hashing." >&2; return 1; fi

    # Parse the stored exclusion args string into the runtime array if not already done
    if [[ ${#FIND_EXCLUDE_ARGS_RUNTIME[@]} -eq 0 ]]; then
        if ! parse_exclude_args_string; then
            return 1 # Error parsing args
        fi
    fi

    local computed_hash; local ec;
    local -a find_cmd_args=()       # Final find command array
    # Base find command, starts from '.' relative to the target directory ($dir)
    local find_base_cmd=(find . -mindepth 1) # Use mindepth 1 to avoid hashing '.' itself

    # Build the final find command array to run within $dir
    if [[ ${#FIND_EXCLUDE_ARGS_RUNTIME[@]} -gt 0 ]]; then
        # find . -mindepth 1 \( <exclusions> \) -prune -o -type f -print0
        # Note: Runtime array already contains the necessary parens, -o, -prune etc.
        find_cmd_args=("${find_base_cmd[@]}" "${FIND_EXCLUDE_ARGS_RUNTIME[@]}" -o -type f -print0)
    else
        # find . -mindepth 1 -type f -print0
        find_cmd_args=("${find_base_cmd[@]}" -type f -print0)
    fi
    [[ "$VERBOSE" = true ]] && echo "[DEBUG] Executing find command for hash calc: ${find_cmd_args[*]} (in $dir)" >&2

    # Calculate hash:
    # Use a subshell to contain the 'cd' and the find/sort/xargs pipeline.
    # Set LC_ALL=C for predictable sorting and byte processing.
    # Rely on set -e and set -o pipefail to catch errors in the pipeline.
    # Pipe find output through sed to remove leading './' before sorting
    # Redirect find stderr to /dev/null to avoid printing permission errors for excluded/unreadable files
    computed_hash=$( (
        cd "$dir" || { echo "[ERROR] cd to '$dir' failed within hash subshell." >&2; exit 1; }
        # Ensure C locale for all parts of the pipeline for consistency
        # Remove leading "./" from find output before sorting
        # Use xargs -0 cat -- to handle filenames starting with '-' if any files exist
        LC_ALL=C "${find_cmd_args[@]}" 2>/dev/null | LC_ALL=C sed 's|^\./||' | LC_ALL=C sort -z | LC_ALL=C xargs -0 --no-run-if-empty cat -- | $hash_cmd | awk '{print $1}'
    ) )
    ec=$? # Capture the exit code of the subshell

    if [[ $ec -ne 0 ]]; then echo "[ERROR] Hash calculation subshell failed (Code: $ec)." >&2; return 1; fi

     # Handle case where hash is empty (could be empty directory or only excluded files)
     if [[ -z "$computed_hash" ]]; then
         local check_count; local find_check_cmd_args=()
         # Rerun find without -print0, just to check if *any* files should have been found
         if [[ ${#FIND_EXCLUDE_ARGS_RUNTIME[@]} -gt 0 ]]; then
             find_check_cmd_args=("${find_base_cmd[@]}" "${FIND_EXCLUDE_ARGS_RUNTIME[@]}" -o -type f -print)
         else
             find_check_cmd_args=("${find_base_cmd[@]}" -type f -print)
         fi
         # Use subshell and check exit code for find command
         # Limit output check to first line with head -n 1
         # Redirect find stderr to /dev/null
         check_count=$( (cd "$dir" && LC_ALL=C "${find_check_cmd_args[@]}" 2>/dev/null) | head -n 1 | wc -l )
         local check_ec=$?
         # check_ec being non-zero might just mean find had permission errors, not necessarily fatal
         if [[ $check_ec -ne 0 && $check_count -gt 0 ]]; then echo "[WARN] Find check for empty hash reported non-zero exit code $check_ec but found files." >&2; fi

         # If find returns no files (or first check failed entirely), calculate hash of empty string
         if [[ "$check_count" -eq 0 ]]; then
             [[ "$VERBOSE" = true ]] && echo "[DEBUG] No files found for hashing, calculating hash of empty string." >&2
             computed_hash=$(printf "" | $hash_cmd | awk '{print $1}')
             # Check if even hashing empty string failed
             [[ -z "$computed_hash" ]] && { echo "[ERROR] Failed to calculate hash for empty content." >&2; return 1; }
         # If find should have returned files but hash is empty, it's an error
         else
             echo "[ERROR] Hash calculation resulted in empty string, but 'find' check indicates files should be present." >&2
             # Optionally show some output from find check for debugging
             # local check_output; check_output=$( (cd "$dir" && LC_ALL=C "${find_check_cmd_args[@]}" 2>/dev/null) )
             # echo "[DEBUG] Find check output head: $(echo "$check_output" | head -n 5)" >&2
             return 1
         fi
     fi
    echo "$computed_hash"; return 0
}


# Function to verify the directory hash against the embedded SOURCE_HASH
verify_hash() {
    local dir="$1"
    echo "[INFO] Verifying hash of '$dir'..."
    local computed_hash;
    # Calculate the hash of the target directory
    if ! computed_hash=$(calculate_dir_hash "$dir"); then
         echo "[ERROR] Hash calculation failed during verification." >&2; exit 1; # Exit if calculation failed
    fi
    # Check if calculate_dir_hash returned empty string (shouldn't happen with checks inside it)
    if [[ -z "$computed_hash" ]]; then echo "[ERROR] Computed hash is empty during verification (unexpected)." >&2; exit 1; fi
    # Compare and report
    echo "[INFO] Embedded Hash: $SOURCE_HASH"
    echo "[INFO] Computed Hash: $computed_hash"
    if [[ "$computed_hash" == "$SOURCE_HASH" ]]; then
        echo "[SUCCESS] Verification OK. Hashes match."
        return 0 # Explicitly return success
    else
        echo "[FAILURE] Verification FAILED. Hashes MISMATCH." >&2
        exit 1 # Exit with error on mismatch
    fi
}

# Function to recalculate the hash and update the script itself
recalculate_and_update_hash() {
    local dir="$1"
    # Runtime dependency check
    for cmd_rt_recalc in calculate_dir_hash read cp sed mv rm date; do
       if ! command -v "$cmd_rt_recalc" >/dev/null 2>&1 && ! type "$cmd_rt_recalc" &>/dev/null; then echo "[ERROR] Runtime recalculate_hash needs '$cmd_rt_recalc'." >&2; return 1; fi
    done

    echo "[INFO] Recalculating hash for '$dir' to update script..."
    local new_hash;
    # Calculate the new hash
    if ! new_hash=$(calculate_dir_hash "$dir"); then
         exit 1 # Exit if calculation failed
    fi
    if [[ -z "$new_hash" ]]; then echo "[ERROR] Computed hash is empty, cannot update." >&2; exit 1; fi
    # Report current and new hash
    echo "[INFO] Current Embedded Hash: $SOURCE_HASH"
    echo "[INFO] New Computed Hash:     $new_hash"
    # Check if update is needed
    if [[ "$new_hash" == "$SOURCE_HASH" ]]; then
        echo "[INFO] Hashes already match. No update needed."
        return 0
    fi
    # Prompt user for confirmation
    local REPLY
    read -p "Update SOURCE_HASH in '$0' from '$SOURCE_HASH' to '$new_hash'? (y/N) " -n 1 -r REPLY; echo
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "[INFO] Update cancelled by user."
        return 1 # Return non-zero to indicate cancellation
    fi

    # Separate declaration and assignment for backup filename (SC2155 fix)
    local bak
    bak="$0.bak.$(date +%Y%m%d_%H%M%S)"

    cp "$0" "$bak" || { echo "[ERROR] Failed to create backup '$bak'." >&2; exit 1; }
    echo "[INFO] Created backup: $bak"
    # Use sed to replace the SOURCE_HASH line in-place.
    # Using -i.bak.sedtmp for cross-platform compatibility (BSD sed requires extension)
    # Ensure the line starts exactly with SOURCE_HASH= to avoid matching comments
    # Use LC_ALL=C for sed consistency
    export LC_ALL=C
    if ! sed -i.bak.sedtmp "s|^SOURCE_HASH=.*$|SOURCE_HASH=\"$new_hash\"|" "$0"; then
        # Handle sed failure: restore backup and exit
        echo "[ERROR] sed command failed to update hash. Restoring from backup." >&2
        mv "$bak" "$0" # Attempt to restore original
        rm -f "$0.bak.sedtmp" # Clean up temporary file from sed if it exists
        unset LC_ALL
        exit 1
    fi
    unset LC_ALL
    # Remove the temporary backup file created by sed -i
    rm -f "$0.bak.sedtmp"
    # Update the in-memory variable as well for consistency if script continues
    SOURCE_HASH="$new_hash"
    echo "[SUCCESS] SOURCE_HASH updated in '$0'."
    return 0 # Explicitly return success
}

# Function to handle --dump mode: Print file markers and metadata
dump_mode() {
    echo "[INFO] Dumping file structure info (Filter: '${DUMP_PATTERN:-none}')..."
    # Runtime dependency check
    if ! command -v awk >/dev/null 2>&1; then echo "[ERROR] Runtime dump_mode needs 'awk'." >&2; return 1; fi
    # Use awk to parse the script content:
    # - Look for BEGIN FILE marker, set flags, print if matches pattern
    # - If in a matching block, print Metadata and Content lines
    # - Look for END FILE marker, print if in matching block, reset flags
    # Use ERE for pattern matching if pattern is provided
    awk -v pattern="$DUMP_PATTERN" '
        BEGIN { in_block=0; match_block=0; }
        /^# <<< BEGIN FILE:/ {
            in_block=1
            current_file=$4
            # Remove trailing >>> and potential leading/trailing whitespace
            gsub(/^ *| *>>>$/, "", current_file)
            if (pattern == "" || current_file ~ pattern) {
                match_block=1
                print $0 # Print BEGIN line
            } else {
                match_block=0
            }
            next # Move to next line
        }
        # Print metadata/content lines only if the block matched the pattern
        in_block && match_block && /^# Metadata:/ { print $0; next }
        in_block && match_block && /^# Content:/ { print $0; next }
        /^# <<< END FILE:/ {
            if (in_block && match_block) {
                print $0 # Print END line
                print "" # Add blank line separator
            }
            in_block=0
            match_block=0
            next # Move to next line
        }
    ' "$0" # Process the script file itself
    exit 0 # Exit after dumping
}

# Function to handle --diff mode: Compare embedded content against an existing directory
diff_mode() {
    echo "[INFO] Diff mode: Comparing embedded content against '$DIFF_ORIG_DIR_ABS'"
    # Informational message about pattern (not currently used to filter diff)
    [[ -n "$DIFF_PATTERN" ]] && echo "[INFO] Applying pattern (currently informational only): '$DIFF_PATTERN'"
    # Check if the directory to compare against exists
    if [[ ! -d "$DIFF_ORIG_DIR_ABS" ]]; then echo "[ERROR] Original directory '$DIFF_ORIG_DIR' (resolved to '$DIFF_ORIG_DIR_ABS') not found for diff." >&2; exit 1; fi
    # Runtime dependency check
    for cmd_rt_diff in diff mktemp rm trap mkdir chmod cat base64 dirname; do
        if ! command -v "$cmd_rt_diff" >/dev/null 2>&1; then echo "[ERROR] Runtime diff_mode needs '$cmd_rt_diff'." >&2; return 1; fi
    done

    # Create a temporary directory to extract embedded files into
    local TEMP_DIFF_DIR
    # Ensure TMPDIR is respected if set, otherwise use /tmp
    TEMP_DIFF_DIR=$(mktemp -d "${TMPDIR:-/tmp}/repocapsule_diff.XXXXXX")
    if [[ -z "$TEMP_DIFF_DIR" || ! -d "$TEMP_DIFF_DIR" ]]; then echo "[ERROR] Failed to create temporary diff directory." >&2; exit 1; fi

    # Setup trap to clean up the temporary directory on exit/interrupt/error
    # Use a more robust trap that passes the exit signal
    # shellcheck disable=SC2154 # signal is assigned in the trap handler
    trap 'signal=$?; echo "[INFO] Cleaning up temporary diff directory: $TEMP_DIFF_DIR" >&2; rm -rf "$TEMP_DIFF_DIR"; exit $signal' INT TERM EXIT ERR

    echo "[INFO] Extracting embedded files to temporary directory: $TEMP_DIFF_DIR"
    # Temporarily override TARGET_DIR_ABS to the temp diff directory
    TARGET_DIR_ABS="$TEMP_DIFF_DIR"
    FAILED_FILES=() # Reset failed files array for extraction
    # Call reconstruct_files to extract content into the temp dir
    # Use subshell to prevent reconstruct_files failures from exiting the main script via set -e
    ( reconstruct_files )
    local extraction_ec=$?
    # Warn if extraction failed for some files (FAILED_FILES array should be populated)
    if [[ ${#FAILED_FILES[@]} -gt 0 ]] || [[ $extraction_ec -ne 0 ]]; then
        echo "[WARN] ${#FAILED_FILES[@]} file(s) failed extraction during diff prep (Exit Code: $extraction_ec). Diff may be incomplete." >&2;
        printf "  [FAILED] %s\n" "${FAILED_FILES[@]}" >&2
        # Decide whether to continue or exit based on severity? For now, continue but warn.
    fi
    # Run diff command: -u (unified format), -r (recursive), -N (treat absent files as empty)
    # Add --color=auto if available for better readability
    local diff_cmd="diff -urN"
    if diff --color=auto --help >/dev/null 2>&1; then diff_cmd="diff -urN --color=auto"; fi

    echo "[INFO] Running diff command: $diff_cmd '$DIFF_ORIG_DIR_ABS' '$TARGET_DIR_ABS'"
    echo "--- Diff Start ---"
    local diff_ec=0
    # Execute diff command, capture exit code manually as set -e might exit early
    $diff_cmd "$DIFF_ORIG_DIR_ABS" "$TARGET_DIR_ABS" || diff_ec=$?

    if [[ $diff_ec -eq 0 ]]; then
        # Exit code 0 means no differences found
        echo "--- Diff End (No differences found) ---"
    elif [[ $diff_ec -eq 1 ]]; then
        # Exit code 1 means differences were found (normal for diff)
        echo "--- Diff End (Differences found) ---"
    else
        # Other non-zero exit codes indicate an error
        echo "[ERROR] Diff command failed with exit code $diff_ec." >&2
        # Trap will handle cleanup, exit with the diff error code
        exit $diff_ec
    fi
    # Exit successfully after diff (trap handles cleanup)
    # Need to manually exit here as trap EXIT would run otherwise
    exit 0
}

# --- Parse Runtime Arguments ---
# Process arguments passed to the generated script itself
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage_runtime ;; # Display runtime help
        --dump) # Handle --dump mode
            DUMP_MODE=true
            # Check if next argument is a pattern (doesn't start with '-')
            if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                DUMP_PATTERN="$2"; shift 2; # Assign pattern, shift 2 args
            else
                shift; # No pattern, shift 1 arg
            fi
            ;;
        --update) UPDATE_MODE=true; shift ;; # Enable update mode
        --dry-run) DRY_RUN=true; shift ;;    # Enable dry run mode
        --verify) VERIFY_MODE=true; shift ;; # Enable verification mode
        --recalculate-hash) RECALCULATE_HASH=true; shift ;; # Enable hash recalculation
        --retry-failed) RETRY_FAILED=true; shift ;; # Enable retry failed mode
        --target-dir) # Specify target directory
            if [[ -n "${2:-}" ]]; then
                TARGET_DIR="$2"; shift 2; # Assign directory, shift 2 args
            else
                echo "[ERROR] --target-dir requires a directory argument." >&2; exit 1;
            fi
            ;;
        --diff) # Handle diff mode
             if [[ -z "${2:-}" ]]; then echo "[ERROR] --diff requires an original directory argument." >&2; exit 1; fi
             DIFF_MODE=true
             DIFF_ORIG_DIR="$2" # Assign original directory path
             # Check for optional pattern argument
             if [[ -n "${3:-}" && "${3:0:1}" != "-" ]]; then
                 DIFF_PATTERN="$3"; shift 3; # Assign pattern, shift 3 args
             else
                 shift 2; # No pattern, shift 2 args
             fi
             ;;
         # Allow --verbose for runtime debugging, although not documented
         --verbose) VERBOSE=true; shift ;;
        *) echo "[ERROR] Unknown runtime option: $1" >&2; usage_runtime ;; # Handle unknown options
    esac;
done

# --- Resolve Target Directory ---
# Get the absolute path for the target directory (runtime)
TARGET_DIR_ABS=$(get_absolute_path "$TARGET_DIR") || exit 1
# Check if target path exists as a file (and not in diff mode where it's okay temporarily)
if [[ -e "$TARGET_DIR_ABS" && ! -d "$TARGET_DIR_ABS" && "$DIFF_MODE" != true ]]; then echo "[ERROR] Target path '$TARGET_DIR_ABS' exists but is not a directory." >&2; exit 1; fi
echo "[INFO] Target Directory: $TARGET_DIR_ABS"

# --- Mode Handling (Exclusive Modes or Early Exits) ---
# Handle modes that exit early or are mutually exclusive with reconstruction

# Execute dump mode if requested
if [ "$DUMP_MODE" = true ]; then dump_mode; fi # Exits within function
# Execute diff mode if requested (resolves original dir path first)
if [ "$DIFF_MODE" = true ]; then
    DIFF_ORIG_DIR_ABS=$(get_absolute_path "$DIFF_ORIG_DIR") || exit 1;
    diff_mode; # Exits within function
fi
# Execute dry run mode if requested
if [ "$DRY_RUN" = true ]; then
    echo "[INFO] Dry run: Simulating file creation in '$TARGET_DIR_ABS'..."
    # Use awk for potentially more robust parsing than grep/sed
    # Look for BEGIN lines, extract path between marker and ' >>>'
    awk '
        /^# <<< BEGIN FILE:/ {
            file_path=$4
            sub(/ >>>$/, "", file_path) # Remove trailing marker
            # Ensure TARGET_DIR_ABS ends with / if not root, for clean joining
            target_base = ENVIRON["TARGET_DIR_ABS"]
            if (target_base != "/" && substr(target_base, length(target_base), 1) != "/") {
                target_base = target_base "/"
            } else if (target_base == "/") {
                 target_base = "/"
            }
            print "[DRY RUN] Would process: " target_base file_path
        }
    ' "$0"
    echo "[INFO] Dry run complete. Total files expected: $TOTAL_FILES_EXPECTED"
    exit 0 # Exit after dry run
fi

# Parse stored exclude args early if needed by verify/recalculate
if [[ "$VERIFY_MODE" = true || "$RECALCULATE_HASH" = true ]]; then
    if ! parse_exclude_args_string; then
        echo "[ERROR] Failed to parse exclusion args needed for verify/recalculate." >&2
        exit 1
    fi
fi

# Handle verify mode if target directory doesn't exist yet (will run after creation)
if [ "$VERIFY_MODE" = true ] && [ ! -d "$TARGET_DIR_ABS" ]; then echo "[INFO] Verification requested, but target directory '$TARGET_DIR_ABS' does not exist yet. Will verify after creation.";
# Handle verify mode if target directory exists (verify immediately and exit)
elif [ "$VERIFY_MODE" = true ] && [ -d "$TARGET_DIR_ABS" ]; then
    echo "[INFO] Verification requested: Checking existing directory '$TARGET_DIR_ABS'.";
    verify_hash "$TARGET_DIR_ABS"; # verify_hash exits on failure, returns 0 on success
    exit $?; # Exit with verify_hash status
fi
# Handle recalculate hash mode (requires target directory to exist)
if [ "$RECALCULATE_HASH" = true ]; then
    if [[ ! -d "$TARGET_DIR_ABS" ]]; then echo "[ERROR] Cannot recalculate hash: Target directory '$TARGET_DIR_ABS' does not exist." >&2; exit 1; fi
    recalculate_and_update_hash "$TARGET_DIR_ABS"; # Exits within function on error/success/cancel
    exit $?; # Exit with update function status
fi

# --- Pre-Run Checks (Actual Execution) ---
# Checks before starting the main file reconstruction

# Final check: Target path exists but is not a directory (should have been caught earlier, but safety)
if [ -e "$TARGET_DIR_ABS" ] && [ ! -d "$TARGET_DIR_ABS" ]; then echo "[ERROR] Target path '$TARGET_DIR_ABS' exists but is not a directory." >&2; exit 1; fi
# Check if target directory exists without --update or --retry-failed flags
if [ -d "$TARGET_DIR_ABS" ] && [ "$UPDATE_MODE" != true ] && [ "$RETRY_FAILED" != true ]; then echo "[ERROR] Target directory '$TARGET_DIR_ABS' already exists. Use --update to overwrite or --retry-failed to attempt failed files." >&2; exit 1;
# Warn if update mode is enabled and directory exists
elif [ -d "$TARGET_DIR_ABS" ] && [ "$UPDATE_MODE" = true ]; then echo "[WARN] Update mode enabled: Files in '$TARGET_DIR_ABS' may be overwritten.";
# Create target directory if it doesn't exist
elif [ ! -d "$TARGET_DIR_ABS" ]; then
    echo "[INFO] Creating target directory: $TARGET_DIR_ABS";
    # Use mkdir -p which succeeds if directory already exists (handles race conditions)
    mkdir -p "$TARGET_DIR_ABS" || { echo "[ERROR] Failed to create target directory '$TARGET_DIR_ABS'." >&2; exit 1; };
fi
# Check if --retry-failed is used but target directory doesn't exist
if [ "$RETRY_FAILED" = true ] && [ ! -d "$TARGET_DIR_ABS" ]; then echo "[ERROR] Cannot use --retry-failed: Target directory '$TARGET_DIR_ABS' does not exist." >&2; exit 1; fi

# --- Main Execution Logic ---
echo "[INFO] Starting file reconstruction in '$TARGET_DIR_ABS' (Expected files: $TOTAL_FILES_EXPECTED)..."
# Set trap for normal exit/interrupt during reconstruction (diff mode sets its own trap)
# Trap on ERR as well to report failures gracefully
# shellcheck disable=SC2154 # exit_code is assigned in the trap handler
trap 'exit_code=$?; echo "[INFO] Script finished with exit code $exit_code." >&2; exit $exit_code' INT TERM EXIT ERR

# Store the initial list of failed files if in retry mode, then clear the main array
declare -a ORIGINAL_FAILED_FILES=()
if [[ "$RETRY_FAILED" == true ]]; then
    # Copy current FAILED_FILES (populated by test harness sed command)
    ORIGINAL_FAILED_FILES=("${FAILED_FILES[@]}")
    # Clear FAILED_FILES before the run, so only *new* errors get added
    FAILED_FILES=()
    echo "[INFO] Retry Mode: Attempting to recreate ${#ORIGINAL_FAILED_FILES[@]} previously failed file(s)."
fi

# Call the main function to reconstruct files
reconstruct_files

# --- Post-Execution / Final Summary ---
# This section runs after reconstruct_files completes (or is interrupted by ERR trap)

# Determine final exit code based on success/failure
FINAL_EXIT_CODE=0

# Different logic for retry mode vs normal run
if [[ "$RETRY_FAILED" == true ]]; then
    echo "[INFO] Checking status after --retry-failed run..."
    declare -a STILL_FAILED_FILES=()
    # Remove 'local' keyword here (SC2168 fix)
    _original_failed_path=""
    for _original_failed_path in "${ORIGINAL_FAILED_FILES[@]}"; do
        if [[ ! -f "$_original_failed_path" ]]; then
            # File still doesn't exist after retry attempt
            STILL_FAILED_FILES+=("$_original_failed_path")
            echo "[FAIL] Retry failed: $_original_failed_path" >&2
        else
            echo "[ OK ] Retry successful: $_original_failed_path"
        fi
    done

    if [[ ${#STILL_FAILED_FILES[@]} -gt 0 ]]; then
        echo "[ERROR] ${#STILL_FAILED_FILES[@]} file(s) still failed after retry." >&2
        echo "[ERROR] Failed file paths:" >&2
        printf "  %s\n" "${STILL_FAILED_FILES[@]}" >&2
        FINAL_EXIT_CODE=1
    else
        echo "[SUCCESS] All previously failed files were created successfully on retry."
    fi
    # Also report any *new* failures that might have occurred during the retry run
    if [[ ${#FAILED_FILES[@]} -gt 0 ]]; then
         echo "[WARN] Additionally, ${#FAILED_FILES[@]} *new* error(s) occurred during the retry run:" >&2
         printf "  [NEW FAIL] %s\n" "${FAILED_FILES[@]}" >&2
         FINAL_EXIT_CODE=1 # Ensure failure if new errors occurred
    fi
else
    # Normal run (not retry): Check FAILED_FILES populated during this run
    if [ ${#FAILED_FILES[@]} -gt 0 ]; then
        echo "[ERROR] ${#FAILED_FILES[@]} file(s) failed to process during this run." >&2
        echo "[ERROR] Failed file paths:" >&2
        printf "  %s\n" "${FAILED_FILES[@]}" >&2 # Print list of failed files
        echo "[INFO] Total files successfully created in this run: $TOTAL_FILES_CREATED" >&2
        FINAL_EXIT_CODE=1 # Set error exit code
    # Check if fewer files were created than expected (and not in update mode where partial success is possible)
    # Only warn if not in update/retry mode, as partial runs are expected there.
    elif [ "$TOTAL_FILES_CREATED" -lt "$TOTAL_FILES_EXPECTED" ] && [ "$UPDATE_MODE" != true ]; then
        echo "[WARN] Expected $TOTAL_FILES_EXPECTED files, but only $TOTAL_FILES_CREATED were processed successfully in this run." >&2
        # This could indicate missing file blocks in the script or an early exit
        # Keep exit code 0 unless verify fails, but the warning is important.
    # Success case (or partial success in update mode)
    else
        # Remove 'local' from mode_info declaration (SC2168 fix)
        mode_info=""
        if [[ "$UPDATE_MODE" = true ]]; then mode_info=" (update mode)"; fi
        echo "[SUCCESS] Processed $TOTAL_FILES_CREATED / $TOTAL_FILES_EXPECTED files in '$TARGET_DIR_ABS'${mode_info}."

        # Run verification if requested (and not already run earlier)
        if [ "$VERIFY_MODE" = true ]; then
             # Parse exclude args if not already done (e.g., verify after initial run)
             if [[ ${#FIND_EXCLUDE_ARGS_RUNTIME[@]} -eq 0 ]]; then
                 if ! parse_exclude_args_string; then
                     echo "[ERROR] Failed to parse exclusion args needed for final verification." >&2
                     FINAL_EXIT_CODE=1
                 fi
             fi
             # Only run verify if exclude args were parsed successfully
             if [[ $FINAL_EXIT_CODE -eq 0 ]]; then
                  # verify_hash exits on failure (code 1), returns 0 on success.
                  # Capture return status to set FINAL_EXIT_CODE.
                  verify_hash "$TARGET_DIR_ABS" || FINAL_EXIT_CODE=$?
             fi
        fi
    fi
fi

# Explicitly disable the ERR trap before exiting normally to avoid double messages
trap - ERR
# Exit with the determined final exit code
exit $FINAL_EXIT_CODE

EOF_GENERATED_SCRIPT_REST

# --- Calculate Source Hash ---
# Calculate the hash of the *original* source directory content *after* generating
# the embedding blocks, using the *same* find/exclude logic.
echo "[INFO] Calculating final source hash for verification..." >&2
SOURCE_HASH=""          # Initialize hash variable
SOURCE_HASH_TEMP=""     # Temporary variable for hash calculation
ec=0                    # Exit code variable

# Use the FIND_EXCLUDE_ARGS_STRINGS array which contains the relative paths needed for hashing
# Remove 'local' keyword as this section is in global scope (SC2168 fix)
declare -a current_exclude_args_gen=() # Array for reconstructed find arguments for hashing
find_base_cmd_gen=(find . -mindepth 1) # Use relative path, mindepth 1

if [[ ${#FIND_EXCLUDE_ARGS_STRINGS[@]} -gt 0 && "${FIND_EXCLUDE_ARGS_STRINGS[0]}" != "" ]]; then
    # Build find arguments using the stored strings array
    # This mirrors the logic in the runtime calculate_dir_hash's parse_exclude_args_string/build section
    current_exclude_args_gen+=(\()
    # Remove 'local' keyword (SC2168 fix)
    i_gen=0; needs_or_gen=false
    while [[ $i_gen -lt ${#FIND_EXCLUDE_ARGS_STRINGS[@]} ]]; do
        # Remove 'local' keyword (SC2168 fix)
        arg_gen="${FIND_EXCLUDE_ARGS_STRINGS[$i_gen]}"
        if $needs_or_gen && [[ "$arg_gen" != ")" ]]; then current_exclude_args_gen+=("-o"); fi; needs_or_gen=true

        case "$arg_gen" in
            -path)
                # Path argument is next element
                # Remove 'local' keyword (SC2168 fix)
                path_arg="${FIND_EXCLUDE_ARGS_STRINGS[$((i_gen+1))]}"
                current_exclude_args_gen+=("-path" "$path_arg")
                # Check if -prune follows
                if [[ $((i_gen + 2)) -lt ${#FIND_EXCLUDE_ARGS_STRINGS[@]} && "${FIND_EXCLUDE_ARGS_STRINGS[$((i_gen + 2))]}" == "-prune" ]]; then
                    current_exclude_args_gen+=("-prune"); i_gen=$((i_gen + 2));
                else
                    i_gen=$((i_gen + 1));
                fi
                ;;
            -name)
                 # Name argument is next element
                current_exclude_args_gen+=("$arg_gen" "${FIND_EXCLUDE_ARGS_STRINGS[$((i_gen+1))]}"); i_gen=$((i_gen + 1))
                ;;
            "(" | ")") needs_or_gen=false ;; # Reset flag for parens
            "-o") needs_or_gen=false ;;      # Reset flag for explicit -o
            *) current_exclude_args_gen+=("$arg_gen") ;; # Should ideally only be -prune if not after -path
        esac

        # Check if next element is closing parenthesis
        if [[ $((i_gen + 1)) -lt ${#FIND_EXCLUDE_ARGS_STRINGS[@]} && "${FIND_EXCLUDE_ARGS_STRINGS[$((i_gen + 1))]}" == ")" ]]; then
             needs_or_gen=false;
        fi
        i_gen=$((i_gen + 1)) # Move to the next argument
    done;
    current_exclude_args_gen+=(\)) # End group
fi

# Build the final find command array for hashing
declare -a find_cmd_hash_array=()
if [[ ${#current_exclude_args_gen[@]} -gt 0 ]]; then
    # find . -mindepth 1 \( <exclusions> \) -prune -o -type f -print0
    find_cmd_hash_array=("${find_base_cmd_gen[@]}" "${current_exclude_args_gen[@]}" -o -type f -print0)
else
    # find . -mindepth 1 -type f -print0
    find_cmd_hash_array=("${find_base_cmd_gen[@]}" -type f -print0)
fi

# Build the find command array for the quick check (no -print0, just -print -quit)
declare -a find_cmd_check_array=()
if [[ ${#current_exclude_args_gen[@]} -gt 0 ]]; then
     find_cmd_check_array=("${find_base_cmd_gen[@]}" "${current_exclude_args_gen[@]}" -o -type f -print -quit)
else
     find_cmd_check_array=("${find_base_cmd_gen[@]}" -type f -print -quit)
fi


file_count=0;
# Run the quick check find command within the source directory using a subshell
# Redirect stderr to avoid permission errors cluttering output
check_output=$( ( cd "$SOURCE_DIR" && LC_ALL=C "${find_cmd_check_array[@]}" 2>/dev/null ) )
ec_check=$?

# Check if the find command itself failed (exit code > 0) AND produced no output
if [[ $ec_check -ne 0 && -z "$check_output" ]]; then
    echo "[WARN] Find check command failed (Code: $ec_check) and found no files in '$SOURCE_DIR'. Assuming empty/excluded." >&2
    file_count=0
# Check if the find output was empty (no matching files found)
elif [[ -z "$check_output" ]]; then
    file_count=0
else
    # At least one matching file was found
    file_count=1
fi


# Proceed with hash calculation
# Handle the case of zero matching files (hash of empty input)
if [[ "$file_count" -eq 0 ]]; then
    SOURCE_HASH_TEMP=$(printf "" | shasum -a 256 | awk '{print $1}')
    ec=$? # Capture exit code of empty hash calculation
    if [[ $ec -ne 0 ]]; then
        echo "[WARN] Could not determine hash for empty content (shasum error? Code: $ec)." >&2
        SOURCE_HASH="HASH_CALCULATION_EMPTY_FAILED"
    elif [[ -z "$SOURCE_HASH_TEMP" ]]; then
        echo "[WARN] Hash calculation for empty content resulted in empty string." >&2
        SOURCE_HASH="HASH_CALCULATION_EMPTY_EMPTY"
    else
        echo "[INFO] Source directory appears empty or contains only excluded files for hashing." >&2
        SOURCE_HASH="$SOURCE_HASH_TEMP"
    fi
# Handle the case with one or more matching files
else
    [[ "$VERBOSE" = true ]] && echo "[DEBUG] Executing find command for hash generation: ${find_cmd_hash_array[*]} (within $SOURCE_DIR)" >&2
    # Calculate hash using the pipeline: find | sed | sort | xargs cat | shasum
    # Ensure LC_ALL=C for consistent sorting and byte handling
    # Run the entire pipeline within the SOURCE_DIR using a subshell
    # Redirect find stderr to /dev/null
    SOURCE_HASH_TEMP=$( (
         cd "$SOURCE_DIR" || { echo "[ERROR] cd to '$SOURCE_DIR' failed for generator hash calculation." >&2; exit 1; }
         # Remove leading './' from find output before sorting
         LC_ALL=C "${find_cmd_hash_array[@]}" 2>/dev/null | LC_ALL=C sed 's|^\./||' | LC_ALL=C sort -z | LC_ALL=C xargs -0 --no-run-if-empty cat -- | LC_ALL=C shasum -a 256 | awk '{print $1}'
       )
    )
    ec=$? # Capture pipeline exit code (respects pipefail if set)
    if [[ $ec -ne 0 ]]; then
        echo "[ERROR] Source hash calculation pipeline failed (Code: $ec)." >&2
        SOURCE_HASH="HASH_CALCULATION_FAILED"
    elif [[ -z "$SOURCE_HASH_TEMP" ]]; then
        # This case should ideally not happen if file_count > 0, but handle defensively
        echo "[WARN] Hash calculation pipeline resulted in an empty string despite files found." >&2
        SOURCE_HASH="HASH_CALCULATION_EMPTY_PIPELINE"
    else
        SOURCE_HASH="$SOURCE_HASH_TEMP"
    fi
fi


# --- Finalize the Generated Script ---
echo "[INFO] Finalizing script (replacing placeholders)..." >&2
# Convert the array of find exclude argument strings into a single space-separated string
exclude_args_string="${FIND_EXCLUDE_ARGS_STRINGS[*]}"

# Use sed to replace placeholders in the temporary script.
# Set LC_ALL=C to ensure sed behaves predictably, especially with ranges/special chars.
# Use a different separator like '#' for sed if paths/values might contain '/'
# Escape '&', '\' and the separator character '#' in replacement strings.
escape_sed_rhs() {
    sed -e 's/[&\#]/\\&/g' -e 's/\\/\\\\/g' <<< "$1"
}
REPO_NAME_ESC=$(escape_sed_rhs "$REPO_NAME")
REPO_VERSION_ESC=$(escape_sed_rhs "$REPO_VERSION")
SOURCE_HASH_ESC=$(escape_sed_rhs "$SOURCE_HASH")
CREATED_DATE_ESC=$(escape_sed_rhs "$CREATED_DATE")
GIT_COMMIT_ESC=$(escape_sed_rhs "$GIT_COMMIT")
FIND_EXCLUDE_ARGS_STRINGS_ESC=$(escape_sed_rhs "$exclude_args_string")

export LC_ALL=C
# --- Robust sed -i detection ---
sed_test_file=$(mktemp "$TEMP_SCRIPT.sedtest.XXXXXX") || { echo "Error: Failed to create sed test file." >&2; unset LC_ALL; exit 1; }
echo "test" > "$sed_test_file"
sed_cmd_args=() # Initialize empty array for sed arguments

# Try GNU sed syntax (-i without suffix argument)
if sed -i 's/test/GNU/' "$sed_test_file" 2>/dev/null; then
    [[ "$VERBOSE" = true ]] && echo "[DEBUG] Detected GNU-like sed -i support." >&2
    sed_cmd_args=("-i")
# Try BSD sed syntax (-i with suffix argument)
elif sed -i '.bak' 's/test/BSD/' "$sed_test_file" 2>/dev/null; then
     [[ "$VERBOSE" = true ]] && echo "[DEBUG] Detected BSD-like sed -i support (requires suffix)." >&2
     sed_cmd_args=("-i" ".bak") # Pass -i and suffix as separate arguments
     rm -f "$sed_test_file.bak" # Clean up the backup created by BSD sed test
else
     echo "[ERROR] Cannot determine working sed -i syntax. Cannot perform in-place replacements." >&2
     rm -f "$sed_test_file" # Clean up test file
     unset LC_ALL
     exit 1
fi
rm -f "$sed_test_file" # Clean up test file
# --- End sed -i detection ---

# Apply replacements using '#' as separator
if ! sed "${sed_cmd_args[@]}" \
    -e "s#REPO_NAME_PLACEHOLDER#$REPO_NAME_ESC#g" \
    -e "s#REPO_VERSION_PLACEHOLDER#$REPO_VERSION_ESC#g" \
    -e "s#SOURCE_HASH_PLACEHOLDER#$SOURCE_HASH_ESC#g" \
    -e "s#FILE_COUNT_PLACEHOLDER#$FILE_COUNT_GEN#g" \
    -e "s#TOTAL_SIZE_PLACEHOLDER#$TOTAL_SIZE_GEN#g" \
    -e "s#CREATED_DATE_PLACEHOLDER#$CREATED_DATE_ESC#g" \
    -e "s#GIT_COMMIT_PLACEHOLDER#$GIT_COMMIT_ESC#g" \
    -e "s#FIND_EXCLUDE_ARGS_STRINGS_PLACEHOLDER#$FIND_EXCLUDE_ARGS_STRINGS_ESC#g" \
    "$TEMP_SCRIPT"; then
      echo "[ERROR] sed command failed during placeholder replacement." >&2
      # Rely on trap EXIT/ERR for $TEMP_SCRIPT cleanup
      unset LC_ALL; exit 1;
fi

# Clean up potential BSD backup if created by the main sed command
if [[ "${#sed_cmd_args[@]}" -eq 2 ]]; then
    rm -f "$TEMP_SCRIPT.bak"
fi
unset LC_ALL

# Move the finalized temporary script to the final output path
[[ "$VERBOSE" = true ]] && echo "[DEBUG] Moving temporary script to final destination: $OUTPUT_SCRIPT..." >&2
mv "$TEMP_SCRIPT" "$OUTPUT_SCRIPT" || { echo "[ERROR] Failed to move temporary script to '$OUTPUT_SCRIPT'." >&2; exit 1; }
# Make the generated script executable
chmod +x "$OUTPUT_SCRIPT" || { echo "[ERROR] Failed to set executable permissions on '$OUTPUT_SCRIPT'." >&2; exit 1; }

# --- Create Index File (Optional) ---
# If the --create-index flag was used
if [[ "$CREATE_INDEX" == true ]]; then
    echo "[INFO] Creating index file: $OUTPUT_INDEX_FILE" >&2
    # Use grep to find BEGIN FILE lines with line numbers (-n)
    # Use awk to parse the output:
    # - Set field separator to ':' for line number
    # - Use match() to extract filename robustly between marker and ' >>>'
    # - Print filename:linenumber
    # Redirect output to the index file
    # Ensure LC_ALL=C for grep/awk consistency
    if ! LC_ALL=C grep -n '^# <<< BEGIN FILE: ' "$OUTPUT_SCRIPT" | \
        LC_ALL=C awk -F':' 'match($0, /# <<< BEGIN FILE: (.*) >>>/) { print substr($0, RSTART + 18, RLENGTH - 22) ":" $1 }' > "$OUTPUT_INDEX_FILE"; then
        echo "[WARN] Failed to create index file '$OUTPUT_INDEX_FILE'. Check permissions or grep/awk execution." >&2;
        # Remove potentially incomplete index file
        rm -f "$OUTPUT_INDEX_FILE"
    fi
fi

# --- Completion Message ---
# Print a summary of the generation process to stderr
echo "-----------------------------------------------------" >&2
echo "RepoCapsule Generation Complete! (v1.0.0)" >&2 # <--- VERSION CHANGE HERE
echo "-----------------------------------------------------" >&2
echo "Generated Script: $OUTPUT_SCRIPT" >&2
# Display index file path if created successfully
[[ "$CREATE_INDEX" == true && -f "$OUTPUT_INDEX_FILE" ]] && echo "Generated Index:  $OUTPUT_INDEX_FILE" >&2
echo "Repository Name:  $REPO_NAME" >&2
echo "Version:          $REPO_VERSION" >&2
echo "Files Embedded:   $FILE_COUNT_GEN" >&2
echo "Total Size:       $TOTAL_SIZE_GEN bytes" >&2
echo "Source Hash:      $SOURCE_HASH" >&2
echo "-----------------------------------------------------" >&2
echo "Review the LLM System Prompt and Workflow Guide comments within the generated script." >&2
echo "To reproduce the directory structure, run:" >&2
# Show relative path to generated script for execution command if possible
script_rel_path="$OUTPUT_SCRIPT"
# Use quoted expansion inside ${..} (SC2295 fix)
if [[ "$OUTPUT_SCRIPT" == "$(pwd)/"* ]]; then
   script_rel_path="./${OUTPUT_SCRIPT#"$(pwd)"/}"
fi
echo "  \"$script_rel_path\"" >&2
echo "For runtime options (diff, verify, update, etc.), see:" >&2
echo "  \"$script_rel_path\" --help" >&2
echo "-----------------------------------------------------" >&2

# Exit successfully
exit 0