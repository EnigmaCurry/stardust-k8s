## bash helpers

require_vars() {
    local ok=true
    for var in "$@"; do
        [ ! -v $var ] && echo "Required variable not set: $var" && ok=false
    done
    [ $ok != "true" ] && exit 1
}
