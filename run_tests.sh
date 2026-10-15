#!/bin/bash

# RemoteLibrary Test Runner
# Usage: ./run_tests.sh <path_to_koreader_root>

set -e

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <path_to_koreader_root>"
    exit 1
fi

# Resolve absolute paths
KO_DIR=$(cd "$1" && pwd)
PLUGIN_DIR="$KO_DIR/plugins/RemoteLibrary.koplugin"
PLUGIN_SPEC_DIR="$PLUGIN_DIR/spec/unit"
SPEC_DST_DIR="$KO_DIR/spec/unit"

# Automatically detect all .lua files in the plugin spec directory
FILES=($(cd "$PLUGIN_SPEC_DIR" && ls *.lua))

# Derive test names from files ending in _spec.lua
TEST_NAMES=()
for file in "${FILES[@]}"; do
    if [[ "$file" == *_spec.lua ]]; then
        # Remove _spec.lua suffix
        TEST_NAMES+=("${file%_spec.lua}")
    fi
done

source "$PLUGIN_DIR/spec/spec_links.sh"
refuse_spec_collisions "$PLUGIN_SPEC_DIR" "$SPEC_DST_DIR" "${FILES[@]}"

cleanup() {
    echo ""
    echo ">> Cleaning up symlinks in $SPEC_DST_DIR..."
    unlink_specs "$PLUGIN_SPEC_DIR" "$SPEC_DST_DIR" "${FILES[@]}"
}

# Ensure cleanup happens on exit
trap cleanup EXIT

echo ">> Linking RemoteLibrary specs into $SPEC_DST_DIR..."
link_specs "$PLUGIN_SPEC_DIR" "$SPEC_DST_DIR" "${FILES[@]}"

echo ">> Executing tests: ${TEST_NAMES[*]}..."
cd "$KO_DIR"
./kodev test front "${TEST_NAMES[@]}"