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
reroot() { sed "s#/etc/#$R/etc/#g; s#/opt/#$R/opt/#g"; }

# A fresh scratch root with stub uci (a flat key=value file) and init scripts.
newroot() {
	R=$T/root.$1
	rm -rf "$R"; mkdir -p "$R/etc/init.d" "$R/etc/crontabs" "$R/bin" "$R/opt"
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

echo "test-packaging: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
