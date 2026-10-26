#!/bin/sh
# openUF verify, device half: collect what tools/verify.py judges.
#
# verify.py pipes this over ssh (`sh -s`), after writing selfcheck.sh to
# /tmp/openuf-verify/. It can also be run by hand on the AP:
#   sh verify-collect.sh > /tmp/collect.txt
#
# Output is "### <section>" headers, each followed by raw lines. verify.py
# keys on the section names, so rename one only together with its parser.
#
# Read-only like selfcheck.sh: UCI, sysfs, logread, the status file and
# chosen state.json fields. state.json itself is never printed -- it holds
# the authkey -- only the fields named in STATE_KEYS. The unhandled ledger is
# summarised as category/key/count, without its (already redacted) payloads.

STATE=$(uci -q get openuf.main.state_file 2>/dev/null)
[ -n "$STATE" ] || STATE=/etc/openuf/state.json
STATE_KEYS="adopted backhaul_mode backhaul_pin backhaul_blacklist backhaul_seen
	uplinkmon_enabled uplinkmon_host uplinkmon_down sched_vaps_down
	guest_portal guest_authorized guest_vaps_down atf_enabled l2guard sta_rates"

echo "### now"
date +%s

echo "### board"
echo "board_name=$(cat /tmp/sysinfo/board_name 2>/dev/null)"
echo "model=$(cat /tmp/sysinfo/model 2>/dev/null)"
if [ -r /etc/openwrt_release ]; then
	. /etc/openwrt_release
	echo "release=$DISTRIB_DESCRIPTION"
fi

echo "### install"
# The headless install lives in /opt/openuf, the released package in
# /usr/lib/openuf; "never both" (CLAUDE.local.md section 5).
for d in /opt/openuf /usr/lib/openuf; do
	[ -f "$d/inform.lua" ] && echo "prefix=$d"
done
for d in /opt/openuf /usr/lib/openuf; do
	[ -r "$d/BUILD" ] && echo "build=$(cat "$d/BUILD")"
done
for d in /opt/openuf /usr/lib/openuf; do
	[ -r "$d/conf.lua" ] || continue
	m=$(sed -n 's/^dev = dofile("modelmap\/\(.*\)\.lua")$/\1/p' "$d/conf.lua")
	[ -n "$m" ] && echo "conf_modelmap=$m"
done
echo "uci_modelmap=$(uci -q get openuf.main.modelmap)"
if pgrep -f 'inform.lua' >/dev/null 2>&1 || ps w 2>/dev/null | grep -v grep | grep -q 'inform.lua'; then
	echo "daemon=running"
else
	echo "daemon=stopped"
fi

echo "### status"
cat /tmp/openuf-status 2>/dev/null

echo "### deps"
if lua -e 'local ok = pcall(require, "bit") or pcall(require, "bit32"); os.exit(ok and 0 or 1)' 2>/dev/null; then
	echo "bitlib=ok"
else
	echo "bitlib=missing"
fi
if grep -q wnm_sleep_mode /usr/sbin/hostapd 2>/dev/null; then echo "wpad=full"; else echo "wpad=basic"; fi

echo "### radios"
for p in /sys/class/ieee80211/*; do
	[ -d "$p" ] || continue
	phy=${p##*/}
	echo "$phy $(iw phy "$phy" info 2>/dev/null | grep -m1 'MHz' | sed 's/^[[:space:]]*//')"
done
uci -q show wireless 2>/dev/null | grep -E '^wireless\.[^.]+\.(band|hwmode|disabled)=' | grep -v 'openuf_'

echo "### leds"
ls /sys/class/leds 2>/dev/null

echo "### state"
for k in $STATE_KEYS; do
	OUF_FILE="$STATE" OUF_KEY="$k" lua -e '
		local ok, cjson = pcall(require, "cjson")
		if not ok then return end
		local f = io.open(os.getenv("OUF_FILE") or "") if not f then return end
		local okd, st = pcall(cjson.decode, f:read("*a")) f:close()
		if not okd or type(st) ~= "table" then return end
		local k = os.getenv("OUF_KEY") or ""
		local v = st[k]
		if v == nil or v == cjson.null then return end
		if type(v) == "table" then
			local out = {}
			for kk, x in pairs(v) do
				if type(kk) == "number" then out[#out + 1] = tostring(x)
				else out[#out + 1] = tostring(kk) end
			end
			table.sort(out)
			v = table.concat(out, " ")
		end
		print(k .. "=" .. tostring(v))
	' 2>/dev/null
done

echo "### unhandled"
OUF_FILE=/etc/openuf/unhandled.json lua -e '
	local ok, cjson = pcall(require, "cjson")
	if not ok then return end
	local f = io.open(os.getenv("OUF_FILE")) if not f then return end
	local okd, doc = pcall(cjson.decode, f:read("*a")) f:close()
	if not okd or type(doc) ~= "table" or type(doc.entries) ~= "table" then return end
	for _, e in pairs(doc.entries) do
		print(tostring(e.category) .. "\t" .. tostring(e.key) .. "\t" .. tostring(e.count)
			.. "\t" .. tostring(e.last_seen))
	end
' 2>/dev/null

echo "### log"
# Every daemon line carries one of these prefixes (io.stderr through procd),
# plus Lua's own "lua: <file>:<line>:" for an error that escaped a pcall.
logread 2>/dev/null \
	| grep -E '(inform|backhaul|uplinkmon|guestportal|ucihelper|unhandled|announce|stun|shaper|switchvlan|netconfig|bcfilter|l2guard|wlansched|sysconf): |lua: |traceback|AP-DISABLED|DFS-CAC|start_dfs_cac' \
	| tail -n 600

echo "### selfcheck"
if [ -r /tmp/openuf-verify/selfcheck.sh ]; then
	sh /tmp/openuf-verify/selfcheck.sh
	echo "selfcheck_rc=$?"
else
	echo "selfcheck_rc=missing"
fi
rm -rf /tmp/openuf-verify
echo "### end"
