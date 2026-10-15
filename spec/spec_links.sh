# Sourced by the test runners to link plugin specs into KOReader's spec/unit.
# A destination is "ours" only if it is a symlink to the plugin's own spec, so
# a same-named KOReader spec is never overwritten or deleted.

is_own_spec_link() {
    local src_dir=$1 dst_dir=$2 file=$3
    [ -L "$dst_dir/$file" ] && [ "$dst_dir/$file" -ef "$src_dir/$file" ]
}

refuse_spec_collisions() {
    local src_dir=$1 dst_dir=$2 file collisions=()
    shift 2
    for file in "$@"; do
        if [ -e "$dst_dir/$file" ] || [ -L "$dst_dir/$file" ]; then
            is_own_spec_link "$src_dir" "$dst_dir" "$file" || collisions+=("$file")
        fi
    done
    if [ "${#collisions[@]}" -ne 0 ]; then
        echo "Refusing to overwrite KOReader files in $dst_dir: ${collisions[*]}" >&2
        echo "Rename the colliding plugin spec(s)." >&2
        return 1
    fi
}

link_specs() {
    local src_dir=$1 dst_dir=$2 file
    shift 2
    for file in "$@"; do
        ln -sf "$src_dir/$file" "$dst_dir/$file"
    done
}

unlink_specs() {
    local src_dir=$1 dst_dir=$2 file
    shift 2
    for file in "$@"; do
        if is_own_spec_link "$src_dir" "$dst_dir" "$file"; then
            rm "$dst_dir/$file"
        fi
    done
}
