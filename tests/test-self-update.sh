#!/bin/sh
# shellcheck shell=ash
# Robustness tests for the self-update (invoke_update) of update-adguardhome.sh.
#
# invoke_update must never replace the script with a broken file: a failed
# download, an HTML error page, a truncated file or a syntax error keep the
# current script, and a full flash fails before the current script is touched.
# Downloads are served from local files, so no network is needed.
#
# Usage: sh tests/test-self-update.sh [path/to/update-adguardhome.sh]
# FLASH_DIR: a small, empty filesystem (CI: 1 MB tmpfs) that is filled up to
# stand in for a full flash. Without it a read-only directory is used instead,
# which does not work as root, so that case is skipped then.
set -u

SRC="${1:-update-adguardhome.sh}"
WORK=$(mktemp -d)
FAILED=0
PASSED=0
TMP_SCRIPT="/tmp/update-adguardhome.sh"

cleanup() {
    chmod -R u+w "${WORK:?}" 2>/dev/null
    rm -rf "${WORK:?}"
}
trap cleanup EXIT

pass() {
    PASSED=$((PASSED + 1))
    printf 'ok   %s\n' "$1"
}
fail() {
    printf 'FAIL %s\n' "$1" >&2
    FAILED=$((FAILED + 1))
}

installed_version() { sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p' "$1" | head -n 1; }
CUR_VERSION=$(installed_version "$SRC")

# The script without its last line (main "$@"), so it can be sourced
sed '$d' "$SRC" > "$WORK/lib.sh"
CASES="$WORK/cases"
INST="$WORK/inst"
mkdir -p "$CASES" "$INST"

# Update candidates. Only the version line differs from the current script.
# Never use the real script as a successful update: exec would run it for real.
sed 's/^SCRIPT_VERSION=.*/SCRIPT_VERSION="2099.01.01.01"/' "$SRC" > "$CASES/newer.sh"
head -n 500 "$CASES/newer.sh" > "$CASES/truncated.sh"
sed '$d' "$CASES/newer.sh" > "$CASES/syntax.sh"
printf 'if then fi\nmain "$@"\n' >> "$CASES/syntax.sh"
echo '<html><body>Captive portal</body></html>' > "$CASES/html.sh"
cp "$SRC" "$CASES/same.sh"
printf '#!/bin/sh\nSCRIPT_VERSION="2099.01.01.01"\nmain() { echo "NEW SCRIPT RAN"; }\nmain "$@"\n' > "$CASES/good.sh"

run_update() {
    # $1 = installed script ($0 of invoke_update), $2 = case file served as
    # the download (a missing file is a failed download)
    CASE=$2 CASES=$CASES LIB="$WORK/lib.sh" sh -c '
        . "$LIB"
        sleep() { :; }
        # Like the real one: success only for a complete transfer, no file
        # left behind on failure
        http_download() {
            rm -f "$2"
            [ -f "$CASES/$CASE" ] || return 1
            cp "$CASES/$CASE" "$2"
        }
        invoke_update
    ' "$1" 2>&1
}

expect_kept() {
    # $1 = case, $2 = expected message
    cp "$SRC" "$INST/update-adguardhome.sh"
    out=$(run_update "$INST/update-adguardhome.sh" "$1")
    if [ "$(installed_version "$INST/update-adguardhome.sh")" = "$CUR_VERSION" ] &&
        echo "$out" | grep -q "$2" &&
        [ ! -e "$INST/update-adguardhome.sh.new" ] && [ ! -e "$TMP_SCRIPT" ]; then
        pass "$1: current script kept ($2)"
    else
        fail "$1: $out"
    fi
}

expect_kept missing "Could not check for script updates"
expect_kept html.sh "does not look like this script"
expect_kept same.sh "The script is up to date"
expect_kept truncated.sh "incomplete or damaged"
expect_kept syntax.sh "incomplete or damaged"

# A valid update replaces the script and execs the new version
cp "$SRC" "$INST/update-adguardhome.sh"
out=$(run_update "$INST/update-adguardhome.sh" good.sh)
if [ "$(installed_version "$INST/update-adguardhome.sh")" = "2099.01.01.01" ] &&
    [ -x "$INST/update-adguardhome.sh" ] && echo "$out" | grep -q "NEW SCRIPT RAN" &&
    [ ! -e "$INST/update-adguardhome.sh.new" ] && [ ! -e "$TMP_SCRIPT" ]; then
    pass "good.sh: script replaced and restarted"
else
    fail "good.sh: $out"
fi

# Full flash: the copy fails while the old script is still in place
flash=""
if [ -n "${FLASH_DIR:-}" ]; then
    flash="$FLASH_DIR"
    cp "$SRC" "$flash/update-adguardhome.sh"
    dd if=/dev/zero of="$flash/fill" bs=1024 2>/dev/null
elif [ "$(id -u)" -ne 0 ]; then
    flash="$WORK/flash"
    mkdir -p "$flash"
    cp "$SRC" "$flash/update-adguardhome.sh"
    chmod 555 "$flash"
fi
if [ -n "$flash" ]; then
    out=$(run_update "$flash/update-adguardhome.sh" good.sh)
    if [ "$(installed_version "$flash/update-adguardhome.sh")" = "$CUR_VERSION" ] &&
        sh -n "$flash/update-adguardhome.sh" && echo "$out" | grep -q "flash full" &&
        [ ! -e "$flash/update-adguardhome.sh.new" ] && [ ! -e "$TMP_SCRIPT" ]; then
        pass "full flash: current script kept intact"
    else
        fail "full flash: $out"
    fi
else
    printf 'skip full flash: set FLASH_DIR when running as root\n'
fi

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
