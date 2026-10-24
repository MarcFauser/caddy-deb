# Sourced by scripts/choose-package.sh. Prints what makes up a caddy package apart from its
# version and description, so that two builds can be compared:
# - the build info of /usr/bin/caddy ("caddy build-info": Go version, every module with its
#   checksum, the build flags), without the lines that only describe this repository's
#   checkout: the main module's version and the "build vcs..." settings, which Go stamps
#   from the commit being built;
# - the checksum of every other file, except the man pages: Caddy generates them with
#   cobra, whose header carries the build date unless SOURCE_DATE_EPOCH is set
#   (cobra v1.10.2 doc/man_docs.go, lines 125-136), and they follow from the binary anyway;
# - the maintainer scripts and the conffiles list.

package_fingerprint()
{
    local deb="$1" dir file

    dir="$(mktemp -d)"
    dpkg-deb --extract "$deb" "$dir/data"
    dpkg-deb --control "$deb" "$dir/control"

    echo "== build info of /usr/bin/caddy"
    "$dir/data/usr/bin/caddy" build-info | grep -v -e '^mod[[:space:]]' -e '^build[[:space:]]vcs'

    echo "== files"
    (
        cd "$dir/data"
        find . \( -type f -o -type l \) ! -path './usr/bin/caddy' ! -path './usr/share/man/*' -print0 \
            | sort -z | xargs -0 sha256sum
    )

    echo "== maintainer scripts and conffiles"
    for file in preinst postinst prerm postrm conffiles
    do
        if [ -f "$dir/control/$file" ]
        then
            (cd "$dir/control" && sha256sum "$file")
        fi
    done

    rm -rf "$dir"
}
