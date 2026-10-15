#!/bin/bash

# Exercises run_tests.sh against a throwaway KOReader root whose kodev is a
# stub, so the runner's linking/cleanup can be checked without building KOReader.
# Usage: ./spec/run_tests_collision_test.sh

# No set -e: the runner is expected to fail in some cases, and each one is asserted.
set -u

PLUGIN_DIR=$(cd "$(dirname "$0")/.." && pwd)
FAILURES=0

fail() {
    echo "FAIL: $1" >&2
    FAILURES=$((FAILURES + 1))
}

make_fake_koreader() {
    local ko_dir
    ko_dir=$(mktemp -d)
    mkdir -p "$ko_dir/plugins" "$ko_dir/spec/unit"
    ln -s "$PLUGIN_DIR" "$ko_dir/plugins/RemoteLibrary.koplugin"
    cat > "$ko_dir/kodev" <<'EOF'
#!/bin/bash
echo "$@" > kodev_called
EOF
    chmod +x "$ko_dir/kodev"
    echo "$ko_dir"
}

a_plugin_spec=$(cd "$PLUGIN_DIR/spec/unit" && ls *.lua | head -1)

test_refuses_to_overwrite_a_colliding_file() {
    local ko_dir output status
    ko_dir=$(make_fake_koreader)
    echo "core spec" > "$ko_dir/spec/unit/$a_plugin_spec"

    output=$("$PLUGIN_DIR/run_tests.sh" "$ko_dir" 2>&1)
    status=$?

    [ "$status" -ne 0 ] || fail "collision: expected non-zero exit"
    [[ "$output" == *"$a_plugin_spec"* ]] || fail "collision: error does not name $a_plugin_spec"
    [ ! -L "$ko_dir/spec/unit/$a_plugin_spec" ] && \
        [ "$(cat "$ko_dir/spec/unit/$a_plugin_spec")" = "core spec" ] || fail "collision: core file was changed"
    [ ! -e "$ko_dir/kodev_called" ] || fail "collision: tests ran anyway"
    [ "$(ls "$ko_dir/spec/unit")" = "$a_plugin_spec" ] || fail "collision: other specs were linked"
    rm -rf "$ko_dir"
}

test_refuses_to_overwrite_a_foreign_symlink() {
    local ko_dir status
    ko_dir=$(make_fake_koreader)
    echo "elsewhere" > "$ko_dir/elsewhere.lua"
    ln -s "$ko_dir/elsewhere.lua" "$ko_dir/spec/unit/$a_plugin_spec"

    "$PLUGIN_DIR/run_tests.sh" "$ko_dir" > /dev/null 2>&1
    status=$?

    [ "$status" -ne 0 ] || fail "foreign symlink: expected non-zero exit"
    [ "$(readlink "$ko_dir/spec/unit/$a_plugin_spec")" = "$ko_dir/elsewhere.lua" ] || fail "foreign symlink: was replaced or removed"
    rm -rf "$ko_dir"
}

test_runs_and_cleans_up_without_collisions() {
    local ko_dir status
    ko_dir=$(make_fake_koreader)

    "$PLUGIN_DIR/run_tests.sh" "$ko_dir" > /dev/null 2>&1
    status=$?

    [ "$status" -eq 0 ] || fail "clean run: expected zero exit, got $status"
    [[ "$(cat "$ko_dir/kodev_called" 2>/dev/null)" == "test front "* ]] || fail "clean run: tests were not run"
    [ -z "$(ls "$ko_dir/spec/unit")" ] || fail "clean run: spec/unit not left clean"
    rm -rf "$ko_dir"
}

test_replaces_a_stale_link_from_an_interrupted_run() {
    local ko_dir status
    ko_dir=$(make_fake_koreader)
    ln -s "$ko_dir/plugins/RemoteLibrary.koplugin/spec/unit/$a_plugin_spec" "$ko_dir/spec/unit/$a_plugin_spec"

    "$PLUGIN_DIR/run_tests.sh" "$ko_dir" > /dev/null 2>&1
    status=$?

    [ "$status" -eq 0 ] || fail "stale link: expected zero exit, got $status"
    [ -e "$ko_dir/kodev_called" ] || fail "stale link: tests were not run"
    [ -z "$(ls "$ko_dir/spec/unit")" ] || fail "stale link: spec/unit not left clean"
    rm -rf "$ko_dir"
}

test_replaces_a_stale_link_spelled_through_another_path() {
    local ko_dir status
    ko_dir=$(make_fake_koreader)
    ln -s "$PLUGIN_DIR/spec/unit/$a_plugin_spec" "$ko_dir/spec/unit/$a_plugin_spec"

    "$PLUGIN_DIR/run_tests.sh" "$ko_dir" > /dev/null 2>&1
    status=$?

    [ "$status" -eq 0 ] || fail "stale link via another path: expected zero exit, got $status"
    [ -z "$(ls "$ko_dir/spec/unit")" ] || fail "stale link via another path: spec/unit not left clean"
    rm -rf "$ko_dir"
}

test_refuses_to_overwrite_a_colliding_file
test_refuses_to_overwrite_a_foreign_symlink
test_runs_and_cleans_up_without_collisions
test_replaces_a_stale_link_from_an_interrupted_run
test_replaces_a_stale_link_spelled_through_another_path

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES failure(s)" >&2
    exit 1
fi
echo "All run_tests.sh collision checks passed"
