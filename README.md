# caddy-deb

[![build](https://github.com/MarcFauser/caddy-deb/actions/workflows/build.yml/badge.svg)](https://github.com/MarcFauser/caddy-deb/actions/workflows/build.yml)

An apt repository for Debian and Ubuntu with [Caddy](https://caddyserver.com) and the
plugins listed in [`main.go`](main.go), currently the
[Cloudflare DNS module](https://github.com/caddy-dns/cloudflare). The package replaces
Caddy's own package file by file, so apt manages the binary that actually runs: no
`caddy add-package`, no hooks, no build server. The same build for Windows comes as a zip
with an update script, see [On Windows](#on-windows).

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

After that, apt offers every Caddy update like any other package, and `apt upgrade` installs
it. Configuration, service and paths are the same as with Caddy's package.

## Automatic updates with unattended-upgrades

unattended-upgrades does **not** install packages from this repository on its own. Debian's
default configuration only allows Debian's own origins (`origin=Debian` with the label
`Debian` or `Debian-Security`), and this repository's Release file says
`Origin: caddy-deb`. The same was true for Caddy's own repository.

For automatic Caddy updates, allow the repository in a file of its own, as root. Do not edit
`50unattended-upgrades`: it belongs to the unattended-upgrades package, which merges it with
`ucf` on its updates. A second `Origins-Pattern` block adds to the list instead of replacing
it (apt.conf(5)).

```bash
cat > /etc/apt/apt.conf.d/52unattended-upgrades-caddy-deb <<'EOF'
Unattended-Upgrade::Origins-Pattern {
        "origin=caddy-deb,codename=stable";
};
EOF
```

Check it without installing anything:

```bash
unattended-upgrades --dry-run -d 2>&1 | grep -e 'Allowed origins' -e 'Packages that will be upgraded'
```

`Allowed origins are:` must list `origin=caddy-deb,codename=stable`; if a newer caddy is
waiting, `Packages that will be upgraded:` names it. unattended-upgrades has to be switched
on for any of this (`APT::Periodic::Unattended-Upgrade "1";`, usually in
`/etc/apt/apt.conf.d/20auto-upgrades`). Each update restarts a running Caddy (the package's
postinst runs `try-restart`, as in Caddy's own package).

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
`apt upgrade` and, if set up as above, unattended-upgrades from installing the newest version
again. Once a fixed
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

## On Windows

Every release also has `caddy_<version>_windows_amd64.zip`: the same build for Windows, with
Caddy's icon and the package version in the file properties (`2.11.9-16` as file version
2.11.9.16), plus `LICENSE`, `Update-Caddy.ps1` and `Update-Caddy.cmd`. The script installs
the newest release and restarts the Windows service; it needs
[PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)
(`pwsh`). The examples use `C:\caddy` and run in an elevated PowerShell 7.

**1. Unpack.** Download the zip of the newest
[release](https://github.com/MarcFauser/caddy-deb/releases/latest) (the release page shows
each file's SHA-256), then:

```powershell
Expand-Archive "$env:USERPROFILE\Downloads\caddy_2.11.9-16_windows_amd64.zip" C:\caddy
Get-ChildItem C:\caddy | Unblock-File
```

`Unblock-File` removes the browser's "downloaded from the internet" mark, which would make
Windows ask before running the files.

**2. Configure.** Put the `Caddyfile` into `C:\caddy`. As a service, Caddy runs as SYSTEM and
would keep certificates in that account's profile; to keep them next to Caddy, set the
storage in the global options:

```
{
	storage file_system C:/caddy/data
}
```

**3. Create the service.** Caddy runs as a Windows service by itself (Caddy's docs, "Windows
service"). A service gets environment variables, such as the Cloudflare token, from the
value `Environment` of its registry key:

```powershell
New-Service -Name caddy -DisplayName Caddy -StartupType Automatic -BinaryPathName '"C:\caddy\caddy.exe" run --config "C:\caddy\Caddyfile" --adapter caddyfile'
New-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\caddy -Name Environment -PropertyType MultiString -Value 'CLOUDFLARE_API_TOKEN=<token>'
Start-Service caddy
```

Who may read the token there is whoever may read that registry key (`Get-Acl`). A Windows
service cannot be reloaded; after changing the `Caddyfile`, run
`C:\caddy\caddy.exe reload --config C:\caddy\Caddyfile` (this needs the admin endpoint,
which is on by default).

**4. Updates.** A scheduled task runs the script every morning as SYSTEM, after Dependabot's
check:

```powershell
$action = New-ScheduledTaskAction -Execute "$env:ProgramFiles\PowerShell\7\pwsh.exe" -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\caddy\Update-Caddy.ps1'
$trigger = New-ScheduledTaskTrigger -Daily -At 06:30
$principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName 'Caddy update' -Action $action -Trigger $trigger -Principal $principal
```

The task calls `pwsh` directly: `Update-Caddy.cmd` is for a double click and waits for a key
when started through `cmd /c`, as the Task Scheduler starts it.

What the script does: it asks GitHub for the newest release, and if its `caddy.exe` is newer
than the installed one, downloads the zip, checks it against the SHA-256 digest GitHub
records, stops the service, swaps `caddy.exe` (the old one stays as `caddy.exe.previous`),
starts the service and checks that it runs. If it does not, the previous `caddy.exe` goes
back. A stopped service stays stopped, as with apt. It refuses to touch a service that runs
a `caddy.exe` from another folder, and a `caddy.exe` from its folder that runs outside the
service. Every run writes a line to `C:\caddy\update-caddy.log` (times in UTC); exit code 0
means installed or already current. `Get-Help C:\caddy\Update-Caddy.ps1 -Full` lists the
options, among them `-HealthUrl` for an address that must answer after the start. Once the
build is signed (see [Code signing](#code-signing)), the script also checks the signature of
the new `caddy.exe` before it runs or installs it.

The installed version is the file's own: `(Get-Item C:\caddy\caddy.exe).VersionInfo.FileVersion`.
A `caddy.exe` from elsewhere (Caddy's download page, or `caddy upgrade`, which fetches a build
with the same plugins from Caddy's build server) has a lower file version, without the
revision, and the next release replaces it.

**Going back:** stop the task (`Disable-ScheduledTask 'Caddy update'`), stop the service, put
`caddy.exe.previous` or the `caddy.exe` of an earlier release's zip in place and start the
service; enable the task again once a fixed version is out. The script updates only
`caddy.exe`; a newer `Update-Caddy.ps1` comes with the zip and is copied by hand.

## How a new Caddy version or a new Go gets here

1. Dependabot checks `go.mod` every day at 05:17 Europe/Berlin, weekends included, and
   opens a pull request when Caddy or a plugin has a new version. A new Caddy is taken the
   same morning; a new plugin version only after 3 days (`cooldown` in
   `.github/dependabot.yml`), a protection against a bad release of a small third-party
   module. Security updates are never held back.
2. The workflow builds the package and installs it in Debian 12, Debian 13 and
   Ubuntu 24.04 containers and on a runner VM with systemd, each time over Caddy's own
   package of the same Caddy version. On a Windows runner, `Update-Caddy.ps1` replaces
   Caddy's own `caddy.exe` of the same version in a real Windows service with the Windows
   build, and goes through refusals and a rollback (`tests/windows-test.ps1`).
3. If all tests pass, the workflow merges the pull request and starts a run on `main`,
   which builds again, signs the Windows build if code signing is set up, tests again, signs
   and publishes the repository on GitHub Pages, attaches the
   package and the Windows zip to a GitHub release, and installs it from the published
   repository once more, including going back to the oldest offered version and up again,
   and on Windows from the release.

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

The Windows build is the same `go build` with `GOOS=windows`. Like Caddy's own release (xcaddy
`internal/utils/resource.go`), it embeds Caddy's icon and a version resource with
[goversioninfo](https://github.com/josephspurrier/goversioninfo); the icon comes from xcaddy
at `XCADDY_REF` and is checked against `CADDY_ICO_SHA256`. The file version carries the
package revision, which Caddy's own has not.

Go is the newest stable release at build time (`setup-go` with `go-version: stable` and
`check-latest: true`); `go.mod` only sets the minimum. `caddy build-info` on a server shows
the Go version and every module. A new Go release reaches the servers through the weekly run
(see above), at the latest a week later.

`scripts/build.sh` builds, `scripts/choose-package.sh` decides between the new and the
published package, `scripts/fetch-older.sh` fetches the earlier versions from the GitHub
releases (each checked against the digest GitHub records for it), `scripts/publish.sh`
creates the signed repository and `caddy-deb.sources`, `tests/install-test.sh`,
`tests/repo-test.sh` and `tests/windows-test.ps1` are the tests, `windows/Update-Caddy.ps1`
is the update script for Windows, `scripts/pack-signed-windows.ps1` checks the signatures and
packs the signed Windows zip.

## Signing key

The repository is signed with an ed25519 key. The public key is `caddy-deb.gpg` in this
repository and on the Pages site; the private key is only the repository secret
`APT_SIGNING_KEY`. `scripts/publish.sh` refuses to sign with a key that is not the one in
`caddy-deb.gpg`, and `caddy-deb.sources` embeds the same key. `tools/new-signing-key.sh`
creates a key, sets the secret and writes the public key; with a new key, the servers need
the new `caddy-deb.sources`.

## Code signing

The workflow can sign `caddy.exe` and `Update-Caddy.ps1` with
[Azure Artifact Signing](https://learn.microsoft.com/azure/artifact-signing/) (formerly
Trusted Signing), through [azure/artifact-signing-action](https://github.com/Azure/artifact-signing-action).
The job `sign-windows` runs only in publishing runs on `main` and only once the variable
`ARTIFACT_SIGNING_PROFILE` is set; until then the Windows build stays unsigned, as now. The
signed zip goes through the same Windows test before it is released.

The login uses OpenID Connect: Azure trusts a token GitHub issues for this repository's
environment `code-signing`, and only `main` may use that environment. There is no password
or key in the repository, and a pull request cannot sign.

**In Azure** (with an Artifact Signing account whose identity validation is done):

1. A certificate profile of the type *Public Trust* for this repository. Its own profile
   gives it its own identity value (below); a profile shared with other software would let
   the update script accept that software's signature too. The certificate names the
   organisation or person of the identity validation behind the profile.
2. An app registration in Microsoft Entra ID with a federated credential: scenario *GitHub
   actions deploying Azure resources*, organisation `MarcFauser`, repository `caddy-deb`,
   entity type *Environment*, name `code-signing` (subject
   `repo:MarcFauser/caddy-deb:environment:code-signing`).
3. The role *Artifact Signing Certificate Profile Signer* for that app on the signing account
   (Access control (IAM)).

**On GitHub,** as the repository owner:

1. *Settings → Environments → New environment* `code-signing`; under *Deployment branches*,
   choose *Selected branches and tags* and add a rule for `main`.
2. The repository variables (not secrets; none of them is a credential):

```bash
gh variable set AZURE_TENANT_ID --repo MarcFauser/caddy-deb --body <directory (tenant) ID>
gh variable set AZURE_CLIENT_ID --repo MarcFauser/caddy-deb --body <application (client) ID>
gh variable set AZURE_SUBSCRIPTION_ID --repo MarcFauser/caddy-deb --body <subscription of the signing account>
gh variable set ARTIFACT_SIGNING_ENDPOINT --repo MarcFauser/caddy-deb --body <endpoint of the account's region>
gh variable set ARTIFACT_SIGNING_ACCOUNT --repo MarcFauser/caddy-deb --body <signing account name>
gh variable set ARTIFACT_SIGNING_PROFILE --repo MarcFauser/caddy-deb --body <certificate profile name>
```

The endpoint belongs to the region the account was created in, for West Europe
`https://weu.codesigning.azure.net` (the table in Microsoft's Artifact Signing quickstart
lists all of them). `ARTIFACT_SIGNING_PROFILE` switches signing on; deleting it switches it
off again.

**The first signed release:** run the workflow with *new_revision* (`gh workflow run build.yml
--repo MarcFauser/caddy-deb -f new_revision=true`): an unchanged package keeps its release,
and the zip with it. The servers get the same package once more, with one Caddy restart.

**Pinning the signer.** Artifact Signing renews its certificates daily, each valid for 72
hours, so neither a certificate nor its thumbprint stays the same. What stays is an EKU of
the form `1.3.6.1.4.1.311.97.<numbers>` that every certificate of one profile carries
(Microsoft, "Artifact Signing certificate management"). The signing job prints it in its
summary. Set it as the default of `-SignerEku` in `windows/Update-Caddy.ps1`; from the next
release on, the script in the zip installs only a `caddy.exe` with a valid, timestamped
signature from that profile, issued under Microsoft's root for Artifact Signing, and checks
that before it runs the file. Copy that `Update-Caddy.ps1` onto the Windows servers (the
script does not replace itself). A run that would publish an unsigned build with a pinning
script fails in the Windows test.

If the certificate profile is deleted and created again, it gets a new EKU: set the new one,
publish, and copy the script again; until then the servers refuse the updates and log why.
To install an unsigned build anyway, pass `-SignerEku ''`.

Check a signature on Windows:

```powershell
Get-AuthenticodeSignature C:\caddy\caddy.exe | Format-List Status, SignerCertificate, TimeStamperCertificate
```

## Limits

- amd64 only.
- On Windows, `caddy.exe` has no code signature until [code signing](#code-signing) is set
  up. Until then, what the update script installs is checked against the SHA-256 digest
  GitHub records for the release file, fetched over HTTPS from GitHub's API; that proves it
  is the file in this repository's release, not who built it.
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
