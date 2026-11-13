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

## 2026-10-25 - earlier versions for going back

Until 1.2.0 the Pages site held only the newest package. If that one had a bug, a server
could only fetch an older `.deb` from the GitHub releases by hand. Caddy's own package is no
fallback: it lacks the plugins, and Caddy refuses a configuration that uses a missing module.
The owner asked for the last few versions in the repository itself; five it is, the current
one and four earlier, which costs about 90 MB of the 1 GB a Pages site may use.

The earlier packages come from the GitHub releases, not from the previous Pages site: the
releases are the permanent record, while the site only holds what the last run put there.
GitHub records a SHA-256 digest for every release asset, so each download is checked against
it and against its tag. A release higher than the package being published is refused, because
apt would then install that one instead. apt-ftparchive lists every package it finds in the
pool, several versions of the same package included (measured with 2.11.7-4 and 2.11.7-5; it
lists them in file name order), and apt offers all of them. That order also exposed a bug
before it could bite: `choose-package.sh` compared with the first caddy entry of the index,
which with several versions would have been an older one.

The repository test now walks through the way back exactly as the README describes it:
install the oldest offered version, hold it, check that `apt-get upgrade` keeps it, release
the hold and check that the upgrade brings the newest back. Non-interactively that needs
`--allow-downgrades`; interactively apt asks instead (apt-private/private-install.cc).

## 2026-10-25 - a weekly run for Go

Every build takes the newest stable Go, but nothing started a build when only Go changed:
Dependabot watches `go.mod`, not the Go releases, so a Go security fix waited for the next
Caddy or plugin update. An own schedule had been turned down at the start, when every run
published a new revision that every server installed. Since 1.1.0 a run publishes only when
the package changed, and the Go version is part of that comparison (`caddy build-info`
starts with it), so a weekly run costs the servers nothing in a week without a new Go.

Friday 04:37 UTC: the 54 Go releases since January 2025 came out on Tuesdays (25),
Thursdays (14), Wednesdays (11) and Mondays (4), so Friday morning catches each week's
release, and the minute keeps clear of the full hour, when GitHub delays scheduled runs.

The schedule lives in its own workflow, `weekly.yml`, which only starts `build.yml`. GitHub
disables a scheduled workflow in a public repository after 60 days without repository
activity, and a disabled workflow is not started by anything. In `build.yml` a quiet stretch
without Caddy or plugin updates would therefore also have stopped the builds of Dependabot's
next update; now it can stop only the weekly start.

## 2026-11-07 - Caddy 2.11.8 and 2.11.9, and three things that held them back

Caddy released 2.11.8 on 2026-11-04 and 2.11.9 a day later. Three days after that, neither
had arrived, for three separate reasons.

Dependabot applies a cooldown of 3 days to version updates by default, even with no
`cooldown` in the configuration (GitHub documents it; security updates are exempt). Its log
said so plainly: "Days since release: 0 (cooldown days: 3)". The waiting is counted in
seconds from the release date in the Go module proxy. For a small third-party plugin that
protection is worth having; for Caddy, which this repository exists to deliver, the owner
decided to take a new version the same morning. `exclude` does that per dependency;
`semver-patch-days: 0` would not have, because a 0 falls back to the default days.

`interval: daily` runs Monday to Friday only, which the README did not say and which was
assumed away when the arrival of 2.11.8 was predicted for a Saturday. Dependabot now runs on
a cron schedule, every day at 05:17.

And the weekly run on 2026-11-06 failed. The install test first installed the newest of
Caddy's own packages, which was 2.11.9 by then, and then this package, still 2.11.7, on top:
a downgrade, which `apt-get -y` refuses. The same would have blocked a Dependabot pull
request for 2.11.8 once Caddy's repository already had 2.11.9. The test is about replacing
Caddy's package file by file, so it now installs Caddy's package of the same version.

The run that was to publish 2.11.9 (build #14) then failed on GitHub's side: the Pages
deployment stayed at `syncing_files` for ten minutes and was cancelled. The error message asks
to re-run the deployment, and that cannot work here: a re-run keeps the earlier attempt's
artifact in the run, uploads a second one of the same name, and `deploy-pages` refuses two.
Since 1.4.1 each attempt names its own artifact. 2.11.9 comes from the next run instead, with
that run's number as its revision; revision 14 never existed outside build #14.

## 2026-11-13 - a Windows build, and how it updates itself

On 2026-11-13 the weekly run published 2.11.9-16 for nothing but Go 1.27.4, the case it was
built for. The same day the owner asked what a Windows build would take. Building is one more
`go build`; what makes it worth having is the update, because Windows has no apt that
replaces the file and restarts the service. The reason for this repository on Debian, apt
overwriting a binary that `caddy add-package` changed, does not exist on Windows: nothing
overwrites `caddy.exe` there. So the Windows build matters for a server that needs a plugin
such as the Cloudflare DNS module, and the update script for every Windows server.

The update script reads the installed version from `caddy.exe` itself. Caddy's own release
already embeds a version resource and Caddy's icon through xcaddy; this build does the same
with goversioninfo and puts the package revision into the fourth part of the file version.
The first draft left the icon out to keep it simple; the owner asked why, and with the
version resource in place the script needs no state file. A `caddy.exe` from Caddy's download
page or from `caddy upgrade` (which asks Caddy's build server for the newest Caddy with the
installed plugins) has a lower file version without the revision, so the next release
replaces it.

The script behaves like the Debian package where it can: it restarts only a running service
(`try-restart`), and it keeps the previous `caddy.exe` to go back to. Alternatives turned
down: winget would need a public pull request to `microsoft/winget-pkgs` for every version,
and neither winget nor Scoop stops a running service before replacing its program. The log
uses UTC, the owner's choice. The archive stays zip, as with Caddy's own Windows release: on a
41.8 MB Go binary, 7z came to 26 % of it against 36 % for zip, about 4 to 5 MB less for
`caddy.exe` per update, but PowerShell's `Expand-Archive` reads only zip, and whether older
Windows versions' `tar.exe` reads 7z was not measured. The script only replaces `caddy.exe`, not itself, so that a
broken script in a release cannot break the next update; a newer script is copied by hand.

The Windows test runs on a GitHub Windows runner, which is administrator and thrown away
afterwards, against a real service: it starts from Caddy's own `caddy.exe` of the same
version, as a server switching over would. `caddy.exe` has no code signature; the script
checks the zip against the SHA-256 digest GitHub records, which shows that it is the file in
this repository's release, not who built it. The owner has Azure code signing at the office;
signing is left for later.

## 2026-11-13 - code signing, prepared

The same day the owner asked to prepare the signing. Azure Trusted Signing is called Artifact
Signing now, and its GitHub action runs on Windows runners only, so the build stays on Linux
and a Windows job signs `caddy.exe` and `Update-Caddy.ps1` out of the built zip and packs it
again. The job logs in with OpenID Connect for the environment `code-signing`, which only
`main` may use; Azure trusts exactly that, so there is no secret, and a pull request, a
Dependabot one or one from a fork, cannot sign. Until the repository variables are set the
job is skipped and nothing changes. A skipped job made one more change necessary: with
GitHub's implicit `success()`, a skipped job also skips the jobs after it (actions/runner#491
and the documentation of `needs`), so every job after it now names the results it needs.

What a signature is checked against was the open question. Artifact Signing renews its
certificates daily and each is valid for 72 hours, so a thumbprint is useless; Microsoft gives
every certificate profile an EKU of its own, `1.3.6.1.4.1.311.97.<numbers>`, that stays for
the lifetime of the profile, and recommends pinning that. The update script now takes it as
`-SignerEku` and refuses a `caddy.exe` without a valid, timestamped signature carrying that EKU
and the Public Trust EKU, whose chain does not end in Microsoft Identity Verification Root
Certificate Authority 2020. The check runs before the new `caddy.exe` is executed for its
version.

Git for Windows signs `git.exe` with Artifact Signing, and that made the check testable without
an Azure account: on the runner and locally, `git.exe` in a zip passes the check with its own
profile and fails it with another, with one changed byte and without a signature. Its
certificate had expired two weeks before and the signature was still valid through its
timestamp, which is the state every signed `caddy.exe` reaches after three days.

The EKU is not known before the first signed build, so the default of `-SignerEku` stays empty
for now: the first signed release prints it, and committing it into the script is the step
that makes the servers refuse anything else. Signing an open-source project of the owner with
the identity behind the office's Artifact Signing account is the owner's decision; the
certificate names whoever was validated for the profile.
