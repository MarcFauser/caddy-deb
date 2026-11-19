#!/bin/bash
# Builds the apt repository for GitHub Pages in site/: the packages from out/ (one per
# architecture) and the earlier ones from older/ (scripts/fetch-older.sh) under pool/, a
# Packages index per architecture, a Release file signed as InRelease and Release.gpg, the
# public key, the source file caddy-deb.sources for the servers and an index page. Writes the
# offered versions of each architecture, highest first, to out/offered-versions-<arch>.txt.
# Every package also stays attached to its GitHub release. Needs apt-ftparchive (apt-utils),
# dpkg-deb and gpg holding the private signing key, which must belong to the public key
# caddy-deb.gpg in the repository.
#
# Environment: PAGES_URL, the address the repository is served from; caddy-deb.sources points
# apt there.
set -euo pipefail

cd "$(dirname "$0")/.."

: "${PAGES_URL:?set PAGES_URL to the address the repository is served from}"
key_file="caddy-deb.gpg"
suite="stable"
component="main"
archs="$(for deb in out/*.deb; do dpkg-deb --field "$deb" Architecture; done | sort -u | paste -sd ' ')"
[ -n "$archs" ] || { echo "FAIL: no package in out/" >&2; exit 1; }

[ -f "$key_file" ] || { echo "FAIL: $key_file (the public key) is missing" >&2; exit 1; }

# The key that signs must be the one the servers trust.
secret_fpr="$(gpg --batch --list-secret-keys --with-colons | awk -F: '$1 == "fpr" { print $10; exit }')"
public_fpr="$(gpg --batch --show-keys --with-colons "$key_file" | awk -F: '$1 == "fpr" { print $10; exit }')"
if [ -z "$secret_fpr" ] || [ "$secret_fpr" != "$public_fpr" ]
then
    echo "FAIL: the signing key (${secret_fpr:-none}) is not the key in $key_file ($public_fpr)" >&2
    exit 1
fi

rm -rf site
mkdir -p site/pool/main/c/caddy
cp out/*.deb site/pool/main/c/caddy/
if [ -d older ]
then
    find older -maxdepth 1 -name '*.deb' -exec cp {} site/pool/main/c/caddy/ \;
fi

version="$(cat out/version.txt)"
for deb in site/pool/main/c/caddy/*.deb
do
    pool_arch="$(dpkg-deb --field "$deb" Architecture)"
    case " $archs " in
        *" $pool_arch "*) ;;
        *) echo "FAIL: $deb is for $pool_arch, which this run does not publish ($archs)" >&2; exit 1 ;;
    esac
done
rm -f out/offered-versions-*.txt
for arch in $archs
do
    # The offered versions, highest first; the package of this run must be the highest, or apt
    # would install an earlier one.
    offered="$(for deb in site/pool/main/c/caddy/*.deb
        do
            if [ "$(dpkg-deb --field "$deb" Architecture)" = "$arch" ]
            then
                dpkg-deb --field "$deb" Version
            fi
        done | sort -V -r)"
    highest="$(printf '%s\n' "$offered" | awk 'NR == 1')"
    if [ "$highest" != "$version" ]
    then
        echo "FAIL: the highest offered $arch version is $highest, not the package of this run, $version" >&2
        exit 1
    fi
    if [ "$(printf '%s\n' "$offered" | sort -u | wc -l)" -ne "$(printf '%s\n' "$offered" | wc -l)" ]
    then
        echo "FAIL: a $arch version is in the pool twice" >&2
        exit 1
    fi
    printf '%s\n' "$offered" > "out/offered-versions-$arch.txt"
    echo "offered $arch versions: $(paste -sd ' ' "out/offered-versions-$arch.txt")"

    # apt-ftparchive(1): --arch takes only *_<arch>.deb and *_all.deb from the pool
    packages_dir="site/dists/$suite/$component/binary-$arch"
    mkdir -p "$packages_dir"
    (cd site && apt-ftparchive --arch "$arch" packages pool) > "$packages_dir/Packages"
    # not "| grep -qv": under pipefail, grep -q stopping early can turn a hit into a miss
    other_archs="$(grep '^Architecture: ' "$packages_dir/Packages" | grep -v "^Architecture: $arch\$" || true)"
    if [ "$(grep -c '^Package: ' "$packages_dir/Packages")" -ne "$(printf '%s\n' "$offered" | wc -l)" ] \
        || [ -n "$other_archs" ]
    then
        echo "FAIL: binary-$arch/Packages does not list exactly the $arch packages" >&2
        cat "$packages_dir/Packages" >&2
        exit 1
    fi
    gzip -9nk "$packages_dir/Packages"
done

apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=caddy-deb \
    -o APT::FTPArchive::Release::Label=caddy-deb \
    -o APT::FTPArchive::Release::Suite="$suite" \
    -o APT::FTPArchive::Release::Codename="$suite" \
    -o APT::FTPArchive::Release::Architectures="$archs" \
    -o APT::FTPArchive::Release::Components="$component" \
    -o APT::FTPArchive::Release::Description="Caddy with plugins, github.com/MarcFauser/caddy-deb" \
    release "site/dists/$suite" > release.tmp
mv release.tmp "site/dists/$suite/Release"

gpg --batch --yes --local-user "$secret_fpr" --clearsign \
    --output "site/dists/$suite/InRelease" "site/dists/$suite/Release"
gpg --batch --yes --local-user "$secret_fpr" --armor --detach-sign \
    --output "site/dists/$suite/Release.gpg" "site/dists/$suite/Release"

cp "$key_file" site/caddy-deb.gpg

# The source file in deb822 format with the public key embedded in Signed-By, so that a
# server needs one file and no separate keyring. sources.list(5): the key block goes in with
# a leading space on every line and " ." for the empty line; apt supports embedded keys
# since 2.3.10 (debian/changelog), i.e. Debian 12 and Ubuntu 22.04 on.
# No "Architectures:" line: one file serves every architecture. Without the line, apt takes
# the server's own architectures (APT::Architectures); with it, apt takes the listed ones
# instead, whatever the server's are (apt-pkg/deb/debmetaindex.cc, parsePlusMinusArchOptions).
# Files fetched before caddy-deb 4.0.0 say "Architectures: amd64" and keep working on amd64.
{
    echo "# caddy-deb: Caddy with plugins, https://github.com/MarcFauser/caddy-deb"
    echo "# signing key $public_fpr"
    echo "Types: deb"
    echo "URIs: ${PAGES_URL%/}"
    echo "Suites: $suite"
    echo "Components: $component"
    echo "Signed-By:"
    gpg --batch --armor --export "$public_fpr" | sed -e 's/^$/./' -e 's/^/ /'
} > site/caddy-deb.sources
grep -q -- '-----END PGP PUBLIC KEY BLOCK-----' site/caddy-deb.sources \
    || { echo "FAIL: no key block in caddy-deb.sources" >&2; exit 1; }

earlier=""
for arch in $archs
do
    arch_earlier="$(awk 'NR > 1' "out/offered-versions-$arch.txt" | paste -sd ' ')"
    earlier="$earlier $arch: ${arch_earlier:-none}."
done
cat > site/index.html <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>caddy-deb</title></head>
<body>
<h1>caddy-deb</h1>
<p>apt repository with Caddy and the plugins listed in
<a href="https://github.com/MarcFauser/caddy-deb/blob/main/main.go">main.go</a>.
Current package: caddy $version ($archs).
Earlier versions offered for going back:$earlier</p>
<p>Source file for apt, with the signing key embedded:
<a href="caddy-deb.sources">caddy-deb.sources</a>.
How to set up a server: <a href="https://github.com/MarcFauser/caddy-deb#on-a-server">README, "On a server"</a>.</p>
<p>Signing key fingerprint: $public_fpr</p>
<p>Source and documentation: <a href="https://github.com/MarcFauser/caddy-deb">github.com/MarcFauser/caddy-deb</a></p>
</body>
</html>
EOF

find site -type f | sort
cat "site/dists/$suite/Release"
