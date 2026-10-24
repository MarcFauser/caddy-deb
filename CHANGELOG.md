# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html). This is the version of the
packaging; the package version follows Caddy (`<caddy version>-<run number>`).

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
