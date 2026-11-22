#!/usr/bin/env bash
# Color definitions
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m' # No Color

trap 'printf "${YELLOW}\nDownload interrupted. You can resume by re-running the command.\n${NC}"; exit 1' INT

display_help() {
    cat << EOF
Usage:
  ghd <OWNER/REPO> [--include include_pattern1 include_pattern2 ...] [--exclude exclude_pattern1 exclude_pattern2 ...] [--include-dir dir1 dir2 ...] [--exclude-dir dir1 dir2 ...] [--token token] [--tool aria2c|wget] [-x threads] [-j jobs] [--retries n] [--retry-wait sec] [--local-dir path] [--revision rev]

Description:
  Downloads the files of a GitHub repository (without git history) using the provided repo.

Arguments:
  OWNER/REPO      The GitHub repository (Required), e.g. 'octocat/Hello-World'.
Options:
  include/exclude_pattern The patterns to match against file path, supports wildcard characters.
                  e.g., '--exclude *.pdf *.md', '--include docs/*'.
  --include       (Optional) Patterns to include files for downloading (supports multiple patterns).
  --exclude       (Optional) Patterns to exclude files from downloading (supports multiple patterns).
  --include-dir   (Optional) Directories (relative to repo root) to include, e.g. 'docs src/sub' (supports multiple dirs).
  --exclude-dir   (Optional) Directories (relative to repo root) to exclude (supports multiple dirs).
  --token         (Optional) GitHub token for authentication (default: \$GITHUB_TOKEN).
  --tool          (Optional) Download tool to use: aria2c (default) or wget.
  -x              (Optional) Number of download threads for aria2c (default: 4).
  -j              (Optional) Number of concurrent downloads for aria2c (default: 5).
  --retries       (Optional) Number of tries per file, 0 = unlimited (default: 0). aria2c --max-tries / wget --tries.
  --retry-wait    (Optional) Seconds to wait between retries, 0-600 (default: 5). aria2c --retry-wait / wget --waitretry.
  --local-dir     (Optional) Directory path to store the downloaded data.
                             Defaults to the current directory with a subdirectory named 'repo_name'.
  --revision      (Optional) Branch, tag or commit to download (default: HEAD, i.e. the default branch).

Environment:
  GITHUB_TOKEN    Token used when --token is not passed.
  GITHUB_API      API endpoint for the file list (default: https://api.github.com).
  GITHUB_RAW      Endpoint for file downloads (default: https://raw.githubusercontent.com).
                  Override both to use a proxy/mirror.

Limitations:
  Git LFS files are downloaded as LFS pointer files (raw.githubusercontent.com does not serve LFS content).
  Submodules are skipped. Repos with more than 100,000 files get a truncated file list (a warning is printed).

Example:
  ghd octocat/Hello-World
  ghd octocat/Spoon-Knife --revision test-branch
  ghd edisonzf2020/ChinaTextbook --include-dir 小学 --exclude *.md
  ghd myorg/private-repo --token mytoken -x 4
EOF
    exit 1
}

[[ -z "$1" || "$1" =~ ^-h || "$1" =~ ^--help ]] && display_help

REPO=$1
shift
[[ "$REPO" == */* ]] || display_help

# Default values
TOOL="aria2c"
THREADS=4
CONCURRENT=5
RETRIES=0
RETRY_WAIT=5
GITHUB_API=${GITHUB_API:-"https://api.github.com"}
GITHUB_RAW=${GITHUB_RAW:-"https://raw.githubusercontent.com"}
INCLUDE_PATTERNS=()
EXCLUDE_PATTERNS=()
REVISION="HEAD"

validate_number() {
    [[ "$2" =~ ^[1-9][0-9]*$ && "$2" -le "$3" ]] || { printf "${RED}[Error] $1 must be 1-$3${NC}\n"; exit 1; }
}

# Like validate_number but allows 0; the max ($3) is optional.
validate_non_negative() {
    local range="${3:+0-$3}"
    [[ "$2" =~ ^(0|[1-9][0-9]*)$ ]] && [[ -z "$3" || "$2" -le "$3" ]] || { printf "${RED}[Error] $1 must be ${range:-a non-negative integer}${NC}\n"; exit 1; }
}

# Argument parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --include) shift; while [[ $# -gt 0 && ! ($1 =~ ^--) && ! ($1 =~ ^-[^-]) ]]; do INCLUDE_PATTERNS+=("$1"); shift; done ;;
        --exclude) shift; while [[ $# -gt 0 && ! ($1 =~ ^--) && ! ($1 =~ ^-[^-]) ]]; do EXCLUDE_PATTERNS+=("$1"); shift; done ;;
        # ponytail: --include-dir/--exclude-dir reuse the pattern arrays as anchored prefixes "^dir/" (union with --include/--exclude).
        --include-dir) shift; while [[ $# -gt 0 && ! ($1 =~ ^--) && ! ($1 =~ ^-[^-]) ]]; do INCLUDE_PATTERNS+=("^${1%/}/"); shift; done ;;
        --exclude-dir) shift; while [[ $# -gt 0 && ! ($1 =~ ^--) && ! ($1 =~ ^-[^-]) ]]; do EXCLUDE_PATTERNS+=("^${1%/}/"); shift; done ;;
        --token) GITHUB_TOKEN="$2"; shift 2 ;;
        --tool)
            case $2 in
                aria2c|wget)
                    TOOL="$2"
                    ;;
                *)
                    printf "%b[Error] Invalid tool. Use 'aria2c' or 'wget'.%b\n" "$RED" "$NC"
                    exit 1
                    ;;
            esac
            shift 2
            ;;
        -x) validate_number "threads (-x)" "$2" 10; THREADS="$2"; shift 2 ;;
        -j) validate_number "concurrent downloads (-j)" "$2" 10; CONCURRENT="$2"; shift 2 ;;
        --retries) validate_non_negative "retries (--retries)" "$2"; RETRIES="$2"; shift 2 ;;
        --retry-wait) validate_non_negative "retry wait (--retry-wait)" "$2" 600; RETRY_WAIT="$2"; shift 2 ;;
        --local-dir) LOCAL_DIR="$2"; shift 2 ;;
        --revision) REVISION="$2"; shift 2 ;;
        *) display_help ;;
    esac
done

# Generate current command string (the token is passed on the download command line, so it is not stored here)
generate_command_string() {
    local cmd_string="REPO=$REPO"
    cmd_string+=" TOOL=$TOOL"
    cmd_string+=" INCLUDE_PATTERNS=${INCLUDE_PATTERNS[*]}"
    cmd_string+=" EXCLUDE_PATTERNS=${EXCLUDE_PATTERNS[*]}"
    cmd_string+=" GITHUB_API=$GITHUB_API"
    cmd_string+=" GITHUB_RAW=$GITHUB_RAW"
    cmd_string+=" REVISION=$REVISION"
    echo "$cmd_string"
}

# Check if aria2, wget, curl are installed
check_command() {
    if ! command -v $1 &>/dev/null; then
        printf "%b%s is not installed. Please install it first.%b\n" "$RED" "$1" "$NC"
        exit 1
    fi
}

check_command curl; check_command "$TOOL"

LOCAL_DIR="${LOCAL_DIR:-${REPO#*/}}"
mkdir -p "$LOCAL_DIR/.ghd"

API_URL="$GITHUB_API/repos/$REPO/git/trees/$REVISION?recursive=1"
DOWNLOAD_URL="$GITHUB_RAW/$REPO/$REVISION"
# wget keeps the URL path after the host; cut every path component of DOWNLOAD_URL (owner/repo/rev, plus any mirror prefix or '/' in rev).
CUT_DIRS=$(printf '%s' "${DOWNLOAD_URL#*://}" | tr -cd / | wc -c | tr -d ' ')

METADATA_FILE="$LOCAL_DIR/.ghd/repo_tree.json"

# Fetch and save metadata
fetch_and_save_metadata() {
    status_code=$(curl -L -s -w "%{http_code}" -o "$METADATA_FILE" ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} "$API_URL")
    RESPONSE=$(cat "$METADATA_FILE")
    if [ "$status_code" -eq 200 ]; then
        printf "%s\n" "$RESPONSE"
    else
        printf "%b[Error] Failed to fetch file list from $API_URL. HTTP status code: $status_code.%b\n$RESPONSE\n" "${RED}" "${NC}" >&2
        rm "$METADATA_FILE"
        exit 1
    fi
}

should_regenerate_filelist() {
    local command_file="$LOCAL_DIR/.ghd/last_download_command"
    local current_command=$(generate_command_string)
    
    # If file list doesn't exist, regenerate
    if [[ ! -f "$LOCAL_DIR/$fileslist_file" ]]; then
        echo "$current_command" > "$command_file"
        return 0
    fi
    
    # If command file doesn't exist, regenerate
    if [[ ! -f "$command_file" ]]; then
        echo "$current_command" > "$command_file"
        return 0
    fi
    
    # Compare current command with saved command
    local saved_command=$(cat "$command_file")
    if [[ "$current_command" != "$saved_command" ]]; then
        echo "$current_command" > "$command_file"
        return 0
    fi
    
    return 1
}

# Percent-encode a path, keeping '/' (used when jq is not installed)
urlencode() {
    local LC_ALL=C s="$1" out="" c n i
    for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        case $c in
            [a-zA-Z0-9._~/-]) out+=$c ;;
            *) printf -v n '%d' "'$c"; printf -v c '%%%02X' $((n & 255)); out+=$c ;;
        esac
    done
    printf '%s' "$out"
}

fileslist_file=".ghd/${TOOL}_urls.txt"

if should_regenerate_filelist; then
    # Remove existing file list if it exists
    [[ -f "$LOCAL_DIR/$fileslist_file" ]] && rm "$LOCAL_DIR/$fileslist_file"

    # The file list is regenerated only when the command changes, so the tree is fetched with it (no stale tree for a new revision).
    printf "%bFetching repo file tree...%b\n" "$YELLOW" "$NC"
    RESPONSE=$(fetch_and_save_metadata) || exit 1

    # ponytail: the recursive tree API caps at 100,000 entries / 7 MB and sets "truncated": true beyond that.
    # Upgrade path: fetch sub-trees non-recursively and walk them (or narrow with --include-dir on a smaller clone).
    if printf '%s' "$RESPONSE" | grep -qE '"truncated": ?true'; then
        printf "%b[Warning] GitHub returned a truncated file tree; some files will be missing from the download.%b\n" "$YELLOW" "$NC"
    fi
    
    printf "%bGenerating file list...%b\n" "$YELLOW" "$NC"
    
    # Convert include and exclude patterns to regex
    INCLUDE_REGEX=""
    EXCLUDE_REGEX=""
    if ((${#INCLUDE_PATTERNS[@]})); then
        INCLUDE_REGEX=$(printf '%s\n' "${INCLUDE_PATTERNS[@]}" | sed 's/\./\\./g; s/\*/.*/g' | paste -sd '|' -)
    fi
    if ((${#EXCLUDE_PATTERNS[@]})); then
        EXCLUDE_REGEX=$(printf '%s\n' "${EXCLUDE_PATTERNS[@]}" | sed 's/\./\\./g; s/\*/.*/g' | paste -sd '|' -)
    fi

    # Check if jq is available
    if command -v jq &>/dev/null; then
        printf "%s" "$RESPONSE" | jq -r \
            --arg base "$DOWNLOAD_URL" \
            --arg tool "$TOOL" \
            --arg include_regex "$INCLUDE_REGEX" \
            --arg exclude_regex "$EXCLUDE_REGEX" \
            '
            .tree[]
            | select(
                .type == "blob"
                and ($include_regex == "" or (.path | test($include_regex)))
                and ($exclude_regex == "" or (.path | test($exclude_regex) | not))
              )
            | ($base + "/" + (.path | split("/") | map(@uri) | join("/"))) as $url
            | if $tool == "aria2c" then
                [
                  $url,
                  " dir=" + (.path | split("/")[:-1] | join("/")),
                  " out=" + (.path | split("/")[-1]),
                  ""
                ] | join("\n")
              else $url end
            ' > "$LOCAL_DIR/$fileslist_file"
    else
        printf "%b[Warning] jq not installed, using grep/awk for metadata json parsing (slower). Consider installing jq for better parsing performance.%b\n" "$YELLOW" "$NC"
        # ponytail: JSON string escapes in paths (\", \\, \uXXXX) are not decoded here; install jq for such repos.
        files=$(printf '%s' "$RESPONSE" | grep -oE '"(path|type)": ?"[^"]*"' | awk -F'"' '$2 == "path" { p = $4 } $2 == "type" && $4 == "blob" { print p }')
        if [[ -n "$INCLUDE_REGEX" ]]; then
            files=$(printf '%s\n' "$files" | grep -E "$INCLUDE_REGEX")
        fi
        if [[ -n "$EXCLUDE_REGEX" ]]; then
            files=$(printf '%s\n' "$files" | grep -vE "$EXCLUDE_REGEX")
        fi

        while IFS= read -r file; do
            if [[ -n "$file" ]]; then
                if [[ "$TOOL" == "aria2c" ]]; then
                    printf '%s\n dir=%s\n out=%s\n\n' "$DOWNLOAD_URL/$(urlencode "$file")" "$(dirname "$file")" "$(basename "$file")"
                else
                    printf '%s\n' "$DOWNLOAD_URL/$(urlencode "$file")"
                fi
            fi
        done <<< "$files" > "$LOCAL_DIR/$fileslist_file"
    fi
else
    printf "%bResume from file list: $LOCAL_DIR/$fileslist_file%b\n" "$GREEN" "$NC"
fi

# Perform download
printf "${YELLOW}Starting download with $TOOL to $LOCAL_DIR...\n${NC}"

cd "$LOCAL_DIR"
if [[ "$TOOL" == "aria2c" ]]; then
    aria2c --console-log-level=error --file-allocation=none -x "$THREADS" -j "$CONCURRENT" -s "$THREADS" -k 1M -c --max-tries="$RETRIES" --retry-wait="$RETRY_WAIT" -i "$fileslist_file" --save-session="$fileslist_file" ${GITHUB_TOKEN:+--header="Authorization: Bearer $GITHUB_TOKEN"}
elif [[ "$TOOL" == "wget" ]]; then
    # nocontrol: keep UTF-8 (e.g. Chinese) file names instead of escaping bytes 0x80-0x9F.
    # ponytail: --retry-connrefused retries refused connections, as aria2c does. wget --waitretry backs off 1..S seconds instead of a fixed S.
    wget -x -nH --cut-dirs="$CUT_DIRS" --restrict-file-names=nocontrol ${GITHUB_TOKEN:+--header="Authorization: Bearer $GITHUB_TOKEN"} --tries="$RETRIES" --waitretry="$RETRY_WAIT" --retry-connrefused --input-file="$fileslist_file" --continue
fi

if [[ $? -eq 0 ]]; then
    printf "${GREEN}Download completed successfully. Repo directory: $PWD\n${NC}"
else
    printf "${RED}Download encountered errors.\n${NC}"
    exit 1
fi
