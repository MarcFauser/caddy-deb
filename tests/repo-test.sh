#!/bin/bash
# Installs caddy from the published repository exactly as the README tells a server to:
# the deb822 source file caddy-deb.sources with the embedded key, apt update (checks the
# signature with that key alone, no keyring file is installed), apt install. Run as root on
# a throwaway Debian or Ubuntu machine, from the repository folder:
#   tests/repo-test.sh <repository URL> <expected package version>
set -euo pipefail

cd "$(dirname "$0")/.."
. scripts/plugins.sh

url="${1%/}"
expected="$2"
export DEBIAN_FRONTEND=noninteractive

apt-get update -q
# gnupg only for the key check below; the README's way needs just curl and ca-certificates
apt-get install -y -q curl ca-certificates gnupg
curl -fsSL "$url/caddy-deb.sources" -o /etc/apt/sources.list.d/caddy-deb.sources
cat /etc/apt/sources.list.d/caddy-deb.sources

# The key embedded in the file must be the one committed in caddy-deb.gpg.
expected_fpr="$(gpg --batch --show-keys --with-colons caddy-deb.gpg | awk -F: '$1 == "fpr" { print $10; exit }')"
embedded_fpr="$(sed -n '/^Signed-By:/,$ { /^ /p }' /etc/apt/sources.list.d/caddy-deb.sources \
    | sed -e 's/^ //' -e 's/^\.$//' \
    | gpg --batch --show-keys --with-colons | awk -F: '$1 == "fpr" { print $10; exit }')"
echo "embedded key: $embedded_fpr, committed key: $expected_fpr"
[ -n "$expected_fpr" ] && [ "$embedded_fpr" = "$expected_fpr" ] \
    || { echo "FAIL: the key in caddy-deb.sources is not the key in caddy-deb.gpg" >&2; exit 1; }
[ ! -e /usr/share/keyrings/caddy-deb.gpg ] && [ ! -e /etc/apt/keyrings/caddy-deb.gpg ] \
    || { echo "FAIL: a keyring file exists, the test would not show that the embedded key works" >&2; exit 1; }

# GitHub Pages may need a moment until the new files are served everywhere
for attempt in 1 2 3 4 5 6
do
    apt-get update -q || true
    # captured first: with pipefail, grep -q ending the pipe early turns a hit into a miss
    policy="$(apt-cache policy caddy)"
    if grep -q "Candidate: $expected\$" <<< "$policy"
    then
        break
    fi
    if [ "$attempt" -eq 6 ]
    then
        printf '%s\n' "$policy"
        echo "FAIL: the repository does not offer caddy $expected" >&2
        exit 1
    fi
    sleep 30
done
printf '%s\n' "$policy"

apt-get install -y -q caddy
[ "$(dpkg-query -W -f='${Version}' caddy)" = "$expected" ] || { echo "FAIL: installed version is not $expected" >&2; exit 1; }
check_plugins /usr/bin/caddy main.go

echo
echo "repository test passed"
