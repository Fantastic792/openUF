#!/bin/sh
# openUF self-check: is each feature the controller turned on actually in
# effect on this AP?
#
# Run on an adopted AP, AFTER install.sh, with openUF running:
#   sh tools/selfcheck.sh            -- every check
#   sh tools/selfcheck.sh mesh guest -- only the named groups
#
# Groups: deps daemon ppsk owe schedule speed blocker l2guard mesh uplinkmon
#         guest apname airtime
#
# Read-only: it reads UCI, state.json, nft, tc, iw, hostapd and sysfs, and
# sends at most one ping. It never writes or reloads anything.
#
# Each line is OK / FAIL / SKIP / INFO. SKIP means the controller has not
# turned that feature on here, so there is nothing to check -- not a pass.
# Many of these features are unit-tested only (README marks them ⚠️); this is
# the check that turns "unverified" into a yes or no on real hardware. Exit
# status is 1 when anything FAILed.

PASS=0
FAIL=0

ok()   { echo "  OK   $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP $1"; }
info() { echo "  INFO $1"; }
have() { command -v "$1" >/dev/null 2>&1; }

WANT="$*"
want() {
	[ -z "$WANT" ] && return 0
	for g in $WANT; do [ "$g" = "$1" ] && return 0; done
	return 1
}

STATE=$(uci -q get openuf.main.state_file 2>/dev/null)
[ -n "$STATE" ] || STATE=/etc/openuf/state.json

# One state.json field, printed plainly: a list as space-separated values, a
# table of tables as its keys, a boolean as true/false, nothing when absent.
# A dotted key ("l2guard.bpdu") walks into a table.
# Lua + cjson because openUF needs both anyway; jsonfilter is not always there.
# The path and key go in through the environment: `lua -e CODE ARG...` hands
# no ARG to CODE (it takes the first as a script file to run instead).
st_get() {
	OUF_FILE="$STATE" OUF_KEY="$1" lua -e '
		local ok, cjson = pcall(require, "cjson")
		if not ok then return end
		local f = io.open(os.getenv("OUF_FILE") or "") if not f then return end
		local okd, st = pcall(cjson.decode, f:read("*a")) f:close()
		if not okd or type(st) ~= "table" then return end
		local v = st
		for part in (os.getenv("OUF_KEY") or ""):gmatch("[^.]+") do
			if type(v) ~= "table" then v = nil; break end
			v = v[part]
		end
		if v == st then v = nil end
		if type(v) == "table" then
			local out = {}
			for k, x in pairs(v) do
				if type(k) == "number" then out[#out + 1] = tostring(x)
				else out[#out + 1] = tostring(k) end
			end
			table.sort(out)
			print(table.concat(out, " "))
		elseif v ~= nil and v ~= cjson.null then
			print(tostring(v))
		end
	' 2>/dev/null
}

# IFF_UP of a netdev: 0 up, 1 down, 2 absent.
link_up() {
	[ -r "/sys/class/net/$1/flags" ] || return 2
	flags=$(cat "/sys/class/net/$1/flags")
	[ $((flags & 1)) -eq 1 ] && return 0
	return 1
}

# The live netdev of a wifi-iface section, from netifd.
ifname_of() {
	ubus call network.wireless status 2>/dev/null | OUF_SEC="$1" lua -e '
		local ok, cjson = pcall(require, "cjson")
		if not ok then return end
		local okd, st = pcall(cjson.decode, io.read("*a"))
		if not okd or type(st) ~= "table" then return end
		for _, r in pairs(st) do
			for _, i in ipairs(type(r) == "table" and r.interfaces or {}) do
				if i.section == os.getenv("OUF_SEC") and i.ifname then print(i.ifname) return end
			end
		end
	' 2>/dev/null
}

# openUF's wifi-iface sections that carry option $1 (with value $2 if given).
sections_with() {
	uci -q show wireless 2>/dev/null | while IFS= read -r line; do
		sec=${line#wireless.}
		sec=${sec%%.*}
		opt=${line#wireless.$sec.}
		opt=${opt%%=*}
		val=${line#*=}
		val=$(echo "$val" | tr -d "'")
		[ "$opt" = "$1" ] || continue
		[ -n "$2" ] && [ "$val" != "$2" ] && continue
		echo "$sec"
	done | sort -u
}

echo "=== openUF self-check ($(date)) ==="

# ── Dependencies ────────────────────────────────────────────────────────────
if want deps; then
	echo ""
	echo "[ deps ]"
	if [ -d /sys/module/nft_meta_bridge ] || lsmod 2>/dev/null | grep -q '^nft_meta_bridge'; then
		ok "kmod-nft-bridge loaded (blocker, L2 hardening, guest portal)"
	else
		fail "kmod-nft-bridge not loaded -- the blocker and guest portal filter nothing without it"
	fi
	if [ -d /sys/module/ifb ] || lsmod 2>/dev/null | grep -q '^ifb'; then
		ok "kmod-ifb loaded (speed limit queues uploads)"
	else
		info "kmod-ifb not loaded -- upload speed limits fall back to policing"
	fi
	if have hostapd_cli; then ok "hostapd_cli present"; else fail "hostapd_cli missing (install hostapd-utils)"; fi
	# The daemon is usteerd, in /sbin on OpenWrt 25.12: looking for "usteer"
	# in /usr/sbin called an installed usteer missing.
	if have usteerd || have usteer || [ -x /sbin/usteerd ] || [ -x /usr/sbin/usteerd ]; then ok "usteer present (band steering, roaming assistant)"; else info "usteer not installed -- band steering and roaming assistant are off"; fi
	if hostapd -vsae >/dev/null 2>&1; then ok "hostapd has SAE (WPA3)"; else info "hostapd without SAE -- WPA3 WLANs are pushed as WPA2"; fi
fi

# ── The daemon ──────────────────────────────────────────────────────────────
if want daemon; then
	echo ""
	echo "[ daemon ]"
	if pgrep -f 'inform.lua' >/dev/null 2>&1 || ps w 2>/dev/null | grep -v grep | grep -q 'inform.lua'; then
		ok "openUF is running"
	else
		fail "openUF is not running (/etc/init.d/openuf start)"
	fi
	if [ -r "$STATE" ]; then
		if [ "$(st_get adopted)" = "true" ]; then ok "adopted"; else fail "not adopted yet"; fi
	else
		fail "no state file at $STATE"
	fi
	if [ -e /var/run/openuf.clock-ok ]; then
		ok "clock trusted (schedules and portal timestamps can work)"
	else
		info "clock not trusted yet -- WLAN schedules hold until the controller's time agrees"
	fi
fi

# ── Private pre-shared keys ─────────────────────────────────────────────────
if want ppsk; then
	echo ""
	echo "[ ppsk ]"
	vlans=$(uci -q show wireless 2>/dev/null | grep "=wifi-vlan$" | grep "^wireless.openuf_" | cut -d. -f2 | cut -d= -f1)
	if [ -z "$vlans" ]; then
		skip "no private pre-shared keys pushed"
	else
		for v in $vlans; do
			iface=$(uci -q get "wireless.$v.iface")
			name=$(uci -q get "wireless.$v.name")
			net=$(uci -q get "wireless.$v.network")
			dev=$(ifname_of "$iface")
			if [ -z "$dev" ]; then fail "$v: its SSID ($iface) is not up"; continue; fi
			vdev="$dev-$name"
			if [ ! -d "/sys/class/net/$vdev" ]; then
				fail "$v: VLAN netdev $vdev missing (dynamic_vlan / hostapd VLAN support?)"
			elif [ -e "/sys/class/net/$vdev/master" ]; then
				ok "$v: $vdev bridged into $(basename "$(readlink "/sys/class/net/$vdev/master")") (network $net)"
			else
				fail "$v: $vdev exists but is in no bridge -- its clients get no network"
			fi
		done
		info "the real test: join with one of the keys and check the client's address is on that VLAN"
	fi
fi

# ── Enhanced Open (OWE) ─────────────────────────────────────────────────────
if want owe; then
	echo ""
	echo "[ owe ]"
	secs=$(sections_with encryption owe | grep '^openuf_')
	if [ -z "$secs" ]; then
		skip "no Enhanced Open WLAN pushed"
	else
		for s in $secs; do
			dev=$(ifname_of "$s")
			if [ -z "$dev" ]; then fail "$s: not up"; continue; fi
			if hostapd_cli -i "$dev" get_config 2>/dev/null | grep -q 'key_mgmt=.*OWE'; then
				ok "$s ($dev): hostapd runs OWE"
			else
				fail "$s ($dev): hostapd does not report key_mgmt OWE"
			fi
			if [ "$(uci -q get "wireless.$s.owe_transition")" = "1" ]; then
				peer=$(ubus call hostapd bss_info "{\"iface\":\"$dev\"}" 2>/dev/null | grep -o '"owe_transition_ifname": *"[^"]*"' | cut -d'"' -f4)
				if [ -n "$peer" ] && link_up "$peer"; then
					ok "$s: transition mode, open BSS $peer up"
				else
					fail "$s: transition mode set but no open partner BSS is up"
				fi
			fi
		done
	fi
fi

# ── WLAN schedule ───────────────────────────────────────────────────────────
if want schedule; then
	echo ""
	echo "[ schedule ]"
	secs=$(sections_with openuf_schedule)
	held=$(st_get sched_vaps_down)
	if [ -z "$secs" ] && [ -z "$held" ]; then
		skip "no WLAN schedule pushed"
	else
		info "scheduled: $(echo $secs)"
		for n in $held; do
			if link_up "$n"; then fail "$n: the schedule holds it down, but it is up"; else ok "$n: held down by the schedule"; fi
		done
		[ -z "$held" ] && info "every scheduled WLAN is inside its on-time now"
	fi
fi

# ── WiFi speed limit ────────────────────────────────────────────────────────
if want speed; then
	echo ""
	echo "[ speed ]"
	secs=$( (sections_with openuf_ratelimit_down; sections_with openuf_ratelimit_up) | sort -u)
	if [ -z "$secs" ] && [ -z "$(st_get sta_rates)" ]; then
		skip "no speed-limit profile on any WLAN, and no per-client limit"
	elif ! have tc; then
		fail "tc missing (install tc-tiny or tc-full)"
	else
		for s in $secs; do
			dev=$(ifname_of "$s")
			[ -n "$dev" ] || { fail "$s: not up"; continue; }
			if tc qdisc show dev "$dev" 2>/dev/null | grep -q 'htb 1: root'; then
				n=$(tc class show dev "$dev" 2>/dev/null | grep -c 'class htb')
				ok "$s ($dev): download shaped, $n class(es)"
			else
				info "$s ($dev): no HTB root -- normal while nobody is connected"
			fi
			if tc qdisc show dev "$dev" 2>/dev/null | grep -q 'ingress'; then
				ok "$s ($dev): upload redirected or policed"
			fi
		done
		info "the real test: iperf3 from a client on the limited SSID, both ways"
	fi
fi

# ── Multicast and broadcast blocker ─────────────────────────────────────────
if want blocker; then
	echo ""
	echo "[ blocker ]"
	secs=$(sections_with openuf_bcfilt 1)
	if [ -z "$secs" ]; then
		skip "blocker off on every WLAN"
	else
		rules=$(nft list table bridge openuf_bcfilt 2>/dev/null)
		for s in $secs; do
			dev=$(ifname_of "$s")
			if echo "$rules" | grep -q "oifname \"$dev\".*drop"; then
				ok "$s ($dev): drop rule installed"
			else
				fail "$s ($dev): no drop rule (kmod-nft-bridge?)"
			fi
		done
		info "wireless clients need the DHCP server's MAC on the allow list, or they get no address"
	fi
fi

# ── ebtables hardening ──────────────────────────────────────────────────────
if want l2guard; then
	echo ""
	echo "[ l2guard ]"
	# l2guard.reconcile deletes the table when the spec asks for neither drop,
	# or while there is no AP netdev to put the rules on. Any l2guard state at
	# all used to read as "rules sent", so a site with both off FAILed.
	bpdu=$(st_get l2guard.bpdu)
	tagdrop=$(st_get l2guard.tagdrop)
	if [ -z "$(st_get l2guard)" ]; then
		skip "no ebtables block received yet"
	elif [ "$bpdu" != "true" ] && [ "$tagdrop" != "true" ]; then
		skip "the controller's ebtables block asks for no BPDU or VLAN-tag drop"
	elif nft list table bridge openuf_l2guard >/dev/null 2>&1; then
		ok "bridge openuf_l2guard installed (bpdu=$bpdu tagdrop=$tagdrop)"
	elif [ -z "$(st_get l2guard.ifnames)" ]; then
		info "rules wanted (bpdu=$bpdu tagdrop=$tagdrop) but no AP SSID is up yet -- deferred"
	else
		fail "the controller sent hardening rules but bridge openuf_l2guard is missing"
	fi
fi

# ── Wireless mesh ───────────────────────────────────────────────────────────
if want mesh; then
	echo ""
	echo "[ mesh ]"
	dl=$(sections_with openuf_backhaul downlink)
	ul=$(sections_with openuf_backhaul uplink)
	if [ -z "$dl" ] && [ -z "$ul" ]; then
		skip "no mesh pushed (site meshing off, or the device's mesh flag)"
	else
		mode=$(st_get backhaul_mode)
		info "uplink mode: ${mode:-wired}"
		for s in $dl; do
			dev=$(ifname_of "$s")
			ve=$(uci -q get "wireless.$s.vendor_elements")
			if [ -n "$dev" ] && link_up "$dev"; then ok "downlink $s ($dev) beaconing"; else info "downlink $s not up -- normal on a child whose station has not joined"; fi
			if echo "$ve" | grep -q '026f556f554602'; then ok "downlink carries the multi-hop path element"; else fail "downlink has no multi-hop path element (build before 2026-10-25?)"; fi
		done
		for s in $ul; do
			dev=$(ifname_of "$s")
			pin=$(uci -q get "wireless.$s.bssid")
			bl=$(uci -q get "wireless.$s.bssid_blacklist")
			[ -n "$pin" ] && info "parent pinned to $pin"
			[ -n "$bl" ] && info "never joins (own descendants): $bl"
			if [ "$mode" = "wireless" ]; then
				if [ -z "$dev" ]; then
					fail "on the wireless uplink but the station $s is not up"
				else
					if iw dev "$dev" info 2>/dev/null | grep -q '4addr: on'; then ok "$dev is a 4-address station"; else fail "$dev is not 4-address (wds)"; fi
					link=$(iw dev "$dev" link 2>/dev/null)
					if echo "$link" | grep -q '^Connected to'; then
						ok "joined $(echo "$link" | sed -n 's/^Connected to \([0-9a-f:]*\).*/\1/p'), signal $(echo "$link" | sed -n 's/.*signal: \(-*[0-9]*\).*/\1/p') dBm"
					else
						fail "station $dev has not joined a parent"
					fi
				fi
			else
				if [ "$(uci -q get "wireless.$s.disabled")" = "1" ]; then ok "station disabled while wired (no bridge loop)"; else fail "station enabled while on the wire -- a bridge loop"; fi
			fi
		done
		if logread 2>/dev/null | grep -q 'backhaul: joined .* a loop'; then
			fail "the log shows a mesh loop was broken -- look at: logread | grep backhaul"
		fi
	fi
fi

# ── Uplink connectivity monitor ─────────────────────────────────────────────
if want uplinkmon; then
	echo ""
	echo "[ uplinkmon ]"
	forced=$(uci -q get openuf.main.uplink_monitor)
	if [ "$(st_get uplinkmon_enabled)" != "true" ] && [ "$forced" != "1" ]; then
		skip "monitor off (site setting, or uplink_monitor)"
	else
		target=$(uci -q get openuf.main.uplink_monitor_host)
		[ -n "$target" ] || target=$(st_get uplinkmon_host)
		[ -n "$target" ] || target=$(ip -4 route show default 2>/dev/null | sed -n 's/^default via \([0-9.]*\).*/\1/p')
		held=$(st_get uplinkmon_down)
		if [ -z "$target" ]; then
			fail "no target to ping (no default route) -- the monitor holds whatever it had"
		elif ping -c 1 -W 2 "$target" >/dev/null 2>&1; then
			if [ -z "$held" ]; then ok "target $target answers, SSIDs on the air"; else fail "target $target answers but SSIDs are still held down: $held"; fi
		else
			if [ -n "$held" ]; then ok "target $target silent, SSIDs off the air: $held"; else info "target $target silent now -- the SSIDs go down after 5 failed checks"; fi
		fi
	fi
fi

# ── Guest portal ────────────────────────────────────────────────────────────
if want guest; then
	echo ""
	echo "[ guest ]"
	if [ -z "$(st_get guest_portal)" ]; then
		skip "no guest portal pushed"
	else
		if nft list table bridge openuf_guest >/dev/null 2>&1; then ok "bridge openuf_guest installed"; else fail "bridge openuf_guest missing"; fi
		if nft list table ip openuf_guest >/dev/null 2>&1; then ok "ip openuf_guest (HTTP redirect) installed"; else fail "ip openuf_guest missing (kmod-nft-nat?)"; fi
		if netstat -lnt 2>/dev/null | grep -q ':8820 '; then ok "portal answerer listening on 8820"; else fail "nothing listens on 8820 -- guests are blocked but see no portal"; fi
		info "authorized now: $(st_get guest_authorized)"
		down=$(st_get guest_vaps_down)
		[ -n "$down" ] && info "selfrun_guest_mode=off holds guest WLANs down: $down"
		info "the real test: join the guest SSID, open http://neverssl.com, log in, browse"
	fi
fi

# ── AP name in beacon ───────────────────────────────────────────────────────
if want apname; then
	echo ""
	echo "[ apname ]"
	found=0
	for conf in /var/run/hostapd-phy*.conf; do
		[ -r "$conf" ] || continue
		if grep -q '^vendor_elements=.*0050f204' "$conf"; then found=1; fi
	done
	secs=$(uci -q show wireless 2>/dev/null | grep '^wireless\.openuf_.*\.vendor_elements=.*0050f204' | cut -d. -f2)
	if [ -z "$secs" ]; then
		skip "\"Show Access Point Name in Beacon\" off"
	elif [ "$found" = "1" ]; then
		ok "hostapd beacons the name element ($(echo $secs))"
		info "the real test: a Wi-Fi scanner (WiFiman, Wireshark) shows the WPS Device Name"
	else
		fail "UCI has the name element but no hostapd config carries it"
	fi
fi

# ── Airtime fairness ────────────────────────────────────────────────────────
if want airtime; then
	echo ""
	echo "[ airtime ]"
	atf=$(st_get atf_enabled)
	if [ -z "$atf" ]; then
		skip "the controller has not set Airtime Fairness"
	else
		for f in /sys/kernel/debug/ieee80211/phy*/airtime_flags; do
			[ -r "$f" ] || { info "debugfs not mounted -- cannot read airtime_flags"; break; }
			phy=$(echo "$f" | cut -d/ -f6)
			if grep -q AIRTIME_TX "$f"; then on=true; else on=false; fi
			if [ "$on" = "$atf" ]; then ok "$phy: fairness $on, as the controller asked"; else fail "$phy: fairness $on, the controller asked $atf"; fi
		done
	fi
fi

echo ""
echo "=== $PASS OK, $FAIL FAIL ==="
[ "$FAIL" -eq 0 ]
