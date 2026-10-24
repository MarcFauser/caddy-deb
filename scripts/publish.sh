#!/bin/bash
# Builds the apt repository for GitHub Pages in site/: the package from out/ under pool/,
# the Packages index, a Release file signed as InRelease and Release.gpg, the public key,
# the source file caddy-deb.sources for the servers and an index page. Only the newest
# package is kept here; every package also stays attached to its GitHub release. Needs
# apt-ftparchive (apt-utils) and gpg holding the private signing key, which must belong to
# the public key caddy-deb.gpg in the repository.
set -euo pipefail

cd "$(dirname "$0")/.."

key_file="caddy-deb.gpg"
suite="stable"
component="main"
arch="amd64"
packages_dir="site/dists/$suite/$component/binary-$arch"

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
mkdir -p site/pool/main/c/caddy "$packages_dir"
cp out/*.deb site/pool/main/c/caddy/

(cd site && apt-ftparchive packages pool) > "$packages_dir/Packages"
gzip -9nk "$packages_dir/Packages"

apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=caddy-deb \
    -o APT::FTPArchive::Release::Label=caddy-deb \
    -o APT::FTPArchive::Release::Suite="$suite" \
    -o APT::FTPArchive::Release::Codename="$suite" \
    -o APT::FTPArchive::Release::Architectures="$arch" \
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
{
    echo "# caddy-deb: Caddy with plugins, https://github.com/MarcFauser/caddy-deb"
    echo "# signing key $public_fpr"
    echo "Types: deb"
    echo "URIs: https://marcfauser.github.io/caddy-deb"
    echo "Suites: $suite"
    echo "Components: $component"
    echo "Architectures: $arch"
    echo "Signed-By:"
    gpg --batch --armor --export "$public_fpr" | sed -e 's/^$/./' -e 's/^/ /'
} > site/caddy-deb.sources
grep -q -- '-----END PGP PUBLIC KEY BLOCK-----' site/caddy-deb.sources \
    || { echo "FAIL: no key block in caddy-deb.sources" >&2; exit 1; }

version="$(cat out/version.txt)"
cat > site/index.html <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>caddy-deb</title></head>
<body>
<h1>caddy-deb</h1>
<p>apt repository with Caddy and the plugins listed in
<a href="https://github.com/MarcFauser/caddy-deb/blob/main/main.go">main.go</a>.
Current package: caddy $version (amd64).</p>
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
