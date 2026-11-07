#!/bin/bash
# Installs the built package on a throwaway Debian or Ubuntu machine the way a server
# switches over: first Caddy's own package of the same Caddy version from Caddy's apt
# repository, then this package on top of it. Checks the version, the plugins, dpkg --verify, the files and, where
# systemd runs, that Caddy runs the new binary. Run as root, from the repository folder:
#   tests/install-test.sh out/caddy_<version>_amd64.deb
set -euo pipefail

cd "$(dirname "$0")/.."
. scripts/plugins.sh

deb="$(readlink -f "$1")"
expected="$(dpkg-deb --field "$deb" Version)"
export DEBIAN_FRONTEND=noninteractive
# needrestart (Ubuntu runner VM) would otherwise restart services of the runner
export NEEDRESTART_SUSPEND=1

step()
{
    echo
    echo "== $*"
}

fail()
{
    echo "FAIL: $*" >&2
    exit 1
}

# The same Caddy version, not the newest: the test is about replacing Caddy's package file by
# file. Whenever Caddy has released and Dependabot's cooldown still holds the update back, the
# newest one is higher than this package, installing this package on top is a downgrade, and
# apt-get -y refuses it (run 11, 2026-11-06: 2.11.7-11 over Caddy's 2.11.9).
upstream="${expected%-*}"
step "Caddy's own caddy $upstream from Caddy's apt repository (caddyserver.com/docs/install)"
apt-get update -q
apt-get install -y -q curl gnupg ca-certificates
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
apt-get update -q
# captured first: with pipefail, a reader that stops early can turn a hit into a miss
offered="$(apt-cache madison caddy)"
if ! awk -F'|' -v want="$upstream" '{ gsub(/[[:space:]]/, "", $2) } $2 == want { found = 1 } END { exit !found }' <<< "$offered"
then
    printf '%s\n' "$offered"
    fail "Caddy's repository does not offer caddy $upstream"
fi
apt-get install -y -q "caddy=$upstream"
[ "$(dpkg-query -W -f='${Version}' caddy)" = "$upstream" ] || fail "Caddy's own caddy $upstream is not installed"
echo "installed: caddy $(dpkg-query -W -f='${Version}' caddy)"

step "this package on top: $deb ($expected)"
apt-get install -y -q "$deb"

step "checks"
[ "$(dpkg-query -W -f='${Version}' caddy)" = "$expected" ] || fail "installed version is not $expected"
caddy version
check_plugins /usr/bin/caddy main.go || fail "a plugin is missing from /usr/bin/caddy"

# Minimized images (the ubuntu Docker image) tell dpkg not to install man pages; dpkg
# --verify then reports them as missing, for Caddy's own package just the same.
man_excluded=0
if grep -rqs '^path-exclude=/usr/share/man/' /etc/dpkg/dpkg.cfg.d/
then
    man_excluded=1
    echo "note: this system excludes /usr/share/man from installation (dpkg path-exclude)"
fi
verify="$(dpkg --verify caddy || true)"
if [ "$man_excluded" -eq 1 ]
then
    verify="$(grep -v ' /usr/share/man/' <<< "$verify" || true)"
fi
[ -z "$verify" ] || fail "dpkg --verify caddy: $verify"

files="/usr/bin/caddy /lib/systemd/system/caddy.service /lib/systemd/system/caddy-api.service
       /etc/caddy/Caddyfile /usr/share/caddy/index.html /etc/bash_completion.d/caddy"
if [ "$man_excluded" -eq 0 ]
then
    files="$files /usr/share/man/man8/caddy.8.gz"
fi
for f in $files
do
    [ -e "$f" ] || fail "$f is missing"
done
grep -qx '/etc/caddy/Caddyfile' /var/lib/dpkg/info/caddy.conffiles || fail "/etc/caddy/Caddyfile is not a conffile"
echo "version, plugins, files and dpkg --verify are fine"

if [ -d /run/systemd/system ]
then
    step "with systemd: the running Caddy is the new binary"
    systemctl is-active --quiet caddy || { systemctl status caddy --no-pager || true; fail "caddy is not active"; }
    pid="$(systemctl show -p MainPID --value caddy)"
    # /proc/PID/exe is the binary the process was started from
    check_plugins "/proc/$pid/exe" main.go || fail "the running caddy (PID $pid) lacks a plugin"
fi

echo
echo "install test passed"
