#!/bin/bash
# Decides whether to publish the packages built in this run or to keep the ones already
# published. All architectures share one version, so they are decided together: only if every
# package (one per architecture in out/) has a published counterpart of the same version and
# nothing in it changed apart from its version and description (see
# scripts/package-fingerprint.sh), the published packages stay: out/ then holds those packages
# and their version, the servers have nothing to install and do not restart Caddy. A change
# of the repository itself (index page, sources file, workflow) therefore needs no new
# package revision; a new architecture does, for all of them.
#
# Environment: PAGES_URL (the published repository), FORCE (true: always the new package).
# Writes reused=true or reused=false to $GITHUB_OUTPUT when that is set.
set -euo pipefail

cd "$(dirname "$0")/.."
. scripts/package-fingerprint.sh

: "${PAGES_URL:?set PAGES_URL to the published repository}"

result()
{
    echo "reused=$1"
    if [ -n "${GITHUB_OUTPUT:-}" ]
    then
        echo "reused=$1" >> "$GITHUB_OUTPUT"
    fi
}

debs=(out/*.deb)
if [ ! -f "${debs[0]}" ]
then
    echo "FAIL: no package in out/" >&2
    exit 1
fi

if [ "${FORCE:-false}" = true ]
then
    echo "a new revision was requested"
    result false
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Compares the new package $1 with the highest published one of its architecture. If they are
# the same, that package is left in $work/published-<arch>.deb and its version in
# $work/version-<arch>; otherwise changed=1. Called as a plain command, not in an "if" or
# "||", so that set -e stops on any failing step inside instead of counting it as a change.
compare_with_published()
{
    local deb="$1" arch entries version="" filename="" sha256="" v f s

    arch="$(dpkg-deb --field "$deb" Architecture)"
    if ! curl -fsSL "$PAGES_URL/dists/stable/main/binary-$arch/Packages" -o "$work/Packages-$arch"
    then
        echo "$arch: nothing published yet"
        changed=1
        return 0
    fi

    # The index lists several caddy versions (KEEP_VERSIONS, scripts/fetch-older.sh), in file
    # name order, so the oldest may come first: compare with the highest version.
    entries="$(awk -v arch="$arch" '
        /^Package: / { p = ($2 == "caddy"); a = v = f = s = "" }
        p && /^Architecture: / { a = $2 }
        p && /^Version: / { v = $2 }
        p && /^Filename: / { f = $2 }
        p && /^SHA256: / { s = $2 }
        p && /^$/ { if (a == arch && v != "" && f != "" && s != "") print v, f, s; p = 0 }
        END { if (p && a == arch && v != "" && f != "" && s != "") print v, f, s }
    ' "$work/Packages-$arch")"

    while read -r v f s
    do
        [ -n "$v" ] || continue
        if [ -z "$version" ] || dpkg --compare-versions "$v" gt "$version"
        then
            version="$v" filename="$f" sha256="$s"
        fi
    done <<< "$entries"
    if [ -z "$filename" ] || [ -z "$version" ] || [ -z "$sha256" ]
    then
        echo "$arch: the published index has no complete caddy entry"
        changed=1
        return 0
    fi

    curl -fsSL "$PAGES_URL/$filename" -o "$work/published-$arch.deb"
    if [ "$(sha256sum "$work/published-$arch.deb" | awk '{ print $1 }')" != "$sha256" ]
    then
        echo "FAIL: the downloaded $filename does not match the published index" >&2
        exit 1
    fi
    echo "$version" > "$work/version-$arch"

    package_fingerprint "$work/published-$arch.deb" > "$work/published-$arch.txt"
    package_fingerprint "$deb" > "$work/new-$arch.txt"
    if diff -u "$work/published-$arch.txt" "$work/new-$arch.txt"
    then
        echo "$arch: the package did not change (published: caddy $version)"
    else
        echo "$arch: the package changed (see the diff above)"
        changed=1
    fi
}

changed=0
archs=()
for deb in "${debs[@]}"
do
    archs+=("$(dpkg-deb --field "$deb" Architecture)")
    compare_with_published "$deb"
done

# All architectures share one version: keeping is only possible if they were published as one
# (a new architecture has no published package and is "changed" above).
kept_versions="$(for arch in "${archs[@]}"; do cat "$work/version-$arch" 2>/dev/null || echo none; done | sort -u)"
if [ "$changed" -eq 0 ] && [ "$(wc -l <<< "$kept_versions")" -ne 1 ]
then
    echo "the published architectures have different versions: $(paste -sd ' ' <<< "$kept_versions")"
    changed=1
fi

if [ "$changed" -eq 0 ]
then
    version="$kept_versions"
    echo "no package changed: keeping the published caddy $version (${archs[*]})"
    # the Windows zip of this run carries this run's revision; the kept release has its own
    rm -f out/*.deb out/*_windows_amd64.zip
    for arch in "${archs[@]}"
    do
        cp "$work/published-$arch.deb" "out/caddy_${version}_${arch}.deb"
    done
    echo "$version" > out/version.txt
    result true
else
    echo "publishing caddy $(cat out/version.txt) (${archs[*]})"
    result false
fi
