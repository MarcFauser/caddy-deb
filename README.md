# caddy-deb

[![build](https://github.com/MarcFauser/caddy-deb/actions/workflows/build.yml/badge.svg)](https://github.com/MarcFauser/caddy-deb/actions/workflows/build.yml)

An apt repository for Debian and Ubuntu with [Caddy](https://caddyserver.com) and the
plugins listed in [`main.go`](main.go), currently the
[Cloudflare DNS module](https://github.com/caddy-dns/cloudflare). The package replaces
Caddy's own package file by file, so apt manages the binary that actually runs: no
`caddy add-package`, no hooks, no build server.

## On a server

As root. If
[dpkg-caddy-cloudflare-hook](https://github.com/MarcFauser/dpkg-caddy-cloudflare-hook) is
installed, remove it first (`./install.sh --uninstall` in its folder).

**1. Add this repository.** The first line is for minimal installations, which have neither
curl nor always ca-certificates.

```bash
apt install curl ca-certificates
curl -fsSL https://marcfauser.github.io/caddy-deb/caddy-deb.sources -o /etc/apt/sources.list.d/caddy-deb.sources
```

`caddy-deb.sources` is one file in apt's deb822 format, the format `apt modernize-sources`
converts to, with the signing key embedded in `Signed-By`. No separate keyring file is
needed; apt reads embedded keys since 2.3.10 (Debian 12, Ubuntu 22.04 and newer). The
signing key's fingerprint is

```
6E579242465097B599FC9701FE8A040F3C7F97AD
```

and the file's second line names it. To check the embedded key itself (needs `gnupg`):

```bash
sed -n '/^Signed-By:/,$ { /^ /p }' /etc/apt/sources.list.d/caddy-deb.sources | sed -e 's/^ //' -e 's/^\.$//' | gpg --show-keys
```

*Set up before caddy-deb 1.1.0*, with `caddy-deb.list` and a keyring in
`/usr/share/keyrings`? Remove both first, then fetch the file as above:

```bash
rm /etc/apt/sources.list.d/caddy-deb.list /usr/share/keyrings/caddy-deb.gpg
```

Two entries for the same repository with different `Signed-By` make apt stop with
"Conflicting values set for option Signed-By". The old way keeps working, so there is no
hurry.

**2. Remove Caddy's own repository.** Otherwise apt takes a new official version without
plugins as soon as it is out and this repository's build is not yet. Its file name depends on
how it was set up (`caddy-stable.list`, or `caddy-stable.sources` after
`apt modernize-sources` on Debian 13), so look for its address:

```bash
grep -rl dl.cloudsmith.io/public/caddy /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null
```

(`/etc/apt/sources.list` does not exist on a fresh Debian 13; `2>/dev/null` hides that.)

Delete the `.list` and `.sources` files it names. apt reads no other files there; a
`.list.bak` left by `apt modernize-sources` is inactive and can go too. If
`/etc/apt/sources.list` itself is named, remove only the Caddy line from it.

**3. Install and check.**

```bash
apt update
apt install caddy
apt-cache policy caddy
```

`apt-cache policy caddy` must show the installed version from `marcfauser.github.io` and no
`dl.cloudsmith.io` at all. It also lists the earlier versions this repository offers (see
below). Debian's own, much older `caddy` may appear; its version is lower, so apt does not
choose it.

After that, Caddy updates come with `apt upgrade` or unattended-upgrades like any other
package. Configuration, service and paths are the same as with Caddy's package.

## Going back to an earlier version

The repository offers the current package and the four highest earlier versions
(`KEEP_VERSIONS` in the workflow), so a server can go back if the newest one has a bug. As
root, list them:

```bash
apt-cache madison caddy
```

Install the one you want and hold it:

```bash
apt install caddy=2.11.7-4
apt-mark hold caddy
```

apt lists the package under "DOWNGRADED" and asks before going ahead. The hold keeps
`apt upgrade` and unattended-upgrades from installing the newest version again. Once a fixed
version is out:

```bash
apt-mark unhold caddy
apt upgrade
```

Older versions stay attached to their
[GitHub releases](https://github.com/MarcFauser/caddy-deb/releases); install a downloaded one
with `apt install ./caddy_<version>_amd64.deb`. Caddy's own package is no way back: it lacks
the plugins, and Caddy refuses a configuration that uses a missing module ("module not
registered").

## How a new Caddy version or a new Go gets here

1. Dependabot checks `go.mod` daily (05:17 Europe/Berlin) and opens a pull request when
   Caddy or a plugin has a new version.
2. The workflow builds the package and installs it in Debian 12, Debian 13 and
   Ubuntu 24.04 containers and on a runner VM with systemd, each time over Caddy's own
   package.
3. If all tests pass, the workflow merges the pull request and starts a run on `main`,
   which builds again, signs and publishes the repository on GitHub Pages, attaches the
   package to a GitHub release, and installs it from the published repository once more,
   including going back to the oldest offered version and up again.

**A new Go** comes with the weekly run: `weekly.yml` starts the build on `main` every
Friday at 04:37 UTC (Go has released on Mondays to Thursdays since 2025). Every build takes
the newest stable Go, and Dependabot watches `go.mod`, not Go itself, so without this run a
new Go would wait for the next Caddy or plugin update. The Go version is part of the package
comparison below, so the weekly run publishes a new revision only when Go (or anything else
in the package) changed; in other weeks it publishes nothing.

Not waiting for the daily check: in the repository, *Insights → Dependency graph →
Dependabot → Recent update jobs → Check for updates*. To rebuild with the current
versions (for example to pick up a newer Go), run the workflow by hand: *Actions → build →
Run workflow*, or `gh workflow run build.yml --repo MarcFauser/caddy-deb`.

**A new package revision appears only when the package changed.** Every run on `main`
builds and tests, then compares the new package with the published one
(`scripts/choose-package.sh`): the Go version, every module with its checksum, the build
flags, every packaged file and the maintainer scripts. If they are the same, the published
package stays, the run only refreshes the repository files (index page, `caddy-deb.sources`,
signature), and the servers have nothing to install and restart. A change to the scripts,
the README or the workflow therefore costs the servers nothing. To publish a new revision
anyway, tick *new_revision* when running the workflow by hand, or
`gh workflow run build.yml --repo MarcFauser/caddy-deb -f new_revision=true`.

The package version is Caddy's plus the number of the run that built it, for example
`2.11.7-12`; runs that keep the published package leave gaps. Caddy's own package is
`2.11.7`, so this one sorts above it, and a newer build of the same Caddy version sorts
above an older one. A kept package still names the caddy-deb version that built it in its
description. If a new Caddy version does not build with a plugin (or with a future
Caddy v3), the tests fail, nothing is merged or published, and the servers keep the version
they run.

## Adding a plugin

Add its import to the plugin block in `main.go`, then

```bash
go get <module>@latest
go mod tidy
```

and open a pull request. The build fails unless every import in that block shows up in
`caddy list-modules --packages --skip-standard`.

## How it is built

The way Caddy describes it in its own `cmd/caddy/main.go`: copy `main.go`, add the module
imports, `go build`. The flags are those of Caddy's release build (`CGO_ENABLED=0`,
`-trimpath -mod=readonly -ldflags '-s -w' -tags nobadger,nomysql,nopgx`). Man pages and
bash completion are generated by the built binary, and the systemd units, the default
`Caddyfile`, the welcome page and the maintainer scripts come from
[caddyserver/dist](https://github.com/caddyserver/dist) at the commit in `DIST_REF` in the
workflow. [nfpm](https://nfpm.goreleaser.com) packages it (`nfpm.yaml`), following the
`nfpms` section of Caddy's `.goreleaser.yml`.

Go is the newest stable release at build time (`setup-go` with `go-version: stable` and
`check-latest: true`); `go.mod` only sets the minimum. `caddy build-info` on a server shows
the Go version and every module. A new Go release reaches the servers through the weekly run
(see above), at the latest a week later.

`scripts/build.sh` builds, `scripts/choose-package.sh` decides between the new and the
published package, `scripts/fetch-older.sh` fetches the earlier versions from the GitHub
releases (each checked against the digest GitHub records for it), `scripts/publish.sh`
creates the signed repository and `caddy-deb.sources`, `tests/install-test.sh` and
`tests/repo-test.sh` are the tests.

## Signing key

The repository is signed with an ed25519 key. The public key is `caddy-deb.gpg` in this
repository and on the Pages site; the private key is only the repository secret
`APT_SIGNING_KEY`. `scripts/publish.sh` refuses to sign with a key that is not the one in
`caddy-deb.gpg`, and `caddy-deb.sources` embeds the same key. `tools/new-signing-key.sh`
creates a key, sets the secret and writes the public key; with a new key, the servers need
the new `caddy-deb.sources`.

## Limits

- amd64 only.
- The Pages site keeps the newest package and the four highest earlier versions (18 MB
  each, against GitHub Pages' 1 GB per site); every package also stays attached to its
  GitHub release.
- Right after a publish, GitHub Pages can serve old and new files for a short while; an
  `apt update` in that window may fail and work on the next try.
- GitHub disables a scheduled workflow in a public repository after 60 days without
  repository activity. That can hit `weekly.yml` in a long stretch without Caddy or plugin
  updates; the build itself has no schedule and is not affected. Check with
  `gh workflow list --all --repo MarcFauser/caddy-deb`, switch it back on with
  `gh workflow enable weekly.yml --repo MarcFauser/caddy-deb`.
- If a run builds an older commit and a newer package is published meanwhile (a weekly run
  overtaken by a Caddy update), `scripts/fetch-older.sh` refuses to publish below it and the
  run fails without changing the repository.

## Development

On the machine you commit from, activate the version guard once after cloning:
double-click `install-git-hooks.cmd` on Windows, or run `pwsh ./install-git-hooks.ps1`. It
copies `_git_hooks/pre-commit` into `.git/hooks`. The hook refuses a commit without a new
version section in `CHANGELOG.md`; that packaging version appears in the package
description. Dependabot's commits come from GitHub and are not affected.

## License

[Apache-2.0](LICENSE), like Caddy and caddyserver/dist, whose `main.go` and packaging
files this repository uses.
