#!/bin/bash
# Creates the apt signing key once: an ed25519 key without passphrase in a temporary
# GNUPGHOME, the private key stored as the repository secret APT_SIGNING_KEY (gh secret
# set), the public key written to caddy-deb.gpg in the repository. Run it in Git Bash from
# the repository folder, logged in with gh; then commit caddy-deb.gpg.
#
#   tools/new-signing-key.sh [backup-file]
#
# With a backup file the private key is also written there (armored). Without one, the
# private key exists only in the GitHub secret: if it is lost, run this again and give
# the servers the new public key.
set -euo pipefail

cd "$(dirname "$0")/.."

repo="MarcFauser/caddy-deb"
uid="caddy-deb apt signing key <297020273+MarcFauser@users.noreply.github.com>"

GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
trap 'gpgconf --kill gpg-agent 2>/dev/null || true; rm -rf "$GNUPGHOME"' EXIT

gpg --batch --passphrase '' --quick-generate-key "$uid" ed25519 sign never
gpg --batch --armor --export-secret-keys | gh secret set APT_SIGNING_KEY --repo "$repo"
gpg --batch --export > caddy-deb.gpg

if [ -n "${1:-}" ]
then
    gpg --batch --armor --export-secret-keys > "$1"
    echo "private key backup written to $1"
fi

gpg --batch --show-keys caddy-deb.gpg
echo "secret APT_SIGNING_KEY set in $repo; now commit caddy-deb.gpg"
