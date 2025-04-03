# RepoCapsule: Package Codebases for LLM Workflows

[![Version](https://img.shields.io/badge/Version-v1.0.0-blue.svg)](https://github.com/jeffrmorton/repocapsule)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![ShellCheck](https://github.com/jeffrmorton/repocapsule/actions/workflows/sequential_tests.yml/badge.svg?branch=main&event=push)](https://github.com/jeffrmorton/repocapsule/actions/workflows/sequential_tests.yml)

**Author:** Jeffrey Morton (Original Concept), LLM/CI enhancements added

**Package an entire directory into a single, self-contained, executable Bash script, specifically optimized for safe and structured interaction with Large Language Models (LLMs) within automated CI/CD workflows.**

## Overview

RepoCapsule takes a source directory (like a project's codebase) and intelligently packages its contents into a single Bash script (`setup-<repo_name>.sh`). This generated script contains:

1.  **Embedded Files:** All source files (text and binary) are embedded within the script. Text files are stored in heredocs (editable by LLMs following specific rules), and binary files are base64 encoded (marked as non-editable).
2.  **Metadata:** Includes repository name, version, file counts, total size, an optional Table of Contents, custom user-provided metadata, and a SHA-256 checksum of the original content.
3.  **Reconstruction Logic:** Bash code to reliably recreate the original directory structure and file contents when the generated script is executed.
4.  **LLM Guidance:** A detailed "System Prompt" embedded as comments, instructing an LLM on how to safely modify only the designated text file content areas within the script, preserving its structure.
5.  **CI/LLM Utilities:** Command-line options within the *generated* script specifically designed to aid automated workflows, such as verifying content (`--verify`), diffing (`--diff`), and managing the embedded hash (`--recalculate-hash`).

The primary goal is to provide a stable, single-unit representation of a codebase that can be passed to an LLM for modification, validated, and then used to reproduce the modified code, streamlining automated development loops.

## Key Features

*   **Self-Contained Packaging:** Bundles an entire directory into one executable Bash script.
*   **Text & Binary Support:** Intelligently detects and handles both text files (via heredocs) and binary files (via base64).
*   **Metadata Embedding:** Includes project name, version, file list (TOC), checksum, Git commit (optional), and custom info.
*   **Permissions Preservation:** Records and restores original file permissions.
*   **Checksum Verification:** Generates a SHA-256 hash of the source content (`SOURCE_HASH`) embedded in the script for later verification (`--verify`).
*   **LLM Safety Prompts:** Includes detailed instructions within comments (the System Prompt) to guide LLMs on safe editing practices within the generated script.
*   **CI/Automation Focused Utilities (in generated script):**
    *   `--verify`: Compare extracted files against the embedded checksum.
    *   `--recalculate-hash`: Update the embedded checksum after verified changes.
    *   `--diff <original_dir>`: Compare embedded content against an existing directory.
    *   `--dump`: List embedded file metadata.
    *   `--update`: Allow overwriting files in an existing target directory.
    *   `--dry-run`: Simulate extraction without writing files.
    *   `--retry-failed`: Attempt to recreate files that failed in a previous run.
*   **Customizable Exclusions:** Easily exclude files or patterns using `find` syntax (defaults include `.git`, `.gitignore`, etc.).
*   **Cross-Platform Compatibility:** Uses common POSIX utilities available on Linux and macOS. Requires Bash 4.0+. Handles `realpath` differences (prefers `grealpath` if available).

## Requirements

To run `repocapsule.sh` (the script that *creates* the capsule):

*   **Bash 4.0+**
*   **Core Utilities:** `bash`, `date`, `stat`, `find`, `cat`, `sed`, `mkdir`, `chmod`, `base64`, `shasum` (or compatible like `sha256sum`), `tr`, `diff`, `mktemp`, `grep`, `awk`, `sort`, `xargs`, `pwd`, `dirname`, `basename`, `printf`, `uname`, `cd`, `file`, `head`.
*   **Realpath:** A working `realpath` command. On macOS, this is often provided by installing `coreutils` (`brew install coreutils`) which provides `grealpath`. The script automatically prefers `grealpath`.
*   `uuidgen` (optional, provides better delimiter uniqueness, falls back to date/random if missing).

The *generated* `setup-*.sh` script also requires Bash 4.0+ and a subset of these utilities for its runtime functions:

*   **Core:** `bash`, `cat`, `base64`, `mkdir`, `chmod`, `shasum`
*   **File/Dir Utils:** `pwd`, `dirname`, `basename`, `cd`, `find`, `rm`, `cp`, `mv`, `mktemp`
*   **Text Processing:** `grep`, `awk`, `sed`, `sort`, `xargs`, `diff`, `head`, `wc`, `tr` (via `is_binary` if needed), `printf`, `cut` (via `usage_runtime`)
*   **Other:** `read`, `date`, `trap`

**Development/Testing:**
*   `shellcheck` (Recommended for linting the generator and generated scripts)
*   `git` (Optional, needed for embedding commit hash)
*   `coreutils` (On macOS, for `grealpath` and potentially other GNU utilities if standard versions are insufficient)

## Installation

RepoCapsule is a standalone script.

1.  Download the `repocapsule.sh` script (e.g., from the repository releases or clone the repo).
2.  Make it executable: `chmod +x repocapsule.sh`
3.  (Optional) Place it in a directory included in your system's `PATH` (like `/usr/local/bin` or `~/bin`) for easier access from anywhere.

## Usage (`repocapsule.sh`)

Run the script, pointing it to the directory you want to package.

**Options:**

| Option                | Description                                                                 | Default                  |
| --------------------- | --------------------------------------------------------------------------- | ------------------------ |
| `-v, --verbose`       | Enable verbose output during generation.                                    | `false`                  |
| `-f, --force`         | Overwrite existing output script without prompting.                         | `false`                  |
| `-i, --create-index`  | Generate a separate `.index` file mapping paths to line numbers.             | `false`                  |
| `-o, --output-dir DIR`| Output directory for the generated script.                                 | `.` (current directory)  |
| `-n, --name NAME`     | Repository name used in the script and default target dir.                 | `basename <source_dir>` |
| `-V, --version VER`   | Repository version embedded in the script.                                  | `1.0.0`                  |
| `-g, --include-git`   | Include the `.git` directory and common git files (overrides defaults).      | `false` (excluded)       |
| `-e, --exclude PATTERN`| Add an exclusion pattern (uses `find -name` or `-path`). Multi-use.         | See Defaults below       |
| `-m, --metadata "INFO"`| Add a custom metadata line (comment) for LLM context. Multi-use.           | None                     |
| `-h, --help`          | Show this help message.                                                     | N/A                      |

**Default Exclusions (when `-g` is NOT used):**

*   `.git` (directory)
*   `.gitignore` (file)
*   `*.md` (files ending in .md)
*   `LICENSE` (file)
*   `.DS_Store` (file)

**Example:**

Package the 'my-python-project' directory into ./setup-my-python-project.sh
./repocapsule.sh ./my-python-project

Package with a specific name, version, custom metadata, and exclude logs/temp files
./repocapsule.sh -n MyWebApp -V 2.5.1 -o ./capsules -e '*.log' -e '*~' -m "Project Type: Flask Web App" -m "Main File: app.py" ./my-web-app


## Generated Script Usage (`setup-*.sh`)

The script generated by RepoCapsule (`setup-<repo_name>.sh`) has its own set of command-line options for extraction and utility functions:

**Key Options:**

| Option                     | Description                                                                     |
| -------------------------- | ------------------------------------------------------------------------------- |
| (no args)                  | Extracts all embedded files into the target directory (Default: `./<repo_name>`). |
| `--help`                   | Show detailed help, including the LLM workflow guide.                           |
| `--target-dir DIR`         | Specify a different target directory for extraction.                            |
| `--update`                 | Allow overwriting existing files in the target directory.                       |
| `--verify`                 | Verify extracted files in `TARGET_DIR` against the embedded `SOURCE_HASH`.      |
| `--recalculate-hash`       | Update the script's `SOURCE_HASH` based on `TARGET_DIR` content (prompts confirmation). |
| `--diff ORIG_DIR [pattern]`| Extract to temp dir & compare (`diff -urN`) against `ORIG_DIR`.                 |
| `--dump [pattern]`         | Print file markers and metadata, optionally filter by ERE pattern.              |
| `--dry-run`                | List files that would be processed without creating them.                       |
| `--retry-failed`           | Attempt to create only files that failed in a previous run.                     |

**Examples (setup-MyWebApp.sh):**

Extract the code to the default location (./MyWebApp)
./setup-MyWebApp.sh

Extract to a specific directory, overwriting if it exists
./setup-MyWebApp.sh --target-dir ./build --update

Verify the contents of an existing extraction against the script's hash
./setup-MyWebApp.sh --target-dir ./build --verify

Show differences between the script's content and an older version
./setup-MyWebApp.sh --diff ./MyWebApp-v2.5.0

After modifying the script with an LLM (and verifying), update its hash
Assuming the modified code is correctly extracted in ./MyWebApp-modified
./setup-MyWebApp-modified.sh --target-dir ./MyWebApp-modified --recalculate-hash
(Confirm 'y' when prompted)

## LLM Development Workflow Guide

RepoCapsule is designed for loops where an LLM modifies code:

1.  **Provide System Prompt:** Ensure the LLM receives the `<<< RECOMMENDED LLM SYSTEM PROMPT >>>` found near the top of the *generated* `setup-*.sh` script. This is *critical* for safety.
2.  **Generate Baseline:** Create the initial capsule: `./repocapsule.sh ./my-code -n MyCode -o .` -> `setup-MyCode.sh`
3.  **Send Task to LLM:** Give the LLM the `setup-MyCode.sh` script and the task (e.g., "Refactor the function `parse_data` in `src/parser.py` to improve efficiency..."). Remind it to follow the System Prompt rules.
4.  **Receive Modified Script:** The LLM *must* return the *entire* modified script. Save this as `setup-MyCode-modified.sh`.
5.  **Validate Syntax (Optional but Recommended):** Check basic structural integrity: `bash -n setup-MyCode-modified.sh`. A syntax error suggests the LLM failed to follow instructions. ShellCheck (`shellcheck setup-MyCode-modified.sh`) is even better.
6.  **Extract & Diff (Review):**
    *   Extract the original: `./setup-MyCode.sh --target-dir original_code`
    *   Extract the modified: `./setup-MyCode-modified.sh --target-dir modified_code`
    *   Review changes: `diff -urN original_code modified_code` or use the capsule's diff: `./setup-MyCode-modified.sh --diff original_code`
7.  **Test & Validate:** Run your project's tests, linters, build steps, etc., on the `modified_code` directory.
8.  **Evaluate:**
    *   **Success:** If tests pass and changes are good. Update the hash in the *modified* script: `./setup-MyCode-modified.sh --target-dir modified_code --recalculate-hash` (confirm 'y'). Commit `setup-MyCode-modified.sh` as the new baseline (`mv setup-MyCode-modified.sh setup-MyCode.sh`).
    *   **Failure:** If tests fail or changes are incorrect. Provide the errors/diffs as feedback to the LLM in the next iteration (go back to step 3 using the *original* or last known good `setup-MyCode.sh`).

This workflow provides a robust way to manage LLM code modifications within version control and CI/CD pipelines.

## Contributing

Contributions, bug reports, and feature requests are welcome! Please feel free to open an issue or submit a pull request on the project repository. <!-- Update if hosted on GitHub/etc -->

## License

This project is licensed under the MIT License - see the `LICENSE` file (or the license text at the top of `repocapsule.sh`) for details.