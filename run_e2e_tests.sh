#!/bin/bash

# RemoteLibrary E2E Test Runner
# Runs the local-only integration/e2e layer (spec/e2e) against a real,
# on-demand WebDAV server. Not wired into run_tests.sh or CI.
# Usage: ./run_e2e_tests.sh <path_to_koreader_root>

set -e

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <path_to_koreader_root>"
    exit 1
fi

# Resolve absolute paths
KO_DIR=$(cd "$1" && pwd)
PLUGIN_DIR="$KO_DIR/plugins/RemoteLibrary.koplugin"
PLUGIN_SPEC_DIR="$PLUGIN_DIR/spec/e2e"
SPEC_DST_DIR="$KO_DIR/spec/unit"

# Automatically detect all .lua files in the plugin e2e spec directory
FILES=($(cd "$PLUGIN_SPEC_DIR" && ls *.lua))

# Derive test names from files ending in _spec.lua
TEST_NAMES=()
for file in "${FILES[@]}"; do
    if [[ "$file" == *_spec.lua ]]; then
        TEST_NAMES+=("${file%_spec.lua}")
    fi
done

# Fixed host/port/credentials: single local dev environment, no parallel
# workers, so a hardcoded address is simpler than threading a dynamic one
# through env vars.
export REMOTELIBRARY_E2E_WEBDAV_HOST="127.0.0.1"
export REMOTELIBRARY_E2E_WEBDAV_PORT="18109"
export REMOTELIBRARY_E2E_WEBDAV_USERNAME="testuser"
export REMOTELIBRARY_E2E_WEBDAV_PASSWORD="testpass"

# Lets a spec seed/refresh fixture files directly on disk before scanning.
export REMOTELIBRARY_E2E_FIXTURES_DIR="$PLUGIN_SPEC_DIR/fixtures"

WEBDAV_DATA_DIR=$(mktemp -d)
# Exported so the download-failures spec can restart the shared server
# (after deliberately killing it) against the same served files, without
# needing every other spec file to run before it.
export REMOTELIBRARY_E2E_WEBDAV_DATA_DIR="$WEBDAV_DATA_DIR"
WEBDAV_PID=""

# Defense-in-depth: `npx webdav-cli` forks through npm-exec/sh/node, so
# killing only the top-level PID can leave the real server process
# orphaned and still bound to our fixed port, silently serving stale state
# to the next run. Clear any such leftover before (re)starting.
kill_stale_webdav() {
    pkill -f "webdav-cli --host ${REMOTELIBRARY_E2E_WEBDAV_HOST} --port ${REMOTELIBRARY_E2E_WEBDAV_PORT} " 2>/dev/null || true
}

start_webdav() {
    kill_stale_webdav
    echo ">> Starting local WebDAV server on ${REMOTELIBRARY_E2E_WEBDAV_HOST}:${REMOTELIBRARY_E2E_WEBDAV_PORT}..."
    # setsid: run in its own process group so cleanup can kill the whole
    # npx/npm-exec/node process tree at once, not just the shell's direct
    # child (see kill_stale_webdav above for why that matters).
    setsid npx --yes webdav-cli \
        --host "$REMOTELIBRARY_E2E_WEBDAV_HOST" \
        --port "$REMOTELIBRARY_E2E_WEBDAV_PORT" \
        --username "$REMOTELIBRARY_E2E_WEBDAV_USERNAME" \
        --password "$REMOTELIBRARY_E2E_WEBDAV_PASSWORD" \
        --path "$WEBDAV_DATA_DIR" \
        >/tmp/remotelibrary_e2e_webdav.log 2>&1 &
    WEBDAV_PID=$!

    for _ in $(seq 1 50); do
        if curl -s -o /dev/null \
            -u "${REMOTELIBRARY_E2E_WEBDAV_USERNAME}:${REMOTELIBRARY_E2E_WEBDAV_PASSWORD}" \
            -X PROPFIND "http://${REMOTELIBRARY_E2E_WEBDAV_HOST}:${REMOTELIBRARY_E2E_WEBDAV_PORT}/"; then
            return 0
        fi
        sleep 0.2
    done

    echo "webdav-cli did not become ready in time; see /tmp/remotelibrary_e2e_webdav.log" >&2
    exit 1
}

cleanup() {
    echo ""
    echo ">> Stopping local WebDAV server..."
    if [ -n "$WEBDAV_PID" ]; then
        kill -- "-${WEBDAV_PID}" 2>/dev/null || true
        wait "$WEBDAV_PID" 2>/dev/null || true
    fi
    kill_stale_webdav
    rm -rf "$WEBDAV_DATA_DIR"

    echo ">> Cleaning up symlinks in $SPEC_DST_DIR..."
    for file in "${FILES[@]}"; do
        if [ -L "$SPEC_DST_DIR/$file" ]; then
            rm "$SPEC_DST_DIR/$file"
        fi
    done
}

# Ensure cleanup happens on exit
trap cleanup EXIT

start_webdav

echo ">> Seeding WebDAV fixtures..."
cp "$REMOTELIBRARY_E2E_FIXTURES_DIR"/*.txt "$WEBDAV_DATA_DIR/"

echo ">> Linking RemoteLibrary e2e specs into $SPEC_DST_DIR..."
for file in "${FILES[@]}"; do
    ln -sf "$PLUGIN_SPEC_DIR/$file" "$SPEC_DST_DIR/$file"
done

echo ">> Executing e2e tests: ${TEST_NAMES[*]}..."
cd "$KO_DIR"
# -j 1: meson's default test parallelism (one worker per core) races these
# specs against the single shared WebDAV server and against each other's
# KO_HOME-rooted filesystem I/O under CPU contention, causing intermittent
# false failures that never reproduce when a spec is run alone. Force
# sequential execution to match this suite's actual design assumption:
# single local dev environment, no parallel workers.
./kodev test -j 1 front "${TEST_NAMES[@]}"
