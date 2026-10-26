#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# openuf rrb -- the 802.11r translator for genuine UniFi APs, from the shell.
# Adapted from d-malinowski's rrb-unifi-setup (unifi-openwrt-roaming 1.3, its
# collect/verify/peers; see rrb/README.md). install/apply/uninstall/confirm
# are openUF's job and are not here.
#
#   openuf rrb status             the service, the veth, what the daemon derives
#                                 from the running hostapd configs
#   openuf rrb peers              the UniFi peers: heard on the LAN (with the
#                                 WLAN's mobility domain once known), and listed
#                                 by hand in openuf.rrb
#   openuf rrb collect USER@HOST  read a UniFi AP's 802.11r settings over SSH
#                                 (dbclient; asks for its password). Optional:
#                                 the daemon learns the peers on its own
#   openuf rrb verify [--ssid S]  compare the collected UniFi data with openUF's
#                                 sections and the running hostapd
#   openuf rrb peers --write [--ssid S]
#                                 list the collected UniFi BSSes by hand in
#                                 openuf.rrb (list peer), for a site where the
#                                 daemon hears nothing; then Force Provision
#
# Collected data (it contains the FT key) stays in RAM: /tmp/openuf-rrb, mode
# 700. Only a SHA-256 of the WiFi password is read from the UniFi AP. Keys are
# never printed.
set -u

DIR=""
for d in /usr/lib/openuf /opt/openuf; do
	if [ -f "$d/inform.lua" ]; then DIR=$d; break; fi
done
INIT=/etc/init.d/openuf-rrb
DATA=/tmp/openuf-rrb
PEERS_FILE=/var/run/openuf/rrb-peers.json

SSID=""; WRITE=0; YES=0; ARGS=""
CMD=${1:-}; [ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
	case "$1" in
	--ssid) shift; [ $# -gt 0 ] || { echo "--ssid needs a value" >&2; exit 2; }; SSID=$1 ;;
	--write) WRITE=1 ;;
	--yes|-y) YES=1 ;;
	*) ARGS="$ARGS $1" ;;
	esac
	shift
done

say() { printf '%s\n' "$*"; }
die() { printf 'openuf rrb: %s\n' "$*" >&2; exit 2; }
fp() { [ -n "$1" ] && echo "$(echo "$1" | cut -c1-4)..." || echo "-"; }	# key fingerprint
nocolon() { echo "$1" | tr -d ':' | tr 'A-F' 'a-f'; }
lower() { echo "$1" | tr 'A-F' 'a-f'; }
sha() { printf %s "$1" | sha256sum | cut -d' ' -f1; }
ask() {		# ask "question" -> 0 if yes
	[ "$YES" = 1 ] && return 0
	printf '%s [y/N] ' "$1"
	read -r a
	[ "$a" = y ] || [ "$a" = Y ]
}

ft_if()   { uci -q get openuf.rrb.ft_iface 2>/dev/null || echo vft0; }
peer_if() { uci -q get openuf.rrb.peer_iface 2>/dev/null || echo vft1; }

ok=0; fix=0; fail=0
OK()   { ok=$((ok + 1));   say "  OK    $*"; }
FIX()  { fix=$((fix + 1)); say "  FIX   $*"; }
FAIL() { fail=$((fail + 1)); say "  FAIL  $*"; }
WARN() { say "  WARN  $*"; }

# ---------------------------------------------------------------- the peers the daemon heard

# One line per learned BSSID: "bssid md seen via" (md "-" while unknown).
learned() {
	[ -f "$PEERS_FILE" ] || return 0
	sed 's/},/}\n/g' "$PEERS_FILE" | sed -n 's/.*"\([0-9a-f:]\{17\}\)":{\(.*\)}.*/\1 \2/p' | while read -r b rest; do
		md=$(echo "$rest" | sed -n 's/.*"md":"\([0-9a-fA-F]\{4\}\)".*/\1/p')
		seen=$(echo "$rest" | sed -n 's/.*"seen":\([0-9]*\).*/\1/p')
		via=$(echo "$rest" | sed -n 's/.*"via":"\([a-z]*\)".*/\1/p')
		echo "$b ${md:--} ${seen:-0} ${via:--}"
	done
}

listed() { uci -q get openuf.rrb.peer 2>/dev/null | tr ' ' '\n' | sed '/^$/d'; }

cmd_peers_show() {
	say "UniFi APs heard on the LAN by the translator ($PEERS_FILE):"
	n=0; now=$(date +%s)
	learned | while read -r b md seen via; do
		age=$((now - seen)); [ "$seen" = 0 ] && age="?"
		printf '  %-18s wlan_id %-5s seen %ss ago via %s\n' "$b" "$md" "$age" "$via"
	done
	[ -s "$PEERS_FILE" ] || say "  none yet (a UniFi AP announces a client on every association; the daemon must be running)"
	say "Listed by hand (openuf.rrb list peer 'bssid,r0kh-id'):"
	l=$(listed); [ -n "$l" ] && echo "$l" | sed 's/^/  /' || say "  none"
	say "The key holders openUF writes are both, per WLAN by mobility domain (state.json rrb_peers)."
}

# ---------------------------------------------------------------- collect (UniFi side, read-only)

# Runs on the UniFi AP. Read-only. Prints the FT-enabled BSSes; for the
# WiFi password only its SHA-256.
REMOTE='
echo "host_name=$(uname -n)"
echo "fw=$(cat /etc/version 2>/dev/null)"
for f in /etc/hostapd/*.cfg; do
  grep -q "^wpa_key_mgmt=.*FT-" "$f" || continue
  ifn=$(sed -n "s/^interface=//p" "$f")
  echo "begin $f"
  echo "addr=$(cat /sys/class/net/$ifn/address 2>/dev/null)"
  echo "operstate=$(cat /sys/class/net/$ifn/operstate 2>/dev/null)"
  grep -E "^(interface|ssid|mobility_domain|ft_over_ds|nas_identifier|r0kh|r1kh|pmk_r1_push|ft_psk_generate_local|wpa|wpa_key_mgmt|wpa_pairwise|rsn_pairwise|ieee80211w)=" "$f"
  pp=$(sed -n "s/^wpa_passphrase=//p" "$f")
  [ -n "$pp" ] && echo "passphrase_sha256=$(printf %s "$pp" | sha256sum 2>/dev/null | cut -d" " -f1)"
  echo end
done
'

cmd_collect() {
	target=$(echo $ARGS | cut -d' ' -f1)
	[ -n "$target" ] || die "usage: openuf rrb collect USER@UNIFI_IP"
	command -v dbclient >/dev/null 2>&1 || die "dbclient (dropbear's ssh client) is not installed"
	host=${target#*@}
	mkdir -p "$DATA" && chmod 700 "$DATA"
	out=$DATA/unifi-$host.txt
	say "== Reading the UniFi AP $target (read-only). Enter its SSH password when asked."
	say "   (UniFi Network: Settings > System > Advanced > Device SSH Authentication)"
	umask 077
	{ echo "host=$host"; dbclient -T "$target" "$REMOTE"; } > "$out.tmp" || { rm -f "$out.tmp"; die "SSH to $target failed"; }
	grep -q '^begin ' "$out.tmp" || { rm -f "$out.tmp"; die "no 802.11r (FT) network found on $target: is Fast Roaming enabled?"; }
	mv "$out.tmp" "$out"
	say "Saved to $out (RAM, mode 600). UniFi BSSes with fast roaming:"
	unifi_records | while IFS='	' read -r h ssid ifn addr md ftds r0id key pmf akm ph oper; do
		printf '  %-10s %-16s ssid=%s md=%s key=%s %s\n' "$ifn" "$addr" "$ssid" "$md" "$(fp "$key")" "$oper"
	done
	say "Next: openuf rrb verify"
}

# All collected UniFi FT BSSes, tab separated:
# host ssid ifname bssid mdid ft_over_ds r0kh-id key pmf akm pass_sha256 operstate
unifi_records() {
	for f in "$DATA"/unifi-*.txt; do
		[ -f "$f" ] || continue
		awk '
		function out() {
			r0 = v["nas_identifier"]
			if (r0 == "$bssid" || r0 == "") { r0 = tolower(v["addr"]); gsub(":", "", r0) }
			printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", host, v["ssid"], v["interface"],
				tolower(v["addr"]), v["mobility_domain"], (v["ft_over_ds"] == "" ? "1" : v["ft_over_ds"]),
				r0, key, (v["ieee80211w"] == "" ? "0" : v["ieee80211w"]), v["wpa_key_mgmt"],
				v["passphrase_sha256"], v["operstate"]
		}
		/^host=/ { host = substr($0, 6); next }
		/^begin / { split("", v); key = ""; inb = 1; next }
		/^end$/ { if (inb) out(); inb = 0; next }
		inb {
			i = index($0, "="); if (!i) next
			k = substr($0, 1, i - 1); val = substr($0, i + 1)
			if (k == "r0kh") { n = split(val, a, " "); if (key == "") key = tolower(a[n]); else if (tolower(a[n]) != key) key = "MIXED" }
			else v[k] = val
		}' "$f"
	done
}

# ---------------------------------------------------------------- verify

# openUF's wifi-iface sections in AP mode with the SSID (the controller's,
# stamped openuf_wlanconf_id; hand-made ones are not openUF's to check).
owrt_sections() {
	for s in $(uci show wireless 2>/dev/null | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface$/\1/p'); do
		[ "$(uci -q get wireless.$s.ssid)" = "$1" ] || continue
		[ "$(uci -q get wireless.$s.mode)" = ap ] || continue
		[ "$(uci -q get wireless.$s.disabled)" = 1 ] && continue
		[ -n "$(uci -q get wireless.$s.openuf_wlanconf_id)" ] || continue
		echo "$s"
	done
}

sec_ifname() { ubus call network.wireless status 2>/dev/null | jsonfilter -e "@.*.interfaces[@.section='$1'].ifname" 2>/dev/null; }

# The peer entries openUF needs for the SSID: every UniFi BSS, "bssid,r0kh-id"
desired_peers() { for b in $U_BSSIDS; do echo "$b,$(r0id_of "$b")"; done; }
r0id_of() { unifi_records | awk -F'\t' -v s="$SSID" -v b="$1" '$2 == s && $4 == b { print $7; exit }'; }

# The values every openUF section must carry, derived from the UniFi data
desired() {	# desired SECTION BSSID -> lines "option value" / "list option value"
	echo "ieee80211r 1"
	echo "mobility_domain $U_MD"
	echo "ft_over_ds 0"
	echo "ft_psk_generate_local 0"
	echo "pmk_r1_push 1"
	echo "nasid $(nocolon "$2")"
	for b in $U_BSSIDS; do
		echo "list r0kh $b,$(r0id_of "$b"),$U_KEY"
		echo "list r1kh $b,$b,$U_KEY"
	done
	echo "list r0kh ff:ff:ff:ff:ff:ff,*,$U_KEY"
	echo "list r1kh 00:00:00:00:00:00,00:00:00:00:00:00,$U_KEY"
}

pick_ssid() {
	[ -n "$SSID" ] && return
	ssids=$(unifi_records | cut -f2 | sort -u)
	n=0; for x in $ssids; do [ -n "$(owrt_sections "$x")" ] && { SSID=$x; n=$((n + 1)); }; done
	[ $n -eq 1 ] || die "use --ssid NAME (UniFi fast-roaming SSIDs: $(echo $ssids))"
}

load_unifi() {
	ls "$DATA"/unifi-*.txt >/dev/null 2>&1 || die "no UniFi data; run: openuf rrb collect USER@UNIFI_IP"
	pick_ssid
	recs=$(unifi_records | awk -F'\t' -v s="$SSID" '$2 == s')
	[ -n "$recs" ] || die "SSID '$SSID' has no fast roaming on the UniFi side"
	U_BSSIDS=$(echo "$recs" | cut -f4 | sort -u)
	U_MD=$(echo "$recs" | cut -f5 | sort -u)
	U_KEY=$(echo "$recs" | cut -f8 | sort -u)
	U_FTDS=$(echo "$recs" | cut -f6 | sort -u)
	U_PMF=$(echo "$recs" | cut -f9 | sort -u)
	U_AKM=$(echo "$recs" | cut -f10 | sort -u)
	U_PASS=$(echo "$recs" | cut -f11 | sort -u)
	U_HOSTS=$(echo "$recs" | cut -f1 | sort -u)
}

check_unifi() {
	say "UniFi side ($(echo $U_HOSTS)), SSID '$SSID':"
	say "  BSSIDs: $(echo $U_BSSIDS)"
	[ $(echo "$U_MD" | wc -l) -eq 1 ] && [ -n "$U_MD" ] && OK "mobility domain $U_MD" || FAIL "UniFi BSSes disagree on the mobility domain: $(echo $U_MD)"
	[ $(echo "$U_KEY" | wc -l) -eq 1 ] && echo "$U_KEY" | grep -qE '^[0-9a-f]{32}([0-9a-f]{32})?$' \
		&& OK "FT key $(fp "$U_KEY") (same on all UniFi BSSes)" || FAIL "no single valid FT key in the UniFi r0kh lines"
	[ "$U_FTDS" = 0 ] && OK "UniFi ft_over_ds=0" || FAIL "UniFi uses FT over the DS (ft_over_ds=$U_FTDS); only over-the-air FT is supported"
	case "$U_AKM" in
	*FT-SAE*) U_AUTH=sae ;; *FT-PSK*) U_AUTH=psk ;; *) U_AUTH=other ;;
	esac
	[ "$U_AUTH" = other ] && FAIL "UniFi key management '$U_AKM' is not FT-PSK/FT-SAE"
}

check_section() {	# check_section SECTION
	s=$1
	ifn=$(sec_ifname "$s")
	bssid=$(lower "$(cat /sys/class/net/$ifn/address 2>/dev/null)")
	say "openUF wifi-iface '$s' (${ifn:-not up}, ${bssid:-no BSSID}):"
	# nothing here is changed by hand: openUF rewrites the section on every push
	SFIX() { FAIL "$* (written by openUF: check unifi_ft_interop and the peers, then Force Provision)"; }
	[ -n "$bssid" ] || { FAIL "$s: interface not up, can't read its BSSID"; return; }

	enc=$(uci -q get wireless.$s.encryption)
	case "$enc" in
	psk2*|psk-mixed*) o_auth=psk ;; sae-mixed*) o_auth=mixed ;; sae*) o_auth=sae ;; *) o_auth=other ;;
	esac
	if [ "$o_auth" = "$U_AUTH" ] || [ "$o_auth" = mixed ]; then OK "security: $enc matches UniFi ($U_AKM)"
	else FAIL "security: OpenWrt '$enc' vs UniFi '$U_AKM'; the controller sets both, so they should match"; fi

	pass=$(uci -q get wireless.$s.key)
	if [ -z "$U_PASS" ]; then WARN "UniFi password hash not available, password not compared"
	elif [ "$(sha "$pass")" = "$U_PASS" ]; then OK "WiFi password matches UniFi (compared as SHA-256)"
	else FAIL "WiFi password differs from UniFi's"; fi

	pmf=$(uci -q get wireless.$s.ieee80211w); [ -n "$pmf" ] || { [ "$o_auth" = sae ] && pmf=2 || { [ "$o_auth" = mixed ] && pmf=1 || pmf=0; }; }
	if [ "$pmf" = "$U_PMF" ]; then OK "802.11w (PMF) $pmf, same as UniFi"
	elif [ "$pmf" = 2 ] || [ "$U_PMF" = 2 ]; then FAIL "802.11w: OpenWrt $pmf vs UniFi $U_PMF; a 'required' side blocks roaming clients without PMF"
	else WARN "802.11w: OpenWrt $pmf vs UniFi $U_PMF"; fi

	desired "$s" "$bssid" > "$DATA/desired.$s"
	while read -r a b c; do
		if [ "$a" = list ]; then
			uci -q get wireless.$s.$b | tr ' ' '\n' | grep -qxF "$c" && OK "$b entry $(echo "$c" | cut -d, -f1-2),$(fp "$U_KEY")" || SFIX "$b entry missing: $(echo "$c" | cut -d, -f1-2),<key>"
		else
			cur=$(uci -q get wireless.$s.$a)
			[ "$cur" = "$b" ] && OK "$a=$b" || SFIX "$a=${cur:-<unset>} -> $b"
		fi
	done < "$DATA/desired.$s"
	for t in r0kh r1kh; do
		for e in $(uci -q get wireless.$s.$t); do
			grep -qxF "list $t $e" "$DATA/desired.$s" || WARN "$t entry not in the UniFi data (another UniFi AP, or a hand entry): $(echo "$e" | cut -d, -f1-2),<key>"
		done
	done
	opts=$(uci -q get wireless.$s.hostapd_bss_options)
	echo "$opts" | tr ' ' '\n' | grep -qxF "ft_iface=$(ft_if)" && OK "hostapd_bss_options ft_iface=$(ft_if)" || SFIX "hostapd_bss_options: ft_iface=$(ft_if) missing (is the veth up? openuf rrb status)"
}

check_peers() {	# the peers openUF knows = the UniFi BSSes
	say "UniFi peers openUF knows (heard on the LAN, or listed in openuf.rrb):"
	have=$( { learned | awk -v m="$U_MD" '$2 == m { print $1 "," $1 }' | sed 's/,\(.*\)$/,\1/' ; listed; } | sed '/^$/d' | sort -u)
	# a learned peer's R0KH-ID is its BSSID without colons (UniFi's convention)
	have=$(echo "$have" | awk -F, '{ r = $2; if (r ~ /:/) { gsub(":", "", r) }; print $1 "," r }' | sort -u)
	want=$(desired_peers | sort -u)
	if [ "$have" = "$want" ]; then OK "peers: $(echo $want)"
	else FIX "peers known: $(echo ${have:-<none>}) -> UniFi has: $(echo $want)  (wait for the daemon to hear them, or: openuf rrb peers --write)"; fi
}

check_system() {
	say "OpenWrt system:"
	[ -f "$DIR/rrb/rrb-unifi.uc" ] && OK "translator $DIR/rrb/rrb-unifi.uc" || FAIL "translator missing under $DIR/rrb (reinstall openUF)"
	[ -x "$INIT" ] && OK "$INIT" || FAIL "$INIT missing (reinstall openUF)"
	for ev in ucode-mod-socket:/usr/lib/ucode/socket.so; do
		[ -e "${ev#*:}" ] && OK "package ${ev%%:*}" || FAIL "package ${ev%%:*} missing (openuf deps --install)"
	done
	ls /lib/modules/*/veth.ko >/dev/null 2>&1 && OK "package kmod-veth" || WARN "kmod-veth not found as a module (built in, or missing: openuf deps --install)"
	ft=$(ft_if); peer=$(peer_if)
	if [ "$(cat /sys/class/net/$peer/iflink 2>/dev/null)" = "$(cat /sys/class/net/$ft/ifindex 2>/dev/null)" ] && [ -e /sys/class/net/$ft ]; then
		OK "veth $ft <-> $peer"
	else FAIL "veth $ft/$peer missing (openUF creates it on the first config push with an FT WLAN)"; fi
	[ -x "$INIT" ] && "$INIT" enabled && OK "service enabled" || FIX "service not enabled ($INIT enable)"
}

check_running() {	# running hostapd + translator
	say "Running state:"
	if [ -x "$INIT" ] && "$INIT" check >"$DATA/check.out" 2>&1; then
		OK "translator check: $(grep -c ' served' "$DATA/check.out") BSS served, LAN $(sed -n 's/^LAN interface: \([^ ]*\).*/\1/p' "$DATA/check.out")"
	else
		FAIL "translator check failed:"; sed 's/^/        /' "$DATA/check.out" 2>/dev/null
	fi
	"$INIT" running 2>/dev/null && OK "translator running" || FAIL "translator not running ($INIT start)"
	lan=$(sed -n 's/^LAN interface: \([^ ]*\).*/\1/p' "$DATA/check.out" 2>/dev/null)
	for h in $U_HOSTS; do
		ping -c1 -W1 "$h" >/dev/null 2>&1
		dev=$(ip neigh show "$h" | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
		[ -n "$dev" ] && [ "$dev" = "$lan" ] && OK "UniFi $h is on the same LAN ($dev)" || FAIL "UniFi $h is not a direct neighbor on $lan (dev ${dev:-none}); inter-AP messages need one layer-2 network"
	done
	for s in $(owrt_sections "$SSID"); do
		ifn=$(sec_ifname "$s")
		conf=$(grep -lE "^(interface|bss)=$ifn\$" /var/run/hostapd-*.conf 2>/dev/null | head -1)
		[ -n "$conf" ] || { FAIL "$s: no running hostapd config for $ifn"; continue; }
		ubus list "hostapd.$ifn" >/dev/null 2>&1 || { FAIL "$ifn: hostapd is not running this BSS (see logread -e hostapd)"; continue; }
		blk=$(awk -v i="$ifn" '/^(interface|bss)=/ { inb = ($0 == "interface=" i || $0 == "bss=" i) } inb' "$conf")
		md=$(echo "$blk" | sed -n 's/^mobility_domain=//p'); nas=$(echo "$blk" | sed -n 's/^nas_identifier=//p')
		n=$(echo "$blk" | grep -c '^r0kh=')
		[ "$md" = "$U_MD" ] && [ "$n" -gt 0 ] \
			&& OK "$ifn running: mobility_domain $md, nas_identifier ${nas:-<hostapd default>}, $n r0kh" \
			|| FAIL "$ifn running config differs from uci (md=$md nas=$nas r0kh=$n); wifi reload pending?"
	done
}

cmd_verify() {
	load_unifi
	check_unifi
	for s in $(owrt_sections "$SSID"); do check_section "$s"; done
	[ -n "$(owrt_sections "$SSID")" ] || FAIL "no enabled openUF AP interface with SSID '$SSID' (is the WLAN pushed to this AP?)"
	check_peers
	check_system
	[ $fix -eq 0 ] && [ $fail -eq 0 ] && check_running
	say ""
	say "Result: $ok OK, $fix to fix, $fail failed"
	[ $fail -gt 0 ] && { say "The FAIL items need a change in the controller, or a Force Provision once the peers are known."; return 2; }
	[ $fix -gt 0 ] && return 1
	say "Everything matches."
	return 0
}

# ---------------------------------------------------------------- peers --write

cmd_peers_write() {
	load_unifi
	check_unifi >/dev/null
	[ $fail -eq 0 ] || { check_unifi; die "UniFi data is not usable; nothing changed"; }
	want=$(desired_peers)
	have=$(listed)
	if [ "$(echo "$have" | sort)" = "$(echo "$want" | sort)" ]; then
		say "openuf.rrb peer already lists: $(echo $want)"; return 0
	fi
	say "openuf.rrb peer: $(echo ${have:-<none>})"
	say "            -> $(echo $want)"
	ask "Write this list to /etc/config/openuf (section rrb)?" || die "cancelled, nothing changed"
	uci -q get openuf.rrb >/dev/null 2>&1 || uci set openuf.rrb=rrb
	uci -q delete openuf.rrb.peer
	for p in $want; do uci add_list openuf.rrb.peer="$p"; done
	uci commit openuf
	say "Written. openUF uses it on its next config push: Force Provision the AP in UniFi."
}

cmd_status() {
	[ -n "$DIR" ] || die "openUF is not installed"
	if [ -x "$INIT" ]; then
		"$INIT" enabled && say "service   openuf-rrb enabled" || say "service   openuf-rrb NOT enabled"
		"$INIT" running && say "          running" || say "          not running"
	else
		say "service   $INIT missing (reinstall openUF)"
	fi
	ft=$(ft_if); peer=$(peer_if)
	[ -e /sys/class/net/$ft ] && [ -e /sys/class/net/$peer ] && say "veth      $ft <-> $peer" || say "veth      $ft/$peer not up (openUF creates it on the first config push with an FT WLAN)"
	say "peers     $(learned | wc -l | tr -d ' ') heard on the LAN, $(listed | wc -l | tr -d ' ') listed by hand (openuf rrb peers)"
	if [ -x "$INIT" ]; then
		say "-- $INIT check:"
		"$INIT" check 2>&1 | sed 's/^/  /'
	fi
}

case "$CMD" in
status)   cmd_status ;;
peers)    if [ "$WRITE" = 1 ]; then cmd_peers_write; else cmd_peers_show; fi ;;
collect)  cmd_collect ;;
verify)   cmd_verify ;;
*) sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
