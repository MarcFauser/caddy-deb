#!/bin/bash
# Decides whether to publish the package built in this run or to keep the one already
# published. If nothing in the package changed apart from its version and description (see
# scripts/package-fingerprint.sh), the published package stays: out/ then holds that package
# and its version, the servers have nothing to install and do not restart Caddy. A change
# of the repository itself (index page, sources file, workflow) therefore needs no new
# package revision.
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
if [ "${#debs[@]}" -ne 1 ] || [ ! -f "${debs[0]}" ]
then
    echo "FAIL: expected exactly one package in out/" >&2
    exit 1
fi
new_deb="${debs[0]}"

if [ "${FORCE:-false}" = true ]
then
    echo "a new revision was requested"
    result false
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
if ! curl -fsSL "$PAGES_URL/dists/stable/main/binary-amd64/Packages" -o "$work/Packages"
then
    echo "no published repository yet"
    result false
    exit 0
fi

field()
{
    awk -v key="$1" '/^Package: caddy$/ { p = 1 } p && index($0, key ": ") == 1 { print substr($0, length(key) + 3); exit }' "$work/Packages"
}

filename="$(field Filename)"
version="$(field Version)"
sha256="$(field SHA256)"
if [ -z "$filename" ] || [ -z "$version" ] || [ -z "$sha256" ]
then
    echo "the published index has no complete caddy entry"
    result false
    exit 0
fi

curl -fsSL "$PAGES_URL/$filename" -o "$work/published.deb"
if [ "$(sha256sum "$work/published.deb" | awk '{ print $1 }')" != "$sha256" ]
then
    echo "FAIL: the downloaded $filename does not match the published index" >&2
    exit 1
fi

package_fingerprint "$work/published.deb" > "$work/published.txt"
package_fingerprint "$new_deb" > "$work/new.txt"

if diff -u "$work/published.txt" "$work/new.txt"
then
    echo "the package did not change: keeping the published caddy $version"
    rm -f out/*.deb
    cp "$work/published.deb" "out/$(basename "$filename")"
    echo "$version" > out/version.txt
    result true
else
    echo "the package changed (see the diff above): publishing caddy $(cat out/version.txt)"
    result false
fi
