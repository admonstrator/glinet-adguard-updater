#!/bin/sh
# shellcheck shell=ash
# The variables set here are read by the functions that are pulled out of the
# script and evaluated below, which shellcheck cannot see.
# shellcheck disable=SC2034
# Regression tests for single functions of update-adguardhome.sh.
#
# Every function is pulled out of the script and evaluated here, so the tests
# run without a router and without touching the system they run on. Paths that
# would be absolute on a router are redirected into a temporary directory.
#
# Usage: sh tests/test-functions.sh [path/to/update-adguardhome.sh]
# No set -e: several functions under test return non-zero on purpose
set -u

SCRIPT="${1:-update-adguardhome.sh}"
WORK=$(mktemp -d)
FAILED=0

cleanup() { rm -rf "${WORK:?}"; }
trap cleanup EXIT

pass() { printf 'ok   %s\n' "$1"; }
fail() {
    printf 'FAIL %s\n' "$1" >&2
    FAILED=1
}

extract() {
    # $1 = function name. Functions end with a closing brace in column 1.
    eval "$(sed -n "/^$1() {/,/^}/p" "$SCRIPT")"
}

constants() {
    # Pull the plain constants out of the script so the tests use the real values
    sed -n '/^AGH_REPO=/p;/^AGH_STABLE_URL=/p;/^AGH_TESTING_URL=/p;/^SHOW_LOG=/p;/^RED=/p;/^GREEN=/p;/^YELLOW=/p;/^INFO=/p' "$SCRIPT"
}

eval "$(constants)"
extract log

# ------------------------------------------------------------------------- log
# A percent sign in a message must survive: it is data, not a format directive
out=$(log "INFO" "100% of 5%s done")
case "$out" in
*"100% of 5%s done"*) pass "log: a percent sign in the message is printed as is" ;;
*) fail "log: mangled the message: $out" ;;
esac
out=$(log "ERROR" "boom")
case "$out" in
*"[X] boom"*) pass "log: ERROR carries its symbol" ;;
*) fail "log: ERROR symbol missing: $out" ;;
esac
# Timestamps only with --log
out=$(log "INFO" "quiet")
case "$out" in
*[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*) fail "log: printed a timestamp without --log: $out" ;;
*) pass "log: no timestamp unless --log is used" ;;
esac
SHOW_LOG=1
out=$(log "INFO" "loud")
case "$out" in
*[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*) pass "log: --log adds a timestamp" ;;
*) fail "log: --log did not add a timestamp: $out" ;;
esac
SHOW_LOG=0

# From here on the log output of the functions under test is just noise
log() { :; }

extract agh_version
extract is_testing_version
extract remove_lines
extract verify_sha256
extract download_and_verify
extract detect_platform

# ------------------------------------------------------------------ is_testing
is_testing_version "v1.0.0-b.1" && pass "is_testing_version: beta is detected" \
    || fail "is_testing_version: beta not detected"
is_testing_version "v0.107.79" && fail "is_testing_version: stable reported as beta" \
    || pass "is_testing_version: stable is not a beta"

# ---------------------------------------------------------------- remove_lines
printf 'keep\n/usr/bin/enable-adguardhome-update-check\nkeep2\n' > "$WORK/rc.local"
remove_lines "$WORK/rc.local" "/usr/bin/enable-adguardhome-update-check"
if [ "$(cat "$WORK/rc.local")" = "$(printf 'keep\nkeep2')" ]; then
    pass "remove_lines: removes the matching line and keeps the rest"
else
    fail "remove_lines: wrong result: $(cat "$WORK/rc.local")"
fi

# A file consisting only of matching lines has to end up empty, not unchanged
printf '/etc/AdGuardHome\n' > "$WORK/sysupgrade.conf"
remove_lines "$WORK/sysupgrade.conf" "/etc/AdGuardHome"
if [ ! -s "$WORK/sysupgrade.conf" ]; then
    pass "remove_lines: empties a file whose every line matches"
else
    fail "remove_lines: file was not emptied: $(cat "$WORK/sysupgrade.conf")"
fi

remove_lines "$WORK/does-not-exist" "whatever" && pass "remove_lines: missing file is not an error" \
    || fail "remove_lines: missing file returned non-zero"

# --------------------------------------------------------------- verify_sha256
printf 'payload\n' > "$WORK/asset"
sum=$(sha256sum "$WORK/asset" | awk '{print $1}')
# Our own releases list the plain name ...
printf '%s  AdGuardHome-linux_arm64\n' "$sum" > "$WORK/checksums.txt"
verify_sha256 "$WORK/asset" "AdGuardHome-linux_arm64" "$WORK/checksums.txt" \
    && pass "verify_sha256: accepts the release format" \
    || fail "verify_sha256: rejected a matching checksum"
# ... upstream prefixes it with ./
printf '%s  ./AdGuardHome_linux_arm64.tar.gz\n' "$sum" > "$WORK/upstream.txt"
verify_sha256 "$WORK/asset" "AdGuardHome_linux_arm64.tar.gz" "$WORK/upstream.txt" \
    && pass "verify_sha256: accepts the upstream ./ format" \
    || fail "verify_sha256: rejected the upstream format"
# A tampered file must be rejected
printf 'tampered\n' > "$WORK/asset"
verify_sha256 "$WORK/asset" "AdGuardHome-linux_arm64" "$WORK/checksums.txt" \
    && fail "verify_sha256: accepted a tampered file" \
    || pass "verify_sha256: rejects a tampered file"
# An unlisted name must be rejected
verify_sha256 "$WORK/asset" "AdGuardHome-linux_nope" "$WORK/checksums.txt" \
    && fail "verify_sha256: accepted a name that is not listed" \
    || pass "verify_sha256: rejects an unlisted name"

# ------------------------------------------------------------- detect_platform
# uname is an external command, so a shell function shadows it
FAKE_ARCH="x86_64"
uname() { printf '%s\n' "$FAKE_ARCH"; }

printf '4.7.0 release\n' > "$WORK/glversion"
printf 'machine\t\t: GL.iNet GL-MT6000\n' > "$WORK/cpuinfo"
GL_VERSION_FILE="$WORK/glversion"
CPUINFO_FILE="$WORK/cpuinfo"
GL_MODEL_FILE="$WORK/model"

check_arch() {
    # $1 = uname output, $2 = /proc/cpuinfo machine value, $3 = expected asset
    FAKE_ARCH="$1"
    printf 'machine\t\t: %s\n' "$2" > "$WORK/cpuinfo"
    detect_platform
    if [ "$AGH_ARCH" = "$3" ]; then
        pass "detect_platform: $1 / $2 -> ${3:-<unsupported>}"
    else
        fail "detect_platform: $1 / $2 -> got '$AGH_ARCH', expected '$3'"
    fi
}

check_arch "aarch64" "GL.iNet GL-BE14000" "AdGuardHome-linux_arm64"
check_arch "armv7l"  "GL.iNet GL-AR750S"  "AdGuardHome-linux_armv7"
check_arch "mips"    "GL.iNet GL-MT1300"  "AdGuardHome-linux_mipsle_softfloat"
check_arch "mips"    "GL-SFT1200"         "AdGuardHome-linux_mipsle_softfloat"
check_arch "mips"    "GL.iNet GL-MT300N"  "AdGuardHome-linux_mips_softfloat"
check_arch "x86_64"  "QEMU"               ""

# The firmware version is the first character of /etc/glversion
if [ "$FIRMWARE_VERSION" = "4" ]; then
    pass "detect_platform: firmware version is read"
else
    fail "detect_platform: firmware version is '$FIRMWARE_VERSION', expected 4"
fi
printf 'garbage\n' > "$WORK/glversion"
detect_platform
if [ "$FIRMWARE_VERSION" = "0" ]; then
    pass "detect_platform: a non-numeric firmware version falls back to 0"
else
    fail "detect_platform: non-numeric firmware version became '$FIRMWARE_VERSION'"
fi

# The model falls back to the GL hardware info file when cpuinfo has no machine
: > "$WORK/cpuinfo"
printf 'be14000\n' > "$WORK/model"
FAKE_ARCH="aarch64"
detect_platform
if [ "$MODEL" = "be14000" ]; then
    pass "detect_platform: falls back to the GL hardware info file"
else
    fail "detect_platform: model is '$MODEL', expected be14000"
fi

unset -f uname

# ------------------------------------------------------- release label filter
# The --select-release menu must never offer a prerelease. This is the exact
# pipeline from choose_release_label(), run against the live API.
if [ "${SKIP_NETWORK_TESTS:-0}" = "1" ]; then
    printf 'skip network tests\n'
else
    releases=$(curl -fL -s --retry 3 --connect-timeout 20 "https://api.github.com/repos/$AGH_REPO/releases?per_page=30") || releases=""
    all_tags=$(printf '%s' "$releases" | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4) || all_tags=""
    labels=$(printf '%s\n' "$all_tags" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$') || labels=""
    if [ -z "$all_tags" ]; then
        # No releases came back at all (offline, or the API rate limit was hit).
        # That says nothing about the filter, so it is not a failure.
        printf 'skip release filter: the GitHub API returned no releases\n'
    elif [ -z "$labels" ]; then
        fail "release filter: filtered away every one of $(printf '%s\n' "$all_tags" | wc -l | tr -d ' ') tags"
    elif printf '%s\n' "$labels" | grep -qE -- '-b\.|^prerelease$'; then
        fail "release filter: a prerelease slipped through: $(printf '%s' "$labels" | tr '\n' ' ')"
    else
        pass "release filter: only plain vX.Y.Z tags ($(printf '%s\n' "$labels" | wc -l | tr -d ' ') found)"
    fi

    # ------------------------------------------------- download_and_verify
    TEMP_CHECKSUMS="$WORK/checksums.download"
    if download_and_verify "$AGH_STABLE_URL" "AdGuardHome-linux_arm64" "$WORK/download"; then
        if [ -s "$WORK/download" ]; then
            pass "download_and_verify: downloads and verifies a real asset"
        else
            fail "download_and_verify: reported success but the file is empty"
        fi
    else
        fail "download_and_verify: a real asset was rejected"
    fi
    # The regression that matters: a 404 must not be reported as success
    if download_and_verify "$AGH_STABLE_URL" "AdGuardHome-linux_nope" "$WORK/download404"; then
        fail "download_and_verify: a 404 was reported as a successful download"
    else
        pass "download_and_verify: a 404 fails instead of storing an error page"
    fi
fi

# ------------------------------------------------------------- install_agh
# Updating the binary must not depend on whether AdGuard Home is running: it can
# be switched off in the GL.iNet web interface. Earlier versions treated "no
# process after the restart" as a failure, rolled back, and then reported the
# rollback as failed too.
extract agh_is_running
extract stop_adguardhome
extract restart_and_verify
extract rollback_binary
extract enable_querylog
extract apply_dns_routing
extract disable_multipath_tcp
extract install_agh

AGH_RESTART_TIMEOUT=2
USER_WANTS_QUERYLOG="n"
DNS_ROUTING_ACTION="none"
BACKUP_PATH=""
AGH_WAS_RUNNING=0
AGH_BIN="$WORK/usr/bin/AdGuardHome"
AGH_BIN_OLD="$WORK/usr/bin/AdGuardHome.old"
AGH_CONFIG_DIR="$WORK/etc/AdGuardHome"
AGH_INIT_SCRIPT="$WORK/init-adguardhome"
TEMP_FILE="$WORK/AdGuardHomeNew"
FAKE_RUNNING="never"

# External commands the functions call, shadowed for the test
pgrep() {
    case "$FAKE_RUNNING" in
    always) return 0 ;;
    never) return 1 ;;
    # "until_restart": running until the init script has been invoked
    *) [ ! -f "$WORK/restarted" ] ;;
    esac
}
killall() { :; }
# Keeps the restart polling instant
sleep() { :; }

fake_binary() {
    # $1 = path, $2 = version to report, or "broken" for a binary that fails
    mkdir -p "$(dirname "$1")"
    if [ "$2" = "broken" ]; then
        printf '#!/bin/sh\nexit 1\n' > "$1"
    else
        printf '#!/bin/sh\necho "AdGuard Home, version %s"\n' "$2" > "$1"
    fi
    chmod +x "$1"
}

setup_install() {
    # $1 = version of the installed binary, $2 = version of the new one
    rm -rf "${WORK:?}/usr" "${WORK:?}/restarted" "${WORK:?}/etc"
    fake_binary "$AGH_BIN" "$1"
    fake_binary "$TEMP_FILE" "$2"
    printf '#!/bin/sh\ntouch "%s/restarted"\nexit 0\n' "$WORK" > "$AGH_INIT_SCRIPT"
    chmod +x "$AGH_INIT_SCRIPT"
}

# 1) AdGuard Home switched off, new binary fine -> the update must succeed
FAKE_RUNNING="never"
setup_install "v0.107.79" "v1.0.0-b.1"
if ( install_agh >/dev/null 2>&1 ); then
    if [ "$(agh_version "$AGH_BIN")" = "v1.0.0-b.1" ] && [ ! -f "$AGH_BIN_OLD" ]; then
        pass "install_agh: updates the binary while AdGuard Home is not running"
    else
        fail "install_agh: wrong state: $(agh_version "$AGH_BIN"), .old present: $([ -f "$AGH_BIN_OLD" ] && echo yes || echo no)"
    fi
else
    fail "install_agh: failed although only the service was not running"
fi

# 2) AdGuard Home switched off, new binary broken -> roll back, report failure
FAKE_RUNNING="never"
setup_install "v0.107.79" "broken"
if ( install_agh >/dev/null 2>&1 ); then
    fail "install_agh: reported success for a broken binary"
elif [ "$(agh_version "$AGH_BIN")" = "v0.107.79" ]; then
    pass "install_agh: rolls back a broken binary even with the service off"
else
    fail "install_agh: did not restore the previous binary: $(agh_version "$AGH_BIN")"
fi

# 3) AdGuard Home running, new binary fine -> update and keep it running
FAKE_RUNNING="always"
setup_install "v0.107.79" "v0.107.80"
if ( install_agh >/dev/null 2>&1 ); then
    if [ "$(agh_version "$AGH_BIN")" = "v0.107.80" ]; then
        pass "install_agh: updates the binary while AdGuard Home is running"
    else
        fail "install_agh: wrong version after the update: $(agh_version "$AGH_BIN")"
    fi
else
    fail "install_agh: failed although the service came back up"
fi

# 4) It was running and does not come back -> that is a real failure, roll back
FAKE_RUNNING="until_restart"
setup_install "v0.107.79" "v0.107.80"
if ( install_agh >/dev/null 2>&1 ); then
    fail "install_agh: reported success although AdGuard Home stayed down"
elif [ "$(agh_version "$AGH_BIN")" = "v0.107.79" ]; then
    pass "install_agh: rolls back when a running AdGuard Home does not come back"
else
    fail "install_agh: did not restore the previous binary: $(agh_version "$AGH_BIN")"
fi

# restart_and_verify on its own: a process that is gone again is not a success
FAKE_RUNNING="never"
if restart_and_verify >/dev/null 2>&1; then
    fail "restart_and_verify: reported success without a running process"
else
    pass "restart_and_verify: fails when no process shows up"
fi
FAKE_RUNNING="always"
if restart_and_verify >/dev/null 2>&1; then
    pass "restart_and_verify: succeeds when the process is up and stays up"
else
    fail "restart_and_verify: failed although the process is running"
fi

unset -f pgrep killall sleep

if [ "$FAILED" -eq 0 ]; then
    printf '\nall function tests passed\n'
else
    printf '\nfunction tests FAILED\n' >&2
fi
exit "$FAILED"
