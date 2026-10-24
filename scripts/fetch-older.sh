#!/bin/bash
# Puts earlier packages into older/, so that the repository offers KEEP_VERSIONS versions in
# total: the package in out/ plus the KEEP_VERSIONS - 1 highest earlier versions. A server can
# then go back to an earlier version with "apt install caddy=<version>" if the newest has a
# bug. The packages come from this repository's GitHub releases (the Pages site itself only
# holds what the last run put there). Each one is checked against the SHA-256 digest GitHub
# records for the asset, and its package name and version against its release tag.
#
# Environment: GH_REPO (owner/name), GH_TOKEN for gh, KEEP_VERSIONS (default 5).
set -euo pipefail

cd "$(dirname "$0")/.."

: "${GH_REPO:?set GH_REPO to owner/name}"
keep="${KEEP_VERSIONS:-5}"
if ! [[ "$keep" =~ ^[1-9][0-9]*$ ]]
then
    echo "FAIL: KEEP_VERSIONS must be a positive whole number, not '$keep'" >&2
    exit 1
fi
current="$(cat out/version.txt)"

rm -rf older
mkdir older

# One line per published package: version, asset name, digest, download URL. Drafts and
# pre-releases are no candidates; a release without a caddy package is no candidate either.
releases="$(gh api --paginate "repos/$GH_REPO/releases" --jq '
    .[] | select(.draft == false and .prerelease == false)
        | .tag_name as $tag
        | .assets[] | select(.name | test("^caddy_.+_amd64\\.deb$"))
        | "\($tag | ltrimstr("v")) \(.name) \(.digest // "-") \(.browser_download_url)"')"

# Highest version first. sort -V agrees with Debian's ordering for these versions
# (<caddy version>-<run number>); the loop below checks that it does, with dpkg.
sorted="$(printf '%s\n' "$releases" | awk 'NF == 4' | sort -k1,1 -V -r)"

previous=""
candidates=()
while read -r version name digest url
do
    [ -n "$version" ] || continue
    if [ -n "$previous" ] && ! dpkg --compare-versions "$version" lt "$previous"
    then
        echo "FAIL: release versions not in order or twice: $version after $previous" >&2
        exit 1
    fi
    previous="$version"
    if [ "$version" = "$current" ]
    then
        continue # the package in out/ (a kept package has its release already)
    fi
    if dpkg --compare-versions "$version" gt "$current"
    then
        # apt would install that one instead of the package this run publishes
        echo "FAIL: release $version is higher than the package being published, $current" >&2
        exit 1
    fi
    candidates+=("$version $name $digest $url")
done <<< "$sorted"

wanted=$((keep - 1))
echo "keeping $keep versions: $current and up to $wanted earlier of ${#candidates[@]} released"

count=0
for entry in "${candidates[@]}"
do
    [ "$count" -lt "$wanted" ] || break
    read -r version name digest url <<< "$entry"
    case "$digest" in
        sha256:*) ;;
        *) echo "FAIL: GitHub records no SHA-256 digest for $name" >&2; exit 1 ;;
    esac
    curl -fsSL "$url" -o "older/$name"
    actual="$(sha256sum "older/$name" | awk '{ print $1 }')"
    if [ "sha256:$actual" != "$digest" ]
    then
        echo "FAIL: $name does not match the digest of its release ($digest, got sha256:$actual)" >&2
        exit 1
    fi
    package="$(dpkg-deb --field "older/$name" Package)"
    package_version="$(dpkg-deb --field "older/$name" Version)"
    if [ "$package" != caddy ] || [ "$package_version" != "$version" ]
    then
        echo "FAIL: $name contains $package $package_version, its release says caddy $version" >&2
        exit 1
    fi
    echo "  $version  $name"
    count=$((count + 1))
done
