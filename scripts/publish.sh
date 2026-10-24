#!/bin/bash
# Builds the apt repository for GitHub Pages in site/: the package from out/ under pool/,
# the Packages index, a Release file signed as InRelease and Release.gpg, the public key
# and an index page. Only the newest package is kept here; every package also stays
# attached to its GitHub release. Needs apt-ftparchive (apt-utils) and gpg holding the
# private signing key, which must belong to the public key caddy-deb.gpg in the repository.
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
<p>How to set up a server: <a href="https://github.com/MarcFauser/caddy-deb#on-a-server">README, "On a server"</a>.
The instructions live only there, so that a correction does not need a new package.</p>
<p>Signing key fingerprint: $public_fpr</p>
<p>Source and documentation: <a href="https://github.com/MarcFauser/caddy-deb">github.com/MarcFauser/caddy-deb</a></p>
</body>
</html>
EOF

find site -type f | sort
cat "site/dists/$suite/Release"
