#!/bin/bash
# Installs caddy from the published repository exactly as the README tells a server to:
# key, source line, apt update (checks the signature), apt install. Run as root on a
# throwaway Debian or Ubuntu machine, from the repository folder:
#   tests/repo-test.sh <repository URL> <expected package version>
set -euo pipefail

cd "$(dirname "$0")/.."
. scripts/plugins.sh

url="${1%/}"
expected="$2"
export DEBIAN_FRONTEND=noninteractive

apt-get update -q
apt-get install -y -q curl ca-certificates
curl -fsSL "$url/caddy-deb.gpg" -o /usr/share/keyrings/caddy-deb.gpg
echo "deb [signed-by=/usr/share/keyrings/caddy-deb.gpg] $url stable main" > /etc/apt/sources.list.d/caddy-deb.list

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
