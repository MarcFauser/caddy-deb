#!/bin/bash
# Installs the built package on a throwaway Debian or Ubuntu machine the way a server
# switches over: first Caddy's own package from Caddy's apt repository, then this package
# on top of it. Checks the version, the plugins, dpkg --verify, the files and, where
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

step "Caddy's own package from Caddy's apt repository (caddyserver.com/docs/install)"
apt-get update -q
apt-get install -y -q curl gnupg ca-certificates
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
apt-get update -q
apt-get install -y -q caddy
echo "installed: caddy $(dpkg-query -W -f='${Version}' caddy)"

step "this package on top: $deb ($expected)"
apt-get install -y -q "$deb"

step "checks"
[ "$(dpkg-query -W -f='${Version}' caddy)" = "$expected" ] || fail "installed version is not $expected"
caddy version
check_plugins /usr/bin/caddy main.go || fail "a plugin is missing from /usr/bin/caddy"
verify="$(dpkg --verify caddy || true)"
[ -z "$verify" ] || fail "dpkg --verify caddy: $verify"
for f in /usr/bin/caddy /lib/systemd/system/caddy.service /lib/systemd/system/caddy-api.service \
         /etc/caddy/Caddyfile /usr/share/caddy/index.html /etc/bash_completion.d/caddy /usr/share/man/man8/caddy.8.gz
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
