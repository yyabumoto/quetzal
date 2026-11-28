#!/bin/bash
# Runs the QuetzalUITests scheme and writes one PNG per fixture state and appearance
# as <scenario>-<appearance>.png.
#
# usage: scripts/ui-screenshots.sh [output-directory]
set -eu

caller_dir=$(pwd -P)
cd "$(dirname "$0")/.."
repo_root=$(git rev-parse --show-toplevel)
repo_root=$(cd "$repo_root" && pwd -P)

scenarios="no-repository worktree-selected session-in-progress pending-approval error-notice"
appearances="light dark"
expected=""
for scenario in $scenarios; do
    for appearance in $appearances; do
        expected="$expected $scenario-$appearance"
    done
done

if [ $# -gt 1 ]; then
    echo "usage: scripts/ui-screenshots.sh [output-directory]" >&2
    exit 2
fi

automation_status=$(automationmodetool 2>&1 || true)
case "$automation_status" in
    *"DOES NOT REQUIRE user authentication"*) ;;
    *)
        echo "automationmodetool reports that Automation Mode needs authentication. Inside a command sandbox it reports this even when the Mac is set up; run the script outside the sandbox first. If it still fails there, ask the developer to run once: sudo automationmodetool enable-automationmode-without-authentication" >&2
        exit 3
        ;;
esac

# Prints the absolute physical path of $1, which may not exist yet.
resolve() {
    local path=$1 rest=""
    case "$path" in /*) ;; *) path="$caller_dir/$path" ;; esac
    while [ ! -d "$path" ]; do
        rest="/$(basename "$path")$rest"
        path=$(dirname "$path")
    done
    echo "$(cd "$path" && pwd -P)$rest"
}

if [ $# -eq 1 ]; then
    out=$(resolve "$1")
    case "$out/" in
        "$repo_root"/*)
            echo "Choose an output directory outside the repository." >&2
            exit 2
            ;;
    esac
    if [ -e "$out" ] && [ -n "$(ls -A "$out" 2>/dev/null || echo not-a-directory)" ]; then
        echo "Output directory is not empty: $out" >&2
        exit 2
    fi
fi

if pgrep -x Quetzal > /dev/null; then
    echo "Quit Quetzal first: the UI tests terminate a running instance." >&2
    exit 1
fi

if [ $# -eq 1 ]; then
    mkdir -p "$out"
else
    out=$(mktemp -d "${TMPDIR:-/tmp}/quetzal-screenshots.XXXXXX")
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/quetzal-ui-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT

test_status=0
xcodebuild test -project Quetzal.xcodeproj -scheme QuetzalUITests -configuration Debug \
    -destination 'platform=macOS' -resultBundlePath "$work/UITests.xcresult" || test_status=$?

# One line per PNG attachment: exported file name, then the name xcresulttool suggests.
# Attachments XCTest adds when a test fails are skipped.
: > "$work/attachments.tsv"
if [ -d "$work/UITests.xcresult" ]; then
    if xcrun xcresulttool export attachments --path "$work/UITests.xcresult" --output-path "$work/attachments"; then
        jq -r '.[].attachments[]
            | select((.exportedFileName | endswith(".png")) and (.isAssociatedWithFailure | not))
            | [.exportedFileName, .suggestedHumanReadableName] | @tsv' \
            "$work/attachments/manifest.json" > "$work/attachments.tsv" || : > "$work/attachments.tsv"
    fi
fi

# xcresulttool may append an extension or "_<index>_<UUID>" to the attachment name.
matches() {
    awk -F '\t' -v name="$1" '$2 == name || $2 == name ".png" || index($2, name "_") == 1 { print $1 }' \
        "$work/attachments.tsv"
}

written=0
missing=""
unexpected=""
for name in $expected; do
    files=$(matches "$name")
    count=$(printf '%s' "$files" | grep -c . || true)
    if [ "$count" -eq 0 ]; then
        missing="$missing $name"
    elif [ "$count" -gt 1 ]; then
        unexpected="$unexpected $name(x$count)"
    else
        cp "$work/attachments/$files" "$out/$name.png"
        echo "$out/$name.png"
        written=$((written + 1))
    fi
done

others=$(awk -F '\t' -v names="$expected" '
    BEGIN { n = split(names, list, " ") }
    {
        known = 0
        for (i = 1; i <= n; i++) {
            if ($2 == list[i] || $2 == list[i] ".png" || index($2, list[i] "_") == 1) known = 1
        }
        if (!known) print $2
    }' "$work/attachments.tsv" | tr '\n' ' ')
if [ -n "$others" ]; then
    unexpected="$unexpected ${others% }"
fi

echo "Output directory: $out"
if [ -n "$missing" ]; then
    echo "Missing screenshots:$missing" >&2
fi
if [ -n "$unexpected" ]; then
    echo "Unexpected screenshot attachments:$unexpected" >&2
fi

if [ "$test_status" -ne 0 ]; then
    exit "$test_status"
fi
if [ "$written" -eq 0 ]; then
    echo "No screenshots were produced. See the xcodebuild output above." >&2
    exit 1
fi
if [ -n "$missing" ] || [ -n "$unexpected" ]; then
    exit 1
fi
