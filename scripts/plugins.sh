# Helpers for the plugin list, sourced by scripts/build.sh and the tests. The plugins are
# the imports in main.go after the comment "plugins of this build"; main.go is the only
# place where they are listed.

# Prints the import path of every plugin in main.go ($1).
plugin_imports()
{
    sed -n '/plugins of this build/,/^)/ s/^[[:space:]]*_ "\([^"]*\)".*/\1/p' "$1"
}

# Fails unless the caddy binary $1 contains every plugin of main.go ($2): for each import,
# some non-standard module must come from that import's Go module. "caddy list-modules
# --packages --skip-standard" prints "<module id> <go module path>" per module
# (cmd/commandfuncs.go, cmdListModules).
check_plugins()
{
    local bin="$1" main="$2" list imports import missing=0

    imports="$(plugin_imports "$main")"
    if [ -z "$imports" ]
    then
        echo "no plugin imports found in $main" >&2
        return 1
    fi

    list="$("$bin" list-modules --packages --skip-standard)"
    for import in $imports
    do
        if awk -v imp="$import" 'NF >= 2 && (imp == $2 || index(imp, $2 "/") == 1) { found = 1 } END { exit !found }' <<< "$list"
        then
            echo "plugin present: $import"
        else
            echo "plugin MISSING: $import" >&2
            missing=1
        fi
    done

    return "$missing"
}
