
# RepoCapsule

**Pack it, script it, ship it!**

RepoCapsule is a Bash script that packages a directory or repository into a single, portable Bash script (`setup-<repo>.sh`). This generated script can reproduce the directory structure and contents on any compatible system, embed files in dual format (plain text for LLM readability and base64 for execution), and support updates or sharing.

## Features
- **Portable Reproduction:** Creates a standalone script to rebuild a directory anywhere.
- **LLM-Friendly:** Embeds plain text versions of files for easy editing by large language models.
- **Incremental Updates:** Supports updating existing directories with `--update`.
- **Verification:** Ensures integrity with hash checks via `--verify`.
- **Binary & Compression Support:** Optional handling of binary files (`-b`) and large file compression (`-c`).

## Installation
1. Clone the repository:

		git clone https://github.com/jeffrmorton/repocapsule.git
	    cd repocapsule
   
2.  Make the script executable:

	    chmod +x repocapsule.sh

## Usage
	
	./repocapsule.sh [OPTIONS]

### Options

-   -o, --output-dir DIR: Output directory for the generated script (default: .).
-   -b, --binary-support: Include binary files (requires base64).
-   -c, --compress: Compress large files (>1MB, requires gzip and tar).
-   -i, --incremental: Enable incremental updates in the generated script.
-   -v, --verbose: Enable verbose logging to ~/.cache/repocapsule.log.
-   -h, --help: Show help message.
-   --version: Show version.

### Generated Script Usage

After running repocapsule.sh myrepo, you get setup-myrepo.sh. Use it like this:

 - ./setup-myrepo.sh # Reproduce the repo in ./myrepo 
 - ./setup-myrepo.sh --dump # Dump contents for LLM
 - ./setup-myrepo.sh --update # Update existing repo
 - ./setup-myrepo.sh --dry-run # Preview changes
 - ./setup-myrepo.sh --verify # Verify reproduced repo matches original
 - ./setup-myrepo.sh --recalculate-hash # Update source hash after changes
 - ./setup-myrepo.sh --retry-failed # Retry failed file creations

### Example

    ./repocapsule.sh -b -c myproject ./setup-myproject.sh

## Requirements

-   Bash 4.0 or higher
-   Optional: base64 (for -b), gzip and tar (for -c), md5sum or md5 (for --verify)

## Contributing

1.  Fork the repository.
2.  Create a feature branch: git checkout -b my-feature.
3.  Commit changes: git commit -m "Add my feature".
4.  Push to the branch: git push origin my-feature.
5.  Open a pull request.

## License
MIT License - see <LICENSE> for details.