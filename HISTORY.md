# History

A narrative log of how this project came to be. The structured, versioned list of changes
lives in CHANGELOG.md; this file records the reasoning.

## 2026-10-24 - why there is an own repository

Caddy runs on several servers here with the Cloudflare DNS module for the ACME DNS
challenge. Caddy's Debian package contains only the standard modules, and
`caddy add-package` turns `/usr/bin/caddy` into a custom build, which the next
`apt upgrade` replaces with the stock binary again.

The first answer was a dpkg hook,
[dpkg-caddy-cloudflare-hook](https://github.com/MarcFauser/dpkg-caddy-cloudflare-hook):
after every dpkg run it ran `caddy add-package` again, before Caddy's postinst restarted
the service. It grew a fallback to the previous binary, retries through a systemd timer and
a login notice, because `add-package` depends on Caddy's build server, which has no SLA and
did not answer for hours in October 2026. In the end it was a working, well tested hack:
it wrote into a file that belongs to dpkg, behind dpkg's back, and depended on a command
Caddy marks as experimental and considers removing (caddyserver/caddy#7010; a maintainer
recommended building on one's own infrastructure instead, caddyserver/caddy#8129). Caddy's
maintainers do not consider the lost plugins a bug either: caddyserver/dist#106.

Caddy's documented alternative, `dpkg-divert` with `update-alternatives`, takes the binary
in use out of apt's hands altogether and leaves updates to `caddy upgrade`, which pins
plugin versions and downloads on every call. certbot instead of Caddy's own certificate
handling was rejected: Caddy is used precisely because it does that itself.

What remains clean is to package Caddy with the plugins oneself, the way Caddy packages
itself: Caddy's `main.go` with the plugin imports (its own comment describes this, no
xcaddy needed), the flags of its release build, the files from caddyserver/dist, nfpm.
Then apt manages exactly the binary that runs, and a version that does not build with the
plugins simply never reaches the servers. Three small projects already published such
packages, but they were stuck at Caddy 2.11.2 when 2.11.7 was current, and a web server
that holds the TLS keys should not run someone else's abandoned binary.

How new versions arrive was a choice between an own schedule and Dependabot. A schedule in
a public repository is switched off by GitHub after 60 days without activity and can be
delayed under load; Dependabot watches `go.mod` anyway. Its pull requests are merged by the
workflow once the tests pass. Because a push made with `GITHUB_TOKEN` starts no workflow,
the merge step starts the publishing run on `main` explicitly with `workflow_dispatch`,
and publishing happens only there: Dependabot's own runs do not get the Actions secrets,
so they could not sign anyway.

The repository on Pages keeps only the newest package; older ones stay in the GitHub
releases. The signing key is ed25519, created by the owner with `tools/new-signing-key.sh`
so that the private key never leaves GitHub's secret store and the owner's machine.

## 2026-10-25 - one source file, and no revision without a change

The first servers were set up with a one-line `caddy-deb.list` and a keyring in
`/usr/share/keyrings`. On Debian 13, `apt modernize-sources` (apt 2.9.26 and newer) converts
such files to the deb822 format and keeps the original as `.list.bak`; Caddy's own source had
gone that way on the first server. The owner asked whether this repository should not start
out in the new format. It should: a deb822 file can carry the public key in `Signed-By`
itself (apt 2.3.10 and newer, i.e. Debian 12 and Ubuntu 22.04 on), so a server needs one
download instead of two and there is no keyring file at all. That also settles where such a
file would belong: sources.list(5) puts keyrings added by the administrator into
`/etc/apt/keyrings`, while `/usr/share/keyrings` is for keyrings shipped by packages, which
is where the first instructions had put it. The old way keeps working; moving to the new
file means removing the old one first, because apt refuses two entries for the same
repository with different `Signed-By`.

Every run on `main` used to publish a new package revision, so a change to the README or a
script made every server download and restart Caddy for an identical binary. Version 1.0.4
stopped documentation-only pushes from running the workflow at all; 1.1.0 compares the
package itself. The binary cannot be compared byte by byte: Go stamps the commit it was
built from into it (`vcs.revision`, `vcs.time`, and the main module's version), so the
comparison uses `caddy build-info` without those lines. That still covers the Go version,
every module with its checksum and the build flags, so a newer Go or a changed dependency
still produces a new revision. The man pages are left out, because cobra writes the build
date into them unless `SOURCE_DATE_EPOCH` is set, and they follow from the binary anyway.
