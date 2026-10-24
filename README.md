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
`dl.cloudsmith.io` at all. Debian's own, much older `caddy` may appear; its version is lower,
so apt does not choose it.

After that, Caddy updates come with `apt upgrade` or unattended-upgrades like any other
package. Configuration, service and paths are the same as with Caddy's package.

## How a new Caddy version gets here

1. Dependabot checks `go.mod` daily (05:17 Europe/Berlin) and opens a pull request when
   Caddy or a plugin has a new version.
2. The workflow builds the package and installs it in Debian 12, Debian 13 and
   Ubuntu 24.04 containers and on a runner VM with systemd, each time over Caddy's own
   package.
3. If all tests pass, the workflow merges the pull request and starts a run on `main`,
   which builds again, signs and publishes the repository on GitHub Pages, attaches the
   package to a GitHub release, and installs it from the published repository once more.

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

`scripts/build.sh` builds, `scripts/choose-package.sh` decides between the new and the
published package, `scripts/publish.sh` creates the signed repository and
`caddy-deb.sources`, `tests/install-test.sh` and `tests/repo-test.sh` are the tests.

## Signing key

The repository is signed with an ed25519 key. The public key is `caddy-deb.gpg` in this
repository and on the Pages site; the private key is only the repository secret
`APT_SIGNING_KEY`. `scripts/publish.sh` refuses to sign with a key that is not the one in
`caddy-deb.gpg`, and `caddy-deb.sources` embeds the same key. `tools/new-signing-key.sh`
creates a key, sets the secret and writes the public key; with a new key, the servers need
the new `caddy-deb.sources`.

## Limits

- amd64 only.
- The Pages site keeps only the newest package; every package also stays attached to its
  GitHub release.
- Right after a publish, GitHub Pages can serve old and new files for a short while; an
  `apt update` in that window may fail and work on the next try.

## Development

On the machine you commit from, activate the version guard once after cloning:
double-click `install-git-hooks.cmd` on Windows, or run `pwsh ./install-git-hooks.ps1`. It
copies `_git_hooks/pre-commit` into `.git/hooks`. The hook refuses a commit without a new
version section in `CHANGELOG.md`; that packaging version appears in the package
description. Dependabot's commits come from GitHub and are not affected.

## License

[Apache-2.0](LICENSE), like Caddy and caddyserver/dist, whose `main.go` and packaging
files this repository uses.
