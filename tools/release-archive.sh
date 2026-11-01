#!/bin/sh
# The source archive an OpenWrt package fetches: openuf-<version>.tar.gz.
#
#   sh tools/release-archive.sh 0.9.0
#
# Runs tools/dist.sh --verify first (tests, and the proof that the
# comment-stripped tree is bytecode-identical to the source), then packs that
# stripped tree under a single top-level directory openuf-<version>/, which is
# what the OpenWrt build system's default unpack expects for PKG_BUILD_DIR
# $(BUILD_DIR)/openuf-<version>. install.sh, setup.sh and update.sh ride along
# so the same archive serves a manual install -- which is why this is gzip, not
# xz: OpenWrt's busybox tar has no xz, and the feed rules accept gz. A .sha256
# is written for the package Makefile's PKG_HASH. The release workflow runs this on every
# tag; PKG_VERSION in package/openuf/Makefile is the same number.
set -e
VER=$1
case "$VER" in
	''|-*) echo "usage: sh tools/release-archive.sh <version>   (e.g. 0.9.0)" >&2; exit 2 ;;
esac
# X.Y.Z, or a test build X.Y.Z_beta1 (_alpha, _rc too): the forms apk's
# version order takes; it refuses -beta1. The tag reaches PKG_VERSION as is.
VER_RE='^[0-9]+(\.[0-9]+)*(_(alpha|beta|rc)[0-9]+)?$'
printf '%s\n' "$VER" | grep -Eq "$VER_RE" || {
	echo "release-archive: version must be X.Y.Z or X.Y.Z_alpha|_beta|_rcN, got '$VER'" >&2; exit 2; }

sh tools/dist.sh --verify

NAME=openuf-$VER
OUT=build/release/$NAME
rm -rf build/release
mkdir -p "$OUT"
cp -r build/openuf "$OUT/openuf"
printf '%s\n' "$VER" > "$OUT/openuf/VERSION"
cp install.sh setup.sh update.sh LICENSE NOTICE README.md REFERENCE.md USAGE.md "$OUT/"

rm -f "$NAME.tar.gz" "$NAME.tar.gz.sha256"
# The same tag gives the same bytes: the member mtime is SOURCE_DATE_EPOCH, else
# the commit's time, never "now" (a rebuild would change PKG_HASH).
MTIME=${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || date +%s)}
# --owner/--group are GNU tar; a BSD tar (macOS) has no such flags. The
# archive contents are the same either way; the workflow runs GNU tar.
if tar --version 2>/dev/null | grep -q GNU; then
	tar -C build/release --owner=0 --group=0 --sort=name --mtime="@$MTIME" \
		-czf "$NAME.tar.gz" "$NAME"
else
	tar -C build/release -czf "$NAME.tar.gz" "$NAME"
fi
if command -v sha256sum >/dev/null 2>&1; then
	sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256"
else
	shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256"
fi
echo ""
echo "$NAME.tar.gz  $(wc -c < "$NAME.tar.gz" | tr -d ' ') bytes"
cat "$NAME.tar.gz.sha256"
