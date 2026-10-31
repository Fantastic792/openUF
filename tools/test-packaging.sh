#!/bin/sh
# Tests for the packaging and installer shell code: the openuf package's
# maintainer scripts, install.sh, setup.sh, update.sh and the tools.
# usage: sh tools/test-packaging.sh      (from the repo root; exit 0 = all pass)
#
# Each case runs the SHIPPED code, extracted from its file, not a copy: a
# Makefile define has its $$ turned back into $, and absolute paths under
# /etc/ and /opt/ are rewritten into a scratch root, so nothing on the host is
# touched. uci, init scripts and package managers are stubs.

cd "$(dirname "$0")/.." || exit 2
PASS=0; FAIL=0
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT

ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
check() { # description, command...
	_d=$1; shift
	if "$@"; then ok; else bad "$_d"; fi
}

# A Makefile define block as the shell script the package carries.
mkdefine() { # makefile, define name
	awk -v d="define $2" '$0 == d { f = 1; next } f && $0 == "endef" { exit } f' "$1" \
		| sed 's/\$\$/$/g'
}
# Paths into the scratch root R.
reroot() {
	sed "s#/etc/#$R/etc/#g; s#/opt/#$R/opt/#g; s#/usr/bin/#$R/usr/bin/#g;
		s#/usr/sbin/#$R/usr/sbin/#g; s#/usr/lib/openuf#$R/usr/lib/openuf#g"
}

# A fresh scratch root with stub uci (a flat key=value file) and init scripts.
newroot() {
	R=$T/root.$1
	rm -rf "$R"; mkdir -p "$R/etc/init.d" "$R/etc/crontabs" "$R/bin" "$R/opt" \
		"$R/usr/bin" "$R/usr/sbin"
	: > "$R/uci"
	cat > "$R/bin/uci" <<EOF
#!/bin/sh
[ "\$1" = -q ] && shift
case "\$1" in
	get) grep -F "\$2=" "$R/uci" | head -1 | cut -d= -f2- | grep . ;;
	delete) grep -vF "\$2" "$R/uci" > "$R/uci.n"; mv "$R/uci.n" "$R/uci" ;;
	commit) echo "commit \$2" >> "$R/uci.log" ;;
	*) exit 0 ;;
esac
EOF
	for s in cron network; do
		printf '#!/bin/sh\necho "%s $1" >> "%s/init.log"\n' "$s" "$R" > "$R/etc/init.d/$s"
	done
	chmod +x "$R/bin/uci" "$R/etc/init.d/"*
	cat > "$R/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/ash
EOF
	echo 'root:::0:99999:7:::' > "$R/etc/shadow"
	echo 'root:x:0:' > "$R/etc/group"
	printf '/bin/ash\n' > "$R/etc/shells"
}
add_ubnt() { # gecos, shell
	echo "ubnt:x:900:900:$1:/etc/openuf:$2" >> "$R/etc/passwd"
	echo 'ubnt:!:::::::' >> "$R/etc/shadow"
	echo 'openuf:x:900:' >> "$R/etc/group"
	echo "$2" >> "$R/etc/shells"
}
has()   { grep -q "$1" "$2"; }
hasnt() { ! grep -q "$1" "$2"; }

# ── B1: the openuf package's preinst and prerm-pkg ─────────────────────────
MK=package/openuf/Makefile
run_prerm() { # env assignments...
	mkdefine "$MK" Package/openuf/prerm-pkg | reroot > "$R/prerm-pkg"
	# default_prerm sources it in a subshell and fails the removal on non-zero
	( PATH=$R/bin:$PATH; IPKG_INSTROOT=; PKG_UPGRADE=; for a in "$@"; do eval "$a"; done
	  . "$R/prerm-pkg" ) >/dev/null 2>&1
}
seed_shared() {
	add_ubnt "openuf bootstrap adoption" /usr/lib/openuf/hook/adopt-shell.sh
	printf '0 3 * * * mine\n# openuf-cron-begin -- x\n0 4 * * * syswrapper.sh\n# openuf-cron-end\n' \
		> "$R/etc/crontabs/root"
	printf 'network.openuf_ftveth=device\nnetwork.openuf_ftlink=interface\nnetwork.lan=interface\n' > "$R/uci"
}

newroot prerm; seed_shared
check "prerm-pkg returns 0" run_prerm
check "prerm removes the marked ubnt account" hasnt '^ubnt:' "$R/etc/passwd"
check "prerm removes ubnt from shadow" hasnt '^ubnt:' "$R/etc/shadow"
check "prerm removes the openuf group" hasnt '^openuf:' "$R/etc/group"
check "prerm removes the package's adoption shell" hasnt adopt-shell "$R/etc/shells"
check "prerm keeps /bin/ash in /etc/shells" has '^/bin/ash$' "$R/etc/shells"
check "prerm removes the cron block" hasnt syswrapper "$R/etc/crontabs/root"
check "prerm keeps the user's cron line" has mine "$R/etc/crontabs/root"
check "prerm restarts cron" has 'cron restart' "$R/init.log"
check "prerm removes the veth pair" hasnt openuf_ft "$R/uci"
check "prerm keeps other network sections" has network.lan "$R/uci"

newroot prerm-foreign
add_ubnt "a real admin" /bin/ash
check "prerm-pkg returns 0 (foreign ubnt)" run_prerm
check "prerm keeps a ubnt account openUF did not make" has '^ubnt:' "$R/etc/passwd"
check "prerm keeps its group" has '^openuf:' "$R/etc/group"

newroot prerm-upgrade; seed_shared
check "prerm-pkg returns 0 (upgrade)" run_prerm PKG_UPGRADE=1
check "an opkg upgrade keeps the account" has '^ubnt:' "$R/etc/passwd"
check "an opkg upgrade keeps the cron block" has syswrapper "$R/etc/crontabs/root"

newroot prerm-files; seed_shared
mkdir -p "$R/opt/openuf"; : > "$R/opt/openuf/inform.lua"
check "prerm-pkg returns 0 (file install present)" run_prerm
check "a file install keeps what it shares" has '^ubnt:' "$R/etc/passwd"

run_preinst() {
	mkdefine "$MK" Package/openuf/preinst | reroot > "$R/preinst"
	( IPKG_INSTROOT= sh "$R/preinst" ) >/dev/null 2>&1
}
newroot preinst
check "preinst passes on a clean device" run_preinst
mkdir -p "$R/opt/openuf"; : > "$R/opt/openuf/inform.lua"
check "preinst refuses beside a file install" eval '! run_preinst'
: > "$R/opt/openuf/.package-replaces"
check "preinst passes when setup.sh replaces the file install" run_preinst

# ── B20: install.sh uninstall removes only the ubnt account openUF made ────
run_install() { # args...
	reroot < install.sh > "$R/install.sh"
	( PATH=$R/bin:$PATH; sh "$R/install.sh" "$@" ) > "$R/out" 2>&1
}
fileinstall() {
	mkdir -p "$R/opt/openuf/hook"; : > "$R/opt/openuf/inform.lua"
}
newroot un-marked; fileinstall
add_ubnt "openuf bootstrap adoption" /opt/openuf/hook/adopt-shell.sh
check "uninstall runs" run_install uninstall
check "uninstall removes the marked ubnt account" hasnt '^ubnt:' "$R/etc/passwd"
check "uninstall removes its group" hasnt '^openuf:' "$R/etc/group"
check "uninstall removes its shell line" hasnt adopt-shell "$R/etc/shells"
check "uninstall removes /opt/openuf" test ! -e "$R/opt/openuf"

newroot un-foreign; fileinstall
add_ubnt "the admin" /bin/ash
echo 'openuf:x:901:' >> "$R/etc/group"
check "uninstall runs (foreign ubnt)" run_install uninstall
check "uninstall keeps a ubnt account openUF did not make" has '^ubnt:x:900' "$R/etc/passwd"
check "uninstall keeps its shadow line" has '^ubnt:' "$R/etc/shadow"
check "uninstall says why it kept it" has 'did not create it' "$R/out"
check "uninstall keeps a group openUF did not make" has '^openuf:x:901' "$R/etc/group"

# ── B7: setup.sh replaces a file install with install.sh uninstall ─────────
# With the package in, uninstall removes only /opt/openuf's own files.
newroot un-pkg; fileinstall
mkdir -p "$R/usr/lib/openuf/hook"; : > "$R/usr/lib/openuf/inform.lua"
printf '#!/bin/sh\necho "openuf $1" >> "%s/init.log"\n' "$R" > "$R/etc/init.d/openuf"
chmod +x "$R/etc/init.d/openuf"
ln -s ../lib/openuf/hook/syswrapper.sh "$R/usr/bin/syswrapper.sh"
: > "$R/usr/bin/openuf-update"
seed_shared
sed -i 's#:/usr/lib/openuf/hook/adopt-shell.sh$#:/opt/openuf/hook/adopt-shell.sh#' "$R/etc/passwd"
sed -i 's#^/usr/lib/openuf/hook/adopt-shell.sh$#/opt/openuf/hook/adopt-shell.sh#' "$R/etc/shells"
sed -i "s#/opt/#$R/opt/#" "$R/etc/passwd" "$R/etc/shells"
printf '/etc/openuf/\n%s/opt/openuf/conf.lua\n' "$R" > "$R/etc/sysupgrade.conf"
# setup.sh's own block, run with install.sh (rerooted) as $SRC/install.sh
mkdir -p "$R/src"; reroot < install.sh > "$R/src/install.sh"
awk '/install.sh.s uninstall, not a bare rm -rf/ { f = 1 } f { print } f && /^\tfi$/ { exit }' setup.sh \
	> "$R/block.sh"
check "setup.sh's block is found" grep -q 'install.sh uninstall' "$R/block.sh"
( ok() { echo "ok: $*"; }; warn() { echo "warn: $*"; }
  PATH=$R/bin:$PATH; SRC=$R/src; INSTALL_DIR=$R/opt/openuf; STATE_DIR=/etc/openuf; FILES_INSTALLED=1
  . "$R/block.sh" ) > "$R/out" 2>&1
check "setup.sh reports the removal" has '^ok: removed the file install' "$R/out"
check "the file install is gone" test ! -e "$R/opt/openuf"
check "its updater is gone" test ! -e "$R/usr/bin/openuf-update"
check "its sysupgrade line is gone" hasnt conf.lua "$R/etc/sysupgrade.conf"
check "the package's init script stays" test -x "$R/etc/init.d/openuf"
check "the package's service is not stopped" test ! -e "$R/init.log"
check "the package's link stays" test -L "$R/usr/bin/syswrapper.sh"
check "the cron block stays" has syswrapper "$R/etc/crontabs/root"
check "the veth pair stays" has openuf_ftveth "$R/uci"
check "the bootstrap account stays" has '^ubnt:' "$R/etc/passwd"
check "it moves onto the package's shell" has ":$R/usr/lib/openuf/hook/adopt-shell.sh$" "$R/etc/passwd"
check "the package's shell is registered" has "^$R/usr/lib/openuf/hook/adopt-shell.sh$" "$R/etc/shells"
check "the old shell line is gone" hasnt "/opt/openuf/hook" "$R/etc/shells"

# ── B4: install.sh's strip keeps the same files' comments as dist.sh ───────
newroot strip
D=$R/opt/openuf
mkdir -p "$D/lib" "$D/modelmap" "$D/ufmodel"
for f in conf.lua lib/x.lua modelmap/m.lua ufmodel/u.lua; do
	printf -- '-- title %s\nreturn 1\n' "$f" > "$D/$f"
done
awk '/^\t\tif \[ -f tools\/strip.lua \]/ { f = 1 } f { print } f && /^\t\tfi$/ { exit }' install.sh \
	> "$R/strip.sh"
( INSTALL_DIR=$D; . "$R/strip.sh" ) >/dev/null 2>&1
check "install.sh strips an ordinary module" hasnt title "$D/lib/x.lua"
check "install.sh keeps conf.lua's comments" has title "$D/conf.lua"
check "install.sh keeps a modelmap's comments" has title "$D/modelmap/m.lua"
check "install.sh keeps an identity's title (probe.lua reads it)" has title "$D/ufmodel/u.lua"
# Every file dist.sh keeps, install.sh keeps: same three patterns.
check "dist.sh keep_comments still lists ufmodel" grep -q 'openuf/ufmodel/\*' tools/dist.sh

# ── B2: downloads are verified, never insecure ─────────────────────────────
# A shell function, as the file defines it.
mkfunc() { # file, function name
	awk -v s="$2() {" '$0 == s { f = 1 } f { print } f && $0 == "}" { exit }' "$1"
}
for f in setup.sh update.sh; do
	check "$f has no --no-check-certificate fetch" eval "! grep -q -- '--no-check-certificate' $f"
	check "$f's verify helpers match setup.sh's" eval '[ "$(mkfunc '$f' check_sha256; mkfunc '$f' release_asset)" = "$(mkfunc setup.sh check_sha256; mkfunc setup.sh release_asset)" ]'
done
check "setup.sh never defaults to a moving branch" eval "! grep -q 'OPENUF_REF:-main' setup.sh"
check "update.sh never defaults to a moving branch" eval "! grep -q 'OPENUF_REF:-main' update.sh"
check "the documented install is a release, checked" grep -q "grep ' setup.sh\$' SHA256SUMS | sha256sum -c -" setup.sh

newroot sha
{ echo 'warn() { echo "warn: $*"; }'; mkfunc setup.sh sha256_of; mkfunc setup.sh check_sha256
  mkfunc setup.sh release_asset; } > "$R/f.sh"
mkdir -p "$R/rel"; echo good > "$R/rel/openuf-1.2.3.tar.gz"; echo pkg > "$R/rel/openuf_1.2.3-r1_all.ipk"
( cd "$R/rel" && sha256sum openuf-1.2.3.tar.gz openuf_1.2.3-r1_all.ipk > SHA256SUMS )
sumcheck() { ( . "$R/f.sh"; check_sha256 "$@" ) >/dev/null 2>&1; }
check "check_sha256 accepts a listed, matching file" sumcheck "$R/rel/openuf-1.2.3.tar.gz" "$R/rel/SHA256SUMS"
echo evil > "$R/rel/openuf_1.2.3-r1_all.ipk"
check "check_sha256 refuses a changed file" eval '! sumcheck "$R/rel/openuf_1.2.3-r1_all.ipk" "$R/rel/SHA256SUMS"'
echo x > "$R/rel/luci-app-openuf_1.ipk"
check "check_sha256 refuses an unlisted file" eval '! sumcheck "$R/rel/luci-app-openuf_1.ipk" "$R/rel/SHA256SUMS"'
check "check_sha256 refuses a missing list" eval '! sumcheck "$R/rel/openuf-1.2.3.tar.gz" "$R/rel/nope"'
printf '{"tag_name":"v1.2.3","assets":[{"browser_download_url":"https://x/d/v1.2.3/openuf-1.2.3.tar.gz"},{"browser_download_url":"https://x/d/v1.2.3/openuf-1.2.3.tar.gz.sha256"},{"browser_download_url":"https://x/d/v1.2.3/SHA256SUMS"}]}' \
	> "$R/rel.json"
check "release_asset finds the archive, not its .sha256" \
	eval '[ "$( . "$R/f.sh"; release_asset "$R/rel.json" "openuf-[0-9][-.0-9A-Za-z_]*\.tar\.gz" | head -1)" = https://x/d/v1.2.3/openuf-1.2.3.tar.gz ]'
check "release_asset finds SHA256SUMS" \
	eval '[ "$( . "$R/f.sh"; release_asset "$R/rel.json" SHA256SUMS)" = https://x/d/v1.2.3/SHA256SUMS ]'

# setup.sh's source download, its fetch a stub that serves $R/rel by name.
srcdl() { # 0 or 1: whether the archive is tampered with
	_r=$R/dl; rm -rf "$_r"; mkdir -p "$_r/rel/openuf-1.2.3/openuf"
	: > "$_r/rel/openuf-1.2.3/openuf/conf.lua"
	( cd "$_r/rel" && tar czf openuf-1.2.3.tar.gz openuf-1.2.3 && sha256sum openuf-1.2.3.tar.gz > SHA256SUMS )
	[ "$1" = 1 ] && echo tampered >> "$_r/rel/openuf-1.2.3.tar.gz"
	cp "$R/rel.json" "$_r/rel/release.json"
	awk '/^if \[ -n "\$SRC" \]; then$/ { f = 1 } f { print } f && /^fi$/ { exit }' setup.sh > "$_r/block.sh"
	( . "$R/f.sh"
	  die() { echo "die: $*"; exit 1; }; ok() { echo "ok: $*"; }; info() { :; }; head1() { :; }
	  fetch() { case "$1" in *api*) cp "$_r/rel/release.json" "$2" ;; *) cp "$_r/rel/$(basename "$1")" "$2" ;; esac; }
	  SRC=""; WORK=$_r/work; OPENUF_TARBALL_URL=""; OPENUF_BRANCH=""; OPENUF_TARBALL_SHA256=""
	  OPENUF_REPO=o/r; OPENUF_RELEASE_URL=https://api.github.com/repos/o/r/releases/latest
	  . "$_r/block.sh"; echo "SRC=$SRC" ) > "$_r/out" 2>&1
	# the block makes its own WORK, /tmp/openuf-setup-$$ (a subshell's $$ is ours)
	rm -rf "/tmp/openuf-setup-$$"
}
srcdl 0
check "setup.sh unpacks a release archive that matches" grep -q '^SRC=/tmp/openuf-setup-[0-9]*/openuf-1.2.3$' "$R/dl/out"
srcdl 1
check "setup.sh refuses an archive that does not match" grep -q '^die: the source archive does not match' "$R/dl/out"
check "and unpacks nothing" eval '! grep -q ^SRC= "$R/dl/out"'

# ── B3: update.sh's backup and rollback cover the init scripts and links ───
newroot rollback
mkdir -p "$R/opt/openuf" "$R/etc/openuf" "$R/etc/rc.d" "$R/tmp"
echo old > "$R/opt/openuf/inform.lua"; echo state > "$R/etc/openuf/state.json"
printf '#!/bin/sh\necho old-init "$1" >> "%s/init.log"\n' "$R" > "$R/etc/init.d/openuf"
chmod +x "$R/etc/init.d/openuf"
ln -s ../init.d/openuf "$R/etc/rc.d/S95openuf"
ln -s /opt/openuf/hook/syswrapper.sh "$R/usr/bin/syswrapper.sh"
awk '/^BACKUP=/ { f = 1 } f { print } f && /^}$/ { exit }' update.sh | reroot \
	| sed "s#-C / #-C $R/ #g; s#-C /\$#-C $R/#; s#\"/\\\$_p\"#\"$R/\$_p\"#g; s#cd / #cd $R/ #; s#/tmp/openuf-backup#$R/tmp/openuf-backup#" \
	> "$R/backup.sh"
if grep -qE '(-C /( |$)|"/\$_p"|cd / )' "$R/backup.sh"; then
	# never run a block that would back up or restore into the host's /
	bad "the rerooted backup block still names a host path"; : > "$R/backup.sh"
fi
( die() { echo "die: $*"; exit 1; }; ok() { :; }; warn() { :; }
  INSTALL_DIR=$R/opt/openuf
  . "$R/backup.sh"
  # the new version's install: a changed tree and init script, a new service
  echo new > "$R/opt/openuf/inform.lua"; echo new-only > "$R/opt/openuf/new.lua"
  printf '#!/bin/sh\necho new-init "$1" >> "%s/init.log"\n' "$R" > "$R/etc/init.d/openuf"
  printf '#!/bin/sh\n' > "$R/etc/init.d/openuf-rrb"; ln -s ../init.d/openuf-rrb "$R/etc/rc.d/S96openuf-rrb"
  restore_backup ) > "$R/out" 2>&1
check "the backup holds the init script" eval 'tar tzf "$R"/tmp/openuf-backup-*.tgz | grep -qx etc/init.d/openuf'
check "the backup holds the rc.d link" eval 'tar tzf "$R"/tmp/openuf-backup-*.tgz | grep -qx etc/rc.d/S95openuf'
check "the backup holds the command link" eval 'tar tzf "$R"/tmp/openuf-backup-*.tgz | grep -qx usr/bin/syswrapper.sh'
check "rollback restores the old tree" grep -qx old "$R/opt/openuf/inform.lua"
check "rollback drops the new version's files" test ! -e "$R/opt/openuf/new.lua"
check "rollback restores the old init script" grep -q old-init "$R/etc/init.d/openuf"
check "rollback restarts with the old init script" grep -q 'old-init restart' "$R/init.log"
check "rollback removes a service the new version added" test ! -e "$R/etc/init.d/openuf-rrb"
check "rollback removes its rc.d link" test ! -L "$R/etc/rc.d/S96openuf-rrb"
check "rollback keeps the old rc.d link" test -L "$R/etc/rc.d/S95openuf"
check "rollback keeps the command link" test -L "$R/usr/bin/syswrapper.sh"
check "rollback keeps the state" grep -qx state "$R/etc/openuf/state.json"

# ── B14: setup.sh's conf_set writes values with & | \ intact ───────────────
newroot confset
CONF=$R/conf.lua
printf 'config = {\n\tinform_url = "http://unifi:8080/inform",\n\tl2_announce = true,\n}\n' > "$CONF"
awk '/^\tconf_set\(\) \{/ { f = 1 } f { print } f && /^\t\}$/ { exit }' setup.sh > "$R/cs.sh"
cset() { ( die() { echo "die: $*"; exit 1; }; . "$R/cs.sh"; conf_set "$@" ) > "$R/out" 2>&1; }
for v in 'http://a/inform?x=1&y=2' 'http://a|b/inform' 'http://a/in\form' 'http://a/&&|\\'; do
	check "conf_set keeps $v" cset inform_url "\"$v\""
	check "conf_set wrote $v exactly" grep -qxF "	inform_url = \"$v\"," "$CONF"
done
check "conf_set leaves the other keys" grep -qxF '	l2_announce = true,' "$CONF"

# ── B5: the vendored translator carries its GPL text ───────────────────────
check "openuf/rrb/LICENSE is the repository's GPL-3.0 text" cmp -s openuf/rrb/LICENSE LICENSE
check "the package installs it beside the translator" \
	grep -q 'openuf/rrb/LICENSE \$(1)/usr/lib/openuf/rrb/' package/openuf/Makefile

# ── B6: hotpatch.sh also ships /etc/init.d/openuf-rrb when it differs ──────
# The "device" is a scratch root; OPENUF_SSH is a stub that runs the remote
# script locally with its paths rerooted and the service calls logged.
newroot hotpatch
D=$R/usr/lib/openuf
mkdir -p "$D/etc/init.d" "$R/tmp"
: > "$D/inform.lua"
echo old-rrb > "$R/etc/init.d/openuf-rrb"; cp "$R/etc/init.d/openuf-rrb" "$D/etc/init.d/openuf-rrb"
# what hotpatch ships is dist.sh's stripped tree; the openuf script is current
sh tools/dist.sh >/dev/null 2>&1
cp build/openuf/etc/init.d/openuf "$R/etc/init.d/openuf"
echo "last_ok=$(( $(date +%s) + 100 ))" > "$R/tmp/openuf-status"
cat > "$R/bin/ssh-stub" <<EOF
#!/bin/sh
shift
s=\$(printf '%s' "\$1" | sed \
	-e 's#/etc/init.d/openuf-rrb running#true#' \
	-e 's#/etc/init.d/openuf-rrb restart#echo rrb-restart >> $R/svc.log#' \
	-e 's#/etc/init.d/openuf restart#echo openuf-restart >> $R/svc.log#' \
	-e 's#\([ "(]\)/etc/#\1$R/etc/#g; s#\([ "(]\)/usr/lib/openuf#\1$R/usr/lib/openuf#g' \
	-e 's#\([ "(]\)/opt/#\1$R/opt/#g' \
	-e 's#/tmp/openuf-status#$R/tmp/openuf-status#g; s#sleep 3#:#')
exec sh -c "\$s"
EOF
chmod +x "$R/bin/ssh-stub"
( OPENUF_SSH=$R/bin/ssh-stub sh tools/hotpatch.sh testhost ) > "$R/out" 2>&1
check "hotpatch runs against the stub" grep -q 'testhost: done' "$R/out"
check "hotpatch ships the changed openuf-rrb script" cmp -s "$R/etc/init.d/openuf-rrb" build/openuf/etc/init.d/openuf-rrb
check "hotpatch keeps the old one inside the tree" grep -qx old-rrb "$D/etc/init.d/openuf-rrb.pre-hotpatch"
check "hotpatch says so" grep -q 'updated .*/etc/init.d/openuf-rrb$' "$R/out"
check "hotpatch restarts a running translator" grep -q rrb-restart "$R/svc.log"
check "an unchanged openuf script is left alone" eval '! grep -q "updated .*/etc/init.d/openuf\$" "$R/out"'
check "no stray backup in /etc/init.d" test ! -e "$R/etc/init.d/openuf-rrb.pre-hotpatch"

# ── B13: dist.sh keeps every executable bit ────────────────────────────────
sh tools/dist.sh >/dev/null 2>&1
_lost=""
for f in $(git ls-files -s openuf | awk '$1 == "100755" { print $4 }'); do
	[ -x "build/${f}" ] || _lost="$_lost $f"
done
check "dist.sh keeps every executable bit git records (lost:${_lost:- none})" test -z "$_lost"

# ── B9: PACKAGING.md's hard-deps row names the Makefile's DEPENDS ──────────
for _d in $(sed -n '/^  DEPENDS:=/,/^  PKGARCH/p' package/openuf/Makefile | sed 's/\\//g' | tr ' \t' '\n\n' | grep '^+'); do
	check "PACKAGING.md names $_d" grep -qF -- "$_d" PACKAGING.md
done

# ── B18: check.sh never prints the authkey ─────────────────────────────────
newroot b18
mkdir -p "$R/etc/openuf"
printf '{\n  "authkey": "0123456789abcdef0123456789abcdef",\n  "adopted": true\n}\n' > "$R/etc/openuf/state.json"
{ echo 'info() { echo "$*"; }'; grep 'state.json present' tools/check.sh | reroot; } > "$R/f.sh"
sh "$R/f.sh" > "$R/out" 2>&1
check "check.sh shows state.json" grep -q adopted "$R/out"
check "check.sh hides the authkey" eval '! grep -q 0123456789abcdef "$R/out"'

# ── B17: openuf-rrb.sh's pick_ssid keeps SSIDs with spaces whole ───────────
newroot b17
{ echo 'die() { echo "die: $*"; exit 2; }'
  echo 'unifi_records() { printf "h\tHome Wifi\nh\tOther\n"; }'
  echo 'owrt_sections() { [ "$1" = "Home Wifi" ] && echo s1; }'
  echo 'SSID='
  mkfunc openuf/hook/openuf-rrb.sh pick_ssid
  echo 'pick_ssid; echo "[$SSID]"'; } > "$R/f.sh"
check "pick_ssid picks 'Home Wifi' whole" eval '[ "$(sh "$R/f.sh")" = "[Home Wifi]" ]'

# ── B12: release-archive.sh stamps a fixed mtime, not "now" ────────────────
_line=$(grep '^MTIME=' tools/release-archive.sh)
check "release-archive.sh sets MTIME" test -n "$_line"
check "release-archive.sh passes MTIME to tar" grep -q -- '--mtime="@\$MTIME"' tools/release-archive.sh
check "MTIME honours SOURCE_DATE_EPOCH" eval '[ "$(SOURCE_DATE_EPOCH=12345; eval "$_line"; echo $MTIME)" = 12345 ]'
check "MTIME without it is the commit time, stable" eval '[ "$(unset SOURCE_DATE_EPOCH; eval "$_line"; echo $MTIME)" = "$(git log -1 --format=%ct)" ]'

# ── B15: verify.py's router.txt has its secret values redacted ─────────────
cat > "$T/rt.py" <<'PYEOF'
import sys
sys.path.insert(0, "tools")
import verify
raw = ("wireless.a.key='hunter2hunter2'\nwireless.a.ssid='Home'\n"
       "\toption psk 'abcdefgh1234'\n{\"authkey\": \"0123456789abcdef\", \"adopted\": true}\n"
       "x_passphrase=letmein99 ok\nadopted=1\n")
out = verify.redact_text(raw)
for leak in ("hunter2hunter2", "abcdefgh1234", "0123456789abcdef", "letmein99"):
    assert leak not in out, leak
for keep in ("ssid='Home'", "adopted=1", '"adopted": true'):
    assert keep in out, keep
PYEOF
check "verify.py redact_text hides secret values, keeps the rest" python3 "$T/rt.py"
check "verify.py writes router.txt through redact_text" grep -q 'f.write(redact_text(raw))' tools/verify.py

# ── B16: field_report.py also refuses MACs, LAN IPs, SSIDs and hostnames ───
_fr() { # a report whose first result's evidence is $1 -> checker exit status
	sed "s|^evidence = .*|evidence = \"$1\"|;" "$T/fr-base.toml" > "$T/fr.toml"
	python3 tools/field_report.py check "$T/fr.toml" >/dev/null
}
cat > "$T/fr-base.toml" <<'TOMLEOF'
format = 1
date = 2026-10-29
reporter = "x"
board = "b"
openwrt = "24.10"
openuf = "0.1"
controller = "c"
[[result]]
feature = "install"
outcome = "pass"
how = "installed"
evidence = "ok"
TOMLEOF
check "field_report accepts plain evidence" _fr "installed, joined"
check "field_report accepts the documentation masks" _fr "AP 192.0.2.7 00:00:5e:00:53:1a"
check "field_report refuses a LAN address" eval '! _fr "AP at 192.168.1.20"'
check "field_report refuses a 10/8 address" eval '! _fr "AP at 10.4.5.6"'
check "field_report refuses a MAC" eval '! _fr "client 3c:22:fb:12:34:56"'
check "field_report refuses a dashed MAC" eval '! _fr "client 3C-22-FB-12-34-56"'
check "field_report refuses an SSID" eval '! _fr "joined SSID = HomeNet"'
check "field_report refuses a quoted SSID" eval '! _fr "on SSID '"'"'HomeNet'"'"'"'
check "field_report refuses a hostname" eval '! _fr "hostname: myrouter"'
check "field_report refuses a .lan name" eval '! _fr "ssh to ap1.lan"'
check "the shipped field reports still validate" python3 tools/field_report.py check field-reports/*.toml

# ── B11: release.yml pins the SDK action and limits contents: write ────────
_rel=.github/workflows/release.yml
check "release.yml pins gh-action-sdk to a commit" grep -qE 'uses: openwrt/gh-action-sdk@[0-9a-f]{40}$' $_rel
check "release.yml: workflow permissions are read-only" eval "awk '/^permissions:/ { getline; print; exit }' $_rel | grep -q 'contents: read'"
check "release.yml: contents: write only inside jobs (3 upload jobs)" eval '[ "$(grep -c "contents: write" '$_rel')" = 3 ] && ! grep -q "^  contents: write" '$_rel
check "release.yml: the version job asks for no write" eval "! awk '/^  version:/,/^  verify:/' $_rel | grep -q 'contents: write'"

echo "test-packaging: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
