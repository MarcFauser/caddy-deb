#!/bin/bash
# Installs caddy from the published repository exactly as the README tells a server to:
# the deb822 source file caddy-deb.sources with the embedded key, apt update (checks the
# signature with that key alone, no keyring file is installed), apt install. Then checks
# that apt offers exactly the expected versions and goes through the README's way back:
# install the oldest offered version, hold it, release the hold, upgrade to the newest.
# Run as root on a throwaway Debian or Ubuntu machine, from the repository folder:
#   tests/repo-test.sh <repository URL> <expected package version> ["<offered versions>"]
# The offered versions default to the expected version alone.
set -euo pipefail

cd "$(dirname "$0")/.."
. scripts/plugins.sh

url="${1%/}"
expected="$2"
offered="${3:-$2}"
export DEBIAN_FRONTEND=noninteractive

installed_version()
{
    dpkg-query -W -f='${Version}' caddy
}

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

# exactly the expected versions from this repository, compared sorted
expected_list="$(tr ' ' '\n' <<< "$offered" | awk 'NF' | sort -V -r | paste -sd ' ')"
madison="$(apt-cache madison caddy)"
printf '%s\n' "$madison"
offered_list="$(awk -F'|' '$3 ~ /marcfauser\.github\.io\/caddy-deb/ { gsub(/[[:space:]]/, "", $2); print $2 }' <<< "$madison" | sort -V -r | paste -sd ' ')"
echo "offered by the repository: $offered_list"
echo "expected:                  $expected_list"
[ "$offered_list" = "$expected_list" ] || { echo "FAIL: the repository does not offer exactly the expected versions" >&2; exit 1; }
oldest="$(tr ' ' '\n' <<< "$expected_list" | awk 'NF { v = $0 } END { print v }')"

apt-get install -y -q caddy
[ "$(installed_version)" = "$expected" ] || { echo "FAIL: installed version is not $expected" >&2; exit 1; }
check_plugins /usr/bin/caddy main.go

if [ "$oldest" != "$expected" ]
then
    echo
    echo "== back to the oldest offered version, $oldest, as in the README"
    # -y needs --allow-downgrades (apt-private/private-install.cc); interactively apt asks
    apt-get install -y -q --allow-downgrades "caddy=$oldest"
    [ "$(installed_version)" = "$oldest" ] || { echo "FAIL: going back did not install $oldest" >&2; exit 1; }
    check_plugins /usr/bin/caddy main.go

    apt-mark hold caddy
    apt-get upgrade -y -q
    [ "$(installed_version)" = "$oldest" ] || { echo "FAIL: the hold did not keep $oldest" >&2; exit 1; }
    echo "the hold kept $oldest through apt-get upgrade"

    apt-mark unhold caddy
    apt-get upgrade -y -q
    [ "$(installed_version)" = "$expected" ] || { echo "FAIL: after unhold, upgrade did not install $expected" >&2; exit 1; }
    check_plugins /usr/bin/caddy main.go
    echo "after unhold, apt-get upgrade installed $expected again"
fi

echo
echo "repository test passed"
