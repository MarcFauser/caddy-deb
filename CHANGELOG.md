# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html). This is the version of the
packaging; the package version follows Caddy (`<caddy version>-<run number>`).

## [1.4.1] - 2026-11-07

### Fixed

- A failed publishing job could not be re-run. The Pages artifact of the first attempt stays
  in the run, the re-run uploaded a second one with the same name, and `deploy-pages` refused
  both ("Multiple artifacts named github-pages", build #14, which never published caddy
  2.11.9-14). The artifact is now named per attempt (`github-pages-<attempt>`) on both sides.
  No change to the package.

## [1.4.0] - 2026-11-07

### Changed

- Dependabot checks every day at 05:17 Europe/Berlin, weekends included (`interval: cron`).
  `interval: daily` runs Monday to Friday only, so Caddy 2.11.9 (out on a Thursday) would
  have waited for Monday.
- A new Caddy is taken without waiting; third-party plugins keep GitHub's default cooldown of
  3 days, now written out in `dependabot.yml`. Before, Caddy waited 3 days as well.

### Fixed

- The install test installed the newest of Caddy's own packages and then this package on
  top. Whenever Caddy had released and Dependabot still held the update back, that was a
  downgrade, apt refused it, and every build failed, as the weekly run did on 2026-11-06
  (2.11.7-11 over Caddy's 2.11.9). It now installs Caddy's own package of the same Caddy
  version and stops with a clear message if Caddy's repository does not offer it.
- The README said Dependabot checks daily, without saying that `daily` means weekdays.

## [1.3.1] - 2026-10-25

### Fixed

- The README said Caddy updates come with unattended-upgrades like any other package. They
  do not: Debian's default configuration only allows `origin=Debian`, and this repository is
  `Origin: caddy-deb`, so updates were only offered and waited for `apt upgrade`. A new
  section shows how to allow the repository in a file of its own
  (`/etc/apt/apt.conf.d/52unattended-upgrades-caddy-deb`, not the package's
  `50unattended-upgrades`) and how to check it with `unattended-upgrades --dry-run -d`.
  No change to the package or the workflow.

## [1.3.0] - 2026-10-25

### Added

- A weekly run (`weekly.yml`, Friday 04:37 UTC) starts the build on `main`, so a new Go
  release reaches the package within a week; before, it waited for the next Caddy or plugin
  update. The build publishes a new revision only if the package changed, which a new Go
  version does. It is a workflow of its own: GitHub disables a scheduled workflow after
  60 days without repository activity, and that must not stop the build with Dependabot's
  updates. The README says how to check and re-enable it.

## [1.2.0] - 2026-10-25

### Added

- The repository offers the current package and the four highest earlier versions
  (`KEEP_VERSIONS`), so a server can go back with `apt install caddy=<version>` and
  `apt-mark hold caddy` if the newest has a bug; the README describes it.
  `scripts/fetch-older.sh` takes them from the GitHub releases and checks each against the
  SHA-256 digest GitHub records and against its tag; it refuses a release higher than the
  package being published. The index page lists the earlier versions.
- The test of the published repository checks that apt offers exactly these versions, then
  goes back to the oldest, holds it through `apt-get upgrade`, releases the hold and upgrades
  to the newest again.

### Fixed

- `scripts/choose-package.sh` compared the new package with the first caddy entry of the
  published index. With several versions, `apt-ftparchive` lists them in file name order, so
  that would have been an older one; it now takes the highest version.

## [1.1.0] - 2026-10-25

### Added

- The Pages site offers `caddy-deb.sources`: the apt source in deb822 format with the
  signing key embedded in `Signed-By`, so a server needs one file and no keyring. The README
  sets up servers with it and says how to move from `caddy-deb.list` (which keeps working;
  `caddy-deb.gpg` stays on the site). The test of the published repository installs through
  it and checks that the embedded key is the key in `caddy-deb.gpg`.
- `scripts/choose-package.sh` compares the new package with the published one (Go version,
  modules with checksums, build flags, packaged files, maintainer scripts). If nothing
  changed, the published package stays and no new revision or GitHub release appears, so the
  servers neither install nor restart anything. A manual run can force a new revision with
  the `new_revision` input.

## [1.0.4] - 2026-10-25

### Fixed

- Removing Caddy's own repository used a fixed file name, `caddy-stable.list`. On Debian 13
  `apt modernize-sources` turns it into `caddy-stable.sources` (and keeps the old file as
  `.list.bak`), so the `rm` did nothing and the official repository stayed active, as found on
  the first server. The README now finds the repository by its address and ends with an
  `apt-cache policy caddy` check.

### Changed

- The Pages index page links to the README instead of repeating the instructions, so that a
  correction there does not need a new package.
- Pushes that change only README, HISTORY, CHANGELOG or LICENSE no longer run the workflow,
  so they publish no new package revision that the servers would install.

## [1.0.3] - 2026-10-25

### Changed

- The server instructions in the README and on the Pages index page are written as root,
  without `sudo` (not installed on a default Debian), and install `curl` and
  `ca-certificates` first, which minimal installations lack. The index page now also removes
  Caddy's own repository, like the README.

## [1.0.2] - 2026-10-24

### Fixed

- The test of the published repository failed although apt offered the right version:
  `apt-cache policy | grep -q` under `pipefail` fails when grep closes the pipe before
  apt-cache is done. The output is now captured first. `scripts/build.sh` read the
  packaging version with `sed | head`, which has the same race; it uses one `awk` now.

## [1.0.1] - 2026-10-24

### Fixed

- The install test failed in the ubuntu container: that image excludes man pages from
  installation (`path-exclude` in `/etc/dpkg/dpkg.cfg.d/`), so `dpkg --verify` reports
  them as missing. The test now leaves out man pages on such systems and says so.

## [1.0.0] - 2026-10-24

### Added

- `main.go`: Caddy's own `cmd/caddy/main.go` plus the Cloudflare DNS module; `go.mod` pins
  Caddy 2.11.7 and `github.com/caddy-dns/cloudflare` v0.2.4.
- `nfpm.yaml` and `scripts/build.sh`: a `caddy` package like Caddy's own, built with the
  flags of Caddy's release build, with man pages, bash completion and the files of
  caddyserver/dist; the build fails unless every plugin is in the binary.
- Workflow: build, install tests over Caddy's own package in Debian 12, Debian 13,
  Ubuntu 24.04 and on a runner VM with systemd, merge of Dependabot updates, signed apt
  repository on GitHub Pages, GitHub release, and an install test from the published
  repository.
- Dependabot for `go.mod`, daily.
- `tools/new-signing-key.sh` for the signing key.
