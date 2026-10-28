-- Tests for openuf/backhaul.lua: the mesh backhaul plan, the wired-first
-- uplink policy and the wireless `uplink` report. No device access: every seam
-- is replaced.

local backhaul = dofile("openuf/backhaul.lua")

local MESH = {status = true, version = 3, essid = "vwire-5f3369181f7fbab5",
	psk = "0123456789abcdef0123456789abcdef", serial1 = "78:bb:c1:fe:3f:c9",
	connectivity = {status = true, uplink_eth = "eth0", uplink_wds = "ath4", uplink_bridge = "br0"}}
local ENTRIES = {
	{role = "downlink", radio = "radio1", ssid = "vwire-5f3369181f7fbab5",
		psk = "0123456789abcdef0123456789abcdef", devname = "vwire3", hidden = true},
	{role = "uplink", radio = "radio1", ssid = "vport-ac10076fc670", devname = "ath4", hidden = true},
}

-- A fake ucihelper: the two functions tick()/uplink_report() call.
local function fake_ufuci(sections, ifname, dl_sections)
	local f = {calls = {}}
	function f.backhaul_uplink_sections() return sections end
	function f.backhaul_downlink_sections() return dl_sections or {} end
	function f.ifname_for_section(name) return ifname end
	function f.backhaul_set_uplink_enabled(enabled)
		f.calls[#f.calls + 1] = enabled
		for _, s in ipairs(sections) do s.disabled = not enabled end
		return true
	end
	return f
end

-- The clock the seams give backhaul._time; a test moves it on.
local now = 1000

local function reset_policy()
	backhaul._down_since, backhaul._switched_at, backhaul._watch = nil, nil, nil
	backhaul._dirty = false
end

local function fake_sysinfo(port)
	return {
		lan_bridge = function() return "br-lan" end,
		uplink_bridge_port = function() return port end,
	}
end

-- A Deco M4R v1-shaped swconfig board: one CPU trunk (eth0, its LAN as
-- eth0.1 in br-lan), two sockets on physical switch ports 3 and 5.
local SWCFG = {
	net  = {lan_cpueth = "eth0", lan_vlanid = 1,
		ports = {{idx = 1, swport = "lan1"}, {idx = 2, swport = "lan2"}}},
	vlan = {device = "switch0", cpu_lan = 0, cpu_wan = 0, ports = {lan1 = 3, lan2 = 5}},
}

-- sysinfo for a swconfig board. sw.gw is the physical port the ARL has the
-- gateway on (nil: not learnt), sw.up the switch's per-port link, sw.fdb_port
-- the LAN bridge port the gateway is learnt behind.
local function fake_swsysinfo(sw)
	return {
		lan_bridge = function() return nil end,   -- the trunk is in no bridge itself
		bridge_of = function(ifname) if ifname == "eth0.1" then return "br-lan" end end,
		switch_status = function(dev)
			sw.status_calls = (sw.status_calls or 0) + 1
			local ports = {}
			for n, up in pairs(sw.up) do ports[n] = {up = up} end
			return {ports = ports, arl = {gw = sw.gw}}
		end,
		uplink_phys_port = function(arl) return arl.gw end,
		uplink_bridge_port = function()
			sw.fdb_calls = (sw.fdb_calls or 0) + 1
			return sw.fdb_port
		end,
	}
end

-- Seams for the swconfig tests: sysfs reads from `files`, `ls` from `dirs`,
-- every write and command recorded.
local function with_sw_seams(files, dirs, fn)
	local o = {backhaul._read_file, backhaul._popen, backhaul._log, backhaul._write_file, backhaul._exec, backhaul._time}
	local rec = {writes = {}, cmds = {}, logs = {}}
	now = 1000
	backhaul._time = function() return now end
	backhaul._read_file = function(path) return files[path] end
	backhaul._popen = function(cmd)
		local dir = cmd:match("^ls (%S+)$")
		return dir and dirs[dir] or ""
	end
	backhaul._log = function(msg) rec.logs[#rec.logs + 1] = msg end
	backhaul._write_file = function(path, v) rec.writes[#rec.writes + 1] = path .. "=" .. v; return true end
	backhaul._exec = function(cmd) rec.cmds[#rec.cmds + 1] = cmd; return 0 end
	reset_policy()
	backhaul._arl_heal = 0
	local ok, err = pcall(fn, rec)
	backhaul._read_file, backhaul._popen, backhaul._log, backhaul._write_file, backhaul._exec, backhaul._time =
		o[1], o[2], o[3], o[4], o[5], o[6]
	reset_policy()
	if not ok then error(err, 0) end
end

local function count(list, pattern)
	local n = 0
	for _, v in ipairs(list) do if v:find(pattern) then n = n + 1 end end
	return n
end

local function with_seams(carrier_by_port, popen_out, fn)
	local orig_read, orig_popen, orig_log, orig_time = backhaul._read_file, backhaul._popen, backhaul._log, backhaul._time
	now = 1000
	backhaul._time = function() return now end
	backhaul._read_file = function(path)
		local port, what = path:match("^/sys/class/net/([^/]+)/(%w+)$")
		if port and (what == "carrier" or what == "operstate") then
			local c = carrier_by_port[port]
			if c == nil then return nil end
			if what == "operstate" then return c and "up\n" or "lowerlayerdown\n" end
			return c and "1\n" or "0\n"
		end
		local stat = path:match("/statistics/([a-z_]+)$")
		if stat then return ({tx_bytes = "1000", rx_bytes = "2000", tx_packets = "10", rx_packets = "20"})[stat] end
		return nil
	end
	backhaul._popen = function() return popen_out or "" end
	backhaul._log = function() end
	reset_policy()
	local ok, err = pcall(fn)
	backhaul._read_file, backhaul._popen, backhaul._log, backhaul._time = orig_read, orig_popen, orig_log, orig_time
	reset_policy()
	if not ok then error(err, 0) end
end

-- Seams for heal_wds_moves(): `bridge fdb show` answers from fdb.out, the
-- clock from fdb.now, every command and log line recorded.
local function with_fdb_seams(fdb, fn)
	local o = {backhaul._popen, backhaul._exec, backhaul._log, backhaul._time, backhaul._read_file}
	local rec = {cmds = {}, logs = {}}
	backhaul._popen = function(cmd)
		if cmd == "bridge fdb show" then return fdb.out or "" end
		return ""
	end
	backhaul._exec = function(cmd) rec.cmds[#rec.cmds + 1] = cmd; return 0 end
	backhaul._log = function(msg) rec.logs[#rec.logs + 1] = msg end
	backhaul._time = function() return fdb.now or 1000 end
	backhaul._read_file = function() return nil end
	local function reset()
		backhaul._wds_hosts, backhaul._wds_ports, backhaul._window_healed = {}, {}, {}
		backhaul._heal_window = 0
	end
	reset()
	local ok, err = pcall(fn, rec)
	backhaul._popen, backhaul._exec, backhaul._log, backhaul._time, backhaul._read_file =
		o[1], o[2], o[3], o[4], o[5]
	reset()
	if not ok then error(err, 0) end
end

return {
	{
		name = "backhaul: heal_wds_moves() rewrites the switch entry of a host the mesh link carried, once it is wired",
		fn = function()
			local fdb = {}
			with_fdb_seams(fdb, function(rec)
				local si = fake_sysinfo("wan")
				-- On the parent, mid-mesh: the PC behind the child's WDS station,
				-- a VLAN host behind it too, a phone on the parent's own AP.
				fdb.out = table.concat({
					"c8:7f:54:06:03:0a dev phy1-ap1.sta1 master br-lan ",
					"02:00:00:00:00:20 dev phy1-ap1.sta1 vlan 20 master br-openuf20 ",
					"02:00:00:00:00:99 dev phy1-ap0 master br-lan ",
					"08:bf:b8:71:c0:31 dev wan master br-lan ",
					"08:bf:b8:71:c0:31 dev wan self ",
					"33:33:00:00:00:01 dev phy1-ap1.sta1 master br-lan permanent",
				}, "\n")
				assert_eq(backhaul.heal_wds_moves({}, si, nil), 0, "nothing moved yet")
				assert_eq(#rec.cmds, 0, "no commands mid-mesh")

				-- The child's cable is back: the WDS port is gone, the PC turns up
				-- behind the parent's wan, the phone roams onto a cable too.
				fdb.out = table.concat({
					"c8:7f:54:06:03:0a dev wan master br-lan ",
					"02:00:00:00:00:20 dev lan2 vlan 20 master br-openuf20 ",
					"02:00:00:00:00:99 dev lan1 master br-lan ",
				}, "\n")
				assert_eq(backhaul.heal_wds_moves({}, si, nil), 2, "the two hosts the mesh link carried")
				assert_eq(rec.cmds[1], "bridge fdb replace c8:7f:54:06:03:0a dev wan master static >/dev/null 2>&1", "pin")
				assert_eq(rec.cmds[2], "bridge fdb del c8:7f:54:06:03:0a dev wan master >/dev/null 2>&1", "unpin")
				assert_eq(rec.cmds[3], "bridge fdb replace 02:00:00:00:00:20 dev lan2 vlan 20 master static >/dev/null 2>&1",
					"the VLAN bridge's host keeps its VLAN")
				assert_eq(#rec.cmds, 4, "the phone was never behind a WDS port: untouched")
				assert_true(rec.logs[1]:find("c8:7f:54:06:03:0a on wan", 1, true) ~= nil, "logged")

				-- Once only: the next heartbeat leaves the relearnt entries alone.
				assert_eq(backhaul.heal_wds_moves({}, si, nil), 0, "healed once")
				assert_eq(#rec.cmds, 4, "no further commands")
			end)
		end
	},
	{
		name = "backhaul: heal_wds_moves() rewrites a switch port's host with no switch entry, in the window after the WDS port goes",
		fn = function()
			local fdb = {}
			with_fdb_seams(fdb, function(rec)
				local si = fake_sysinfo("wan")
				fdb.out = table.concat({
					"96:28:d6:13:bf:ad dev phy1-ap5.sta1 master br-lan ",
					"08:bf:b8:71:c0:31 dev wan master br-lan ",
					"08:bf:b8:71:c0:31 dev wan self ",
				}, "\n")
				backhaul.heal_wds_moves({}, si, nil)
				-- Mid-mesh, a wired host without its switch entry is left alone.
				fdb.out = table.concat({
					"96:28:d6:13:bf:ad dev phy1-ap5.sta1 master br-lan ",
					"08:bf:b8:71:c0:31 dev wan master br-lan ",
				}, "\n")
				assert_eq(backhaul.heal_wds_moves({}, si, nil), 0, "no window while the WDS port is up")

				-- The link ends. The controller crossed it between two heartbeats:
				-- the bridge has it on wan, the switch does not. The gateway has its
				-- switch entry; eth1 is no switch port at all.
				local after = table.concat({
					"08:bf:b8:71:c0:31 dev wan master br-lan ",
					"a8:88:1f:43:85:3f dev wan master br-lan ",
					"a8:88:1f:43:85:3f dev wan self ",
					"02:00:00:00:00:e1 dev eth1 master br-lan ",
				}, "\n")
				fdb.out = after
				assert_eq(backhaul.heal_wds_moves({}, si, nil), 1, "the stuck controller")
				assert_eq(rec.cmds[1], "bridge fdb replace 08:bf:b8:71:c0:31 dev wan master static >/dev/null 2>&1", "rewritten")
				assert_eq(backhaul.heal_wds_moves({}, si, nil), 0, "once per window, even before the switch relearns")
				for _ = 1, backhaul.WDS_HEAL_WINDOW do backhaul.heal_wds_moves({}, si, nil) end
				assert_eq(#rec.cmds, 2, "nothing more, and the window has closed")
				assert_eq(backhaul._heal_window, 0, "closed")
			end)
		end
	},
	{
		name = "backhaul: heal_wds_moves() covers the child's station port, skips static entries, forgets after the TTL",
		fn = function()
			local fdb = {now = 1000}
			with_fdb_seams(fdb, function(rec)
				local si = fake_sysinfo("wan")
				fdb.out = table.concat({
					"a8:88:1f:43:85:3f dev phy1-sta0 master br-lan ",
					"02:00:00:00:00:51 dev phy1-sta0 master br-lan ",
					"02:00:00:00:00:52 dev phy1-sta0 master br-lan ",
				}, "\n")
				backhaul.heal_wds_moves({}, si, "phy1-sta0")
				fdb.now = 1000 + backhaul.WDS_HEAL_TTL + 1
				fdb.out = table.concat({
					"a8:88:1f:43:85:3f dev phy1-sta0 master br-lan ",   -- still on the air: refreshed
					"02:00:00:00:00:51 dev lan3 master br-lan static", -- someone's static entry
				}, "\n")
				assert_eq(backhaul.heal_wds_moves({}, si, "phy1-sta0"), 0, "static entries are left alone")
				fdb.out = table.concat({
					"a8:88:1f:43:85:3f dev wan master br-lan ",
					"02:00:00:00:00:52 dev lan3 master br-lan ",       -- moved after the TTL ran out
				}, "\n")
				assert_eq(backhaul.heal_wds_moves({}, si, "phy1-sta0"), 1, "only the gateway, still remembered")
				assert_eq(rec.cmds[1], "bridge fdb replace a8:88:1f:43:85:3f dev wan master static >/dev/null 2>&1", "gateway")
			end)
		end
	},
	{
		name = "backhaul: tick() runs the WDS heal on a wired root with only a downlink, and not on swconfig",
		fn = function()
			local fdb = {}
			with_fdb_seams(fdb, function(rec)
				local ufuci = fake_ufuci({}, nil, {{name = "openuf_bh_dl_radio1"}})
				fdb.out = "c8:7f:54:06:03:0a dev phy1-ap1.sta1 master br-lan "
				backhaul.tick({}, {}, ufuci, fake_sysinfo("wan"), nil)
				fdb.out = "c8:7f:54:06:03:0a dev lan3 master br-lan "
				backhaul.tick({}, {}, ufuci, fake_sysinfo("wan"), nil)
				assert_eq(count(rec.cmds, "^bridge fdb replace c8:7f:54:06:03:0a dev lan3 master static"), 1, "healed through tick()")
				backhaul._wds_hosts = {}
				fdb.out = "c8:7f:54:06:03:0a dev phy1-ap1.sta1 master br-lan "
				backhaul.tick({}, SWCFG, ufuci, fake_sysinfo("wan"), nil)
				fdb.out = "c8:7f:54:06:03:0a dev eth0.1 master br-lan "
				backhaul.tick({}, SWCFG, ufuci, fake_sysinfo("wan"), nil)
				assert_eq(count(rec.cmds, "^bridge fdb"), 2, "swconfig: no FDB rewrite (its ARL heal covers it)")
			end)
		end
	},
	{
		name = "backhaul: plan() turns the captured entries into a downlink AP and a disabled uplink station",
		fn = function()
			local plan = backhaul.plan(MESH, ENTRIES, {}, {backhaul_mode = ""})
			assert_true(plan ~= nil, "a plan")
			assert_eq(plan.downlink.radio, "radio1", "downlink radio")
			assert_eq(plan.downlink.ssid, MESH.essid, "downlink ssid is the mesh essid")
			assert_eq(plan.downlink.key, MESH.psk, "downlink key is the site PSK")
			assert_eq(plan.uplink.radio, "radio1", "uplink radio")
			assert_eq(plan.uplink.ssid, MESH.essid, "the station joins the mesh essid, not its own vport name")
			assert_eq(plan.uplink.key, MESH.psk, "same PSK")
			assert_false(plan.uplink.enabled, "wired by default: the station is written disabled")
			assert_nil(plan.uplink.bssid, "no BSSID pin from the push")
			assert_eq(plan.uplink.vport, "vport-ac10076fc670", "the station's own name is kept for reporting")
			assert_eq(plan.uplink.devname, "ath4", "the controller's devname for the station")
			assert_eq(plan.downlink.devname, "vwire3", "and for the downlink")
		end
	},
	{
		name = "backhaul: plan() keeps the station enabled while the device is already on its wireless uplink",
		fn = function()
			local plan = backhaul.plan(MESH, ENTRIES, {}, {backhaul_mode = "wireless"})
			assert_true(plan.uplink.enabled, "stays enabled across a push")
		end
	},
	{
		name = "backhaul: plan() is nil without an enabled mesh block, a usable PSK, or any entry",
		fn = function()
			assert_nil(backhaul.plan(nil, ENTRIES), "no mesh block")
			local off = {status = false, essid = MESH.essid, psk = MESH.psk}
			assert_nil(backhaul.plan(off, ENTRIES), "mesh.status=disabled")
			local short = {status = true, essid = MESH.essid, psk = "short"}
			assert_nil(backhaul.plan(short, ENTRIES), "a PSK under 8 chars is not WPA2")
			assert_nil(backhaul.plan(MESH, {}), "no entries")
			local only_dl = backhaul.plan(MESH, {ENTRIES[1]})
			assert_true(only_dl.downlink ~= nil and only_dl.uplink == nil, "a parent-only push")
		end
	},
	{
		name = "backhaul: decide() is wired-first, waits DOWN_SECS on loss and nothing on return",
		fn = function()
			assert_eq(backhaul.DOWN_SECS, 10, "10 s")
			local mode, since = backhaul.decide(true, "wired", nil, 100)
			assert_eq(mode, "wired", "carrier: wired")
			assert_nil(since, "nothing counted")
			mode, since = backhaul.decide(false, "wired", nil, 100)
			assert_eq(mode, "wired", "carrier just gone: still wired")
			assert_eq(since, 100, "the loss is timed from now")
			mode, since = backhaul.decide(false, "wired", since, 109)
			assert_eq(mode, "wired", "9 s: still wired")
			assert_eq(since, 100, "and still timed from the loss")
			mode, since = backhaul.decide(false, "wired", since, 110)
			assert_eq(mode, "wireless", "10 s: wireless, however many heartbeats that was")
			mode, since = backhaul.decide(true, "wireless", since, 111)
			assert_eq(mode, "wired", "carrier back: wired at once")
			assert_nil(since, "timer reset")
			mode, since = backhaul.decide(nil, "wireless", 100, 200)
			assert_eq(mode, "wireless", "unknown carrier: hold")
			assert_nil(since, "and do not keep counting")
			mode = backhaul.decide(nil, nil, nil, 0)
			assert_eq(mode, "wired", "nothing known: wired")
		end
	},
	{
		name = "backhaul: tick() learns the wired socket, enables the station DOWN_SECS after the carrier went and disables it when the wire is back",
		fn = function()
			local carrier = {wan = true}
			with_seams(carrier, "", function()
				local st = {backhaul_mode = "", backhaul_wired_port = ""}
				local secs = {{name = "openuf_bh_ul_radio1", radio = "radio1", ssid = MESH.essid, disabled = true}}
				local uf = fake_ufuci(secs, "phy1-sta0")
				local saves = 0
				local state_mod = {save = function() saves = saves + 1 end}
				assert_eq(backhaul.tick(st, {}, uf, fake_sysinfo("wan"), state_mod), "wired", "wired with carrier")
				assert_eq(st.backhaul_wired_port, "wan", "remembered the socket the gateway is behind")
				assert_eq(saves, 1, "persisted once")
				-- the cable goes: the gateway is no longer behind any port, carrier 0
				carrier.wan = false
				local si = fake_sysinfo(nil)
				assert_eq(backhaul.tick(st, {}, uf, si, state_mod), "wired", "first tick: patience")
				now = now + backhaul.DOWN_SECS - 1
				assert_eq(backhaul.tick(st, {}, uf, si, state_mod), "wired", "9 s on: still patience")
				assert_eq(#uf.calls, 0, "station untouched")
				now = now + 1
				assert_eq(backhaul.tick(st, {}, uf, si, state_mod), "wireless", "10 s on: wireless")
				assert_eq(uf.calls[1], true, "station enabled")
				assert_eq(st.backhaul_mode, "wireless", "mode persisted")
				-- the gateway is now behind the station netdev: that must not be taken as a wired socket
				assert_eq(backhaul.tick(st, {}, uf, fake_sysinfo("phy1-sta0"), state_mod), "wireless", "stays wireless")
				assert_eq(st.backhaul_wired_port, "wan", "the station is not a wired socket")
				-- cable back
				carrier.wan = true
				assert_eq(backhaul.tick(st, {}, uf, fake_sysinfo("wan"), state_mod), "wired", "wired again at once")
				assert_eq(uf.calls[#uf.calls], false, "station disabled")
			end)
		end
	},
	{
		-- JIDU6401, 2026-10-28: the station came up 39 s to 98 s after the
		-- cable was pulled, because the policy only ran when an inform was
		-- due and failed informs back off. The idle loop now watches the
		-- socket, and the loop's wait is capped while a switch is under way.
		name = "backhaul: a DSA socket is watched between heartbeats and the loop's wait is capped around a switch",
		fn = function()
			local carrier = {wan = true}
			with_seams(carrier, "", function()
				local st = {backhaul_mode = "", backhaul_wired_port = ""}
				local secs = {{name = "openuf_bh_ul_radio1", radio = "radio1", ssid = MESH.essid, disabled = true}}
				local uf = fake_ufuci(secs, "phy1-sta0")
				assert_false(backhaul.watching(), "nothing to watch before a heartbeat")
				assert_false(backhaul.carrier_changed(), "and nothing changed")
				backhaul.tick(st, {}, uf, fake_sysinfo("wan"), nil)
				assert_true(backhaul.watching(), "the wired socket is watched")
				assert_nil(backhaul.wait_cap(st), "wired and steady: no cap")
				assert_false(backhaul.carrier_changed(), "link as the heartbeat saw it")
				carrier.wan = false
				assert_true(backhaul.carrier_changed(), "the cable went: wake the loop")
				local si = fake_sysinfo(nil)
				backhaul.tick(st, {}, uf, si, nil)
				assert_false(backhaul.carrier_changed(), "the heartbeat has seen it")
				assert_eq(backhaul.wait_cap(st), backhaul.DOWN_SECS, "wait no longer than the switch is due")
				now = now + 7
				assert_eq(backhaul.wait_cap(st), 3, "3 s left")
				now = now + 3
				assert_eq(backhaul.wait_cap(st), 1, "due: at least a second")
				assert_eq(backhaul.tick(st, {}, uf, si, nil), "wireless", "switched")
				assert_eq(backhaul.wait_cap(st), backhaul.FAST_RETRY_S, "just switched: retry fast")
				now = now + backhaul.SWITCH_FAST_S - 1
				assert_eq(backhaul.wait_cap(st), backhaul.FAST_RETRY_S, "still within the fast window")
				now = now + 1
				backhaul.tick(st, {}, uf, si, nil)
				assert_nil(backhaul.wait_cap(st), "the window is over")
				assert_true(backhaul.watching(), "still watched while wireless")
				carrier.wan = true
				assert_true(backhaul.carrier_changed(), "the cable is back: wake the loop")
				assert_eq(backhaul.tick(st, {}, uf, fake_sysinfo("wan"), nil), "wired", "back on the wire")
				assert_eq(backhaul.wait_cap(st), backhaul.FAST_RETRY_S, "fast again after failback")
				carrier.wan = nil
				assert_false(backhaul.carrier_changed(), "an unreadable link says nothing")
			end)
		end
	},
	{
		name = "backhaul: a carrier that comes back before DOWN_SECS cancels the switch",
		fn = function()
			local carrier = {wan = true}
			with_seams(carrier, "", function()
				local st = {backhaul_mode = "", backhaul_wired_port = ""}
				local secs = {{name = "openuf_bh_ul_radio1", radio = "radio1", ssid = MESH.essid, disabled = true}}
				local uf = fake_ufuci(secs, "phy1-sta0")
				backhaul.tick(st, {}, uf, fake_sysinfo("wan"), nil)
				carrier.wan = false
				backhaul.tick(st, {}, uf, fake_sysinfo(nil), nil)
				now = now + 5
				carrier.wan = true
				assert_eq(backhaul.tick(st, {}, uf, fake_sysinfo("wan"), nil), "wired", "re-seated in 5 s")
				assert_nil(backhaul.wait_cap(st), "nothing pending")
				carrier.wan = false
				backhaul.tick(st, {}, uf, fake_sysinfo(nil), nil)
				now = now + backhaul.DOWN_SECS - 1
				assert_eq(backhaul.tick(st, {}, uf, fake_sysinfo(nil), nil), "wired",
					"the new loss is timed afresh, not from the first")
				assert_eq(#uf.calls, 0, "the station was never touched")
			end)
		end
	},
	{
		name = "backhaul: tick() is a no-op on a device with no uplink station section",
		fn = function()
			with_seams({wan = false}, "", function()
				local st = {backhaul_mode = ""}
				assert_nil(backhaul.tick(st, {}, fake_ufuci({}, nil), fake_sysinfo("wan"), nil), "nothing to do")
				assert_true(st.backhaul_mode == "", "state untouched")
			end)
		end
	},
	{
		name = "backhaul: uplink_report() describes the hop only while wireless and associated",
		fn = function()
			local link = "Connected to 78:bb:c1:fe:3f:cb (on phy1-sta0)\n\tSSID: vwire-5f3369181f7fbab5\n"
				.. "\tfreq: 5500\n\tRX: 1000 bytes (10 packets)\n\tTX: 2000 bytes (20 packets)\n"
				.. "\tsignal: -47 dBm\n\trx bitrate: 866.7 MBit/s\n\ttx bitrate: 780.0 MBit/s\n"
			with_seams({}, link, function()
				local secs = {{name = "openuf_bh_ul_radio1", radio = "radio1", ssid = MESH.essid, disabled = false}}
				local uf = fake_ufuci(secs, "phy1-sta0")
				local st = {backhaul_mode = "wireless", backhaul_parent = "78:bb:c1:fe:3f:c9"}
				local up = backhaul.uplink_report(st, {}, uf)
				assert_eq(up.type, "wireless", "type")
				assert_eq(up.name, "phy1-sta0", "netdev name when the section has no controller devname")
				secs[1].devname = "ath4"
				assert_eq(backhaul.uplink_report(st, {}, uf).name, "ath4", "the controller's devname when known")
				secs[1].devname = nil
				assert_eq(up.bssid, "78:bb:c1:fe:3f:cb", "the BSS it joined")
				assert_eq(up.uplink_mac, "78:bb:c1:fe:3f:c9", "the parent the controller named")
				assert_eq(up.channel, 100, "freq 5500 -> channel 100")
				assert_eq(up.radio, "na", "5 GHz")
				assert_eq(up.signal, -47, "signal")
				assert_eq(up.tx_rate, 780000, "kbps")
				assert_eq(up.tx_bytes, 1000, "counters from sysfs")
				assert_eq(up.essid, MESH.essid, "essid")
				assert_nil(backhaul.uplink_report({backhaul_mode = "wired"}, {}, uf), "wired: nothing")
				-- no priority-1 parent from the controller: resolve it from the sibling element
				local si = {scan_table = function() return {
					{bssid = "aa:bb:cc:dd:ee:ff", is_unifi = false},
					{bssid = "78:BB:C1:FE:3F:CB", is_unifi = true, serialno = "78:bb:c1:fe:3f:c9"},
				} end}
				local up2 = backhaul.uplink_report({backhaul_mode = "wireless", backhaul_parent = ""}, {}, uf, si)
				assert_eq(up2.uplink_mac, "78:bb:c1:fe:3f:c9", "parent from the scan table's serialno")
				local up3 = backhaul.uplink_report({backhaul_mode = "wireless", backhaul_parent = ""}, {}, uf,
					{scan_table = function() return {} end})
				assert_nil(up3.uplink_mac, "unknown parent stays absent, never guessed")
			end)
			with_seams({}, "Not connected.\n", function()
				local secs = {{name = "openuf_bh_ul_radio1", radio = "radio1", ssid = MESH.essid, disabled = false}}
				assert_nil(backhaul.uplink_report({backhaul_mode = "wireless"}, {}, fake_ufuci(secs, "phy1-sta0")),
					"not associated: nothing")
			end)
		end
	},
	{
		name = "backhaul: parent_for_bssid() names the sibling behind the BSS joined, from the RAW scan entry, before the push's parent",
		fn = function()
			-- sysinfo.scan_table's entries carry the sibling element as peer_mac;
			-- is_unifi/serialno exist only on the payload's scan_radio_table.
			local si = {scan_table = function() return {
				{bssid = "aa:bb:cc:dd:ee:ff"},
				{bssid = "7A:BB:C1:FE:3F:CB", peer_mac = "78:BB:C1:FE:3F:C9"},
			} end}
			assert_eq(backhaul.parent_for_bssid({backhaul_parent = ""}, "7a:bb:c1:fe:3f:cb", "phy1-sta0", si),
				"78:bb:c1:fe:3f:c9", "the raw entry's peer_mac, case-insensitively on both sides")
			assert_eq(backhaul.parent_for_bssid({backhaul_parent = "11:22:33:44:55:66"}, "7a:bb:c1:fe:3f:cb", "phy1-sta0", si),
				"78:bb:c1:fe:3f:c9", "the BSS actually joined beats the parent the last push named")
			-- Payload-shaped entries still work (is_unifi + serialno).
			local si2 = {scan_table = function() return {
				{bssid = "7a:bb:c1:fe:3f:cb", is_unifi = true, serialno = "78:bb:c1:fe:3f:c9"},
			} end}
			assert_eq(backhaul.parent_for_bssid({}, "7a:bb:c1:fe:3f:cb", "phy1-sta0", si2), "78:bb:c1:fe:3f:c9", "decoded shape too")
			-- The push's parent is the fallback, never the first word.
			assert_eq(backhaul.parent_for_bssid({backhaul_parent = "11:22:33:44:55:66"}, "aa:bb:cc:dd:ee:ff", "phy1-sta0", si),
				"11:22:33:44:55:66", "a BSS with no sibling element: the push's parent")
			assert_eq(backhaul.parent_for_bssid({backhaul_parent = "11:22:33:44:55:66"}, "7a:bb:c1:fe:3f:cb", nil, si),
				"11:22:33:44:55:66", "no interface to scan from: the push's parent")
			assert_nil(backhaul.parent_for_bssid({backhaul_parent = ""}, "aa:bb:cc:dd:ee:ff", "phy1-sta0", si), "neither: unknown, never a guess")
			assert_nil(backhaul.parent_for_bssid({backhaul_parent = ""}, "7a:bb:c1:fe:3f:cb", nil, si), "no interface and no push: unknown")
		end
	},
	{
		name = "backhaul: child_serialno() names the one sibling AP learnt behind a downlink station's netdev",
		fn = function()
			local scans = {{name = "radio1", scan_table = {
				{bssid = "aa:bb:cc:dd:ee:01", is_unifi = false},
				{bssid = "ac:10:07:6f:c6:71", is_unifi = true, serialno = "AC:10:07:6F:C6:70"},
				{bssid = "11:22:33:44:55:66", is_unifi = true, serialno = "11:22:33:44:55:60"},
			}}}
			local fdb = {["ac:10:07:6f:c6:70"] = "phy1-ap1.sta1", ["20:f1:b2:c5:c6:de"] = "phy1-ap1.sta1",
				["aa:10:07:6f:c6:72"] = "phy1-ap1.sta1", ["66:76:5b:ed:8c:a2"] = "phy1-ap0"}
			local si = {lan_bridge = function() return "br-lan" end, bridge_fdb_ports = function() return fdb end}
			assert_eq(backhaul.child_serialno("phy1-ap1.sta1", scans, {}, si), "ac:10:07:6f:c6:70",
				"the sibling whose identity MAC sits behind the station's netdev, lower-cased")
			assert_nil(backhaul.child_serialno("phy1-ap0", scans, {}, si), "a user VAP netdev: no sibling behind it")
			assert_nil(backhaul.child_serialno("phy1-ap1.sta1", {}, {}, si), "no siblings known: nothing")
			fdb["11:22:33:44:55:60"] = "phy1-ap1.sta1"
			assert_nil(backhaul.child_serialno("phy1-ap1.sta1", scans, {}, si), "two siblings behind one netdev (multi-hop): refuse to guess")
		end
	},
	{
		name = "backhaul: lan_bridge() follows a swconfig trunk to the bridge its LAN sub-device sits in",
		fn = function()
			local si = fake_swsysinfo({up = {}})
			assert_eq(backhaul.lan_bridge(SWCFG, si), "br-lan", "eth0 has no master; eth0.1 does")
			local cfg = {net = {lan_cpueth = "eth0", lan_vlanid = 2}}
			assert_nil(backhaul.lan_bridge(cfg, si), "the LAN's VLAN id decides which sub-device")
			local dsa = {lan_bridge = function(i) return i == "br-lan" and "br-lan" or nil end}
			assert_eq(backhaul.lan_bridge({net = {lan_cpueth = "br-lan"}}, dsa), "br-lan", "DSA: the bridge itself")
			assert_nil(backhaul.lan_bridge({net = {}}, dsa), "nothing named: nothing")
		end
	},
	{
		name = "backhaul: tick() on swconfig follows the socket's switch link, not the CPU trunk's always-up carrier",
		fn = function()
			local files = {}
			local dirs = {
				["/sys/class/net"] = "br-lan\nbr-openuf20\neth0\neth0.1\neth0.20\nbr-lan.20\nphy0-ap0\nphy0-sta0\n",
				["/sys/class/net/br-lan/brif"] = "eth0.1\nphy0-ap0\nphy0-sta0\n",
				["/sys/class/net/br-openuf20/brif"] = "eth0.20\nbr-lan.20\nphy0-ap1\n",
			}
			with_sw_seams(files, dirs, function(rec)
				local sw = {gw = 3, up = {[0] = true, [3] = true, [5] = false}, fdb_port = "eth0.1"}
				local si = fake_swsysinfo(sw)
				local st = {backhaul_mode = ""}
				local secs = {{name = "openuf_bh_ul_radio0", radio = "radio0", ssid = MESH.essid, disabled = true}}
				local uf = fake_ufuci(secs, "phy0-sta0")
				assert_eq(backhaul.tick(st, SWCFG, uf, si, nil), "wired", "socket 3 has link")
				assert_eq(st.backhaul_wired_phys, 3, "remembered the switch port the ARL has the gateway on")
				assert_nil(st.backhaul_wired_port, "not the CPU trunk's sub-device")
				assert_eq(sw.fdb_calls or 0, 0, "no bridge FDB dump: this board has no socket of its own outside the switch")
				-- The cable goes. The driver flushes the port's ARL entries; eth0.1 stays up.
				sw.gw, sw.up[3] = nil, false
				assert_eq(backhaul.tick(st, SWCFG, uf, si, nil), "wired", "first tick: patience")
				assert_eq(#uf.calls, 0, "station untouched")
				assert_false(backhaul.watching(), "a switch port is not watched between heartbeats")
				now = now + backhaul.DOWN_SECS
				assert_eq(backhaul.tick(st, SWCFG, uf, si, nil), "wireless", "10 s on: wireless")
				assert_eq(uf.calls[1], true, "station enabled")
				assert_eq(st.backhaul_wired_phys, 3, "the socket is still remembered")
				-- The switch forgot the gateway by itself; the bridges did not:
				-- every wired port of br-lan and of the VLAN bridge is flushed,
				-- no wireless one.
				assert_eq(count(rec.writes, "^/sys/class/net/eth0%.1/brport/flush=1$"), 1, "eth0.1 flushed")
				assert_eq(count(rec.writes, "^/sys/class/net/eth0%.20/brport/flush=1$"), 1, "eth0.20 flushed")
				assert_eq(count(rec.writes, "^/sys/class/net/br%-lan%.20/brport/flush=1$"), 1, "br-lan.20 flushed")
				assert_eq(count(rec.writes, "phy0%-"), 0, "wireless ports keep theirs")
				-- On the air the ARL has the gateway on the CPU port (flooded in
				-- from br-lan): not a socket, nothing changes.
				sw.gw = 0
				assert_eq(backhaul.tick(st, SWCFG, uf, si, nil), "wireless", "stays wireless")
				assert_eq(st.backhaul_wired_phys, 3, "the CPU port is never taken for the socket")
				assert_eq(count(rec.cmds, "flush_arl_table"), 0, "no ARL flush while wireless")
				-- Cable back in socket 3, the station still up: the ARL still says
				-- CPU port. Wired at once, and that stale entry is flushed.
				sw.up[3] = true
				assert_eq(backhaul.tick(st, SWCFG, uf, si, nil), "wired", "wired again at once")
				assert_eq(uf.calls[#uf.calls], false, "station disabled")
				assert_eq(count(rec.cmds, "^swconfig dev switch0 set flush_arl_table"), 1,
					"the switch's address table flushed: the gateway sat on the CPU port")
				backhaul.tick(st, SWCFG, uf, si, nil)
				assert_eq(count(rec.cmds, "flush_arl_table"), 2, "and again while it still does")
				sw.gw = 3
				backhaul.tick(st, SWCFG, uf, si, nil)
				assert_eq(count(rec.cmds, "flush_arl_table"), 2, "not once the gateway is behind the socket")
				-- Past the window a CPU-port entry is left alone: a board with two
				-- CPU ports lists the gateway there legitimately.
				sw.gw = 0
				for _ = 1, 4 do backhaul.tick(st, SWCFG, uf, si, nil) end
				assert_eq(count(rec.cmds, "flush_arl_table"), 2, "only in the heartbeats right after the switch")
				sw.gw = 3
				-- A cable moved to the other socket is followed, as on DSA.
				sw.gw, sw.up[5] = 5, true
				backhaul.tick(st, SWCFG, uf, si, nil)
				assert_eq(st.backhaul_wired_phys, 5, "socket 5 now")
			end)
		end
	},
	{
		name = "backhaul: tick() on swconfig holds when the switch cannot be read",
		fn = function()
			with_sw_seams({}, {}, function()
				local si = fake_swsysinfo({up = {}})   -- no ports: swconfig missing
				local st = {backhaul_mode = "wired", backhaul_wired_phys = 3}
				local secs = {{name = "openuf_bh_ul_radio0", radio = "radio0", ssid = MESH.essid, disabled = true}}
				local uf = fake_ufuci(secs, "phy0-sta0")
				for _ = 1, 4 do backhaul.tick(st, SWCFG, uf, si, nil) end
				assert_eq(st.backhaul_mode, "wired", "unknown link is not a lost link")
				assert_eq(#uf.calls, 0, "station untouched")
			end)
		end
	},
	{
		name = "backhaul: tick() on swconfig asks the bridge only about a socket that is a netdev of its own",
		fn = function()
			-- TL-WDR3500 shape: four switch sockets and a WAN PHY outside the switch.
			local cfg = {
				net  = {lan_cpueth = "eth0", ports = {{idx = 1, swport = "lan1"}, {idx = 5, ifname = "eth1"}}},
				vlan = {device = "switch0", cpu_lan = 0, cpu_wan = 0, ports = {lan1 = 1}},
			}
			local files = {["/sys/class/net/eth1/operstate"] = "up\n"}
			with_sw_seams(files, {}, function()
				local sw = {gw = 0, up = {[0] = true, [1] = false}, fdb_port = "eth1"}
				local si = fake_swsysinfo(sw)
				local st = {backhaul_mode = ""}
				local secs = {{name = "openuf_bh_ul_radio0", radio = "radio0", ssid = MESH.essid, disabled = true}}
				local uf = fake_ufuci(secs, "phy0-sta0")
				assert_eq(backhaul.tick(st, cfg, uf, si, nil), "wired", "eth1 has carrier")
				assert_eq(st.backhaul_wired_port, "eth1", "the own-PHY socket, from the bridge")
				assert_nil(st.backhaul_wired_phys, "no switch port")
				-- The CPU trunk's sub-device is never a socket.
				local st2 = {backhaul_mode = ""}
				sw.fdb_port = "eth0.1"
				backhaul.tick(st2, cfg, uf, si, nil)
				assert_nil(st2.backhaul_wired_port, "eth0.1 refused")
				-- Gateway behind switch socket 1 now: the switch wins, the netdev is forgotten.
				sw.gw, sw.up[1] = 1, true
				backhaul.tick(st, cfg, uf, si, nil)
				assert_eq(st.backhaul_wired_phys, 1, "switch socket")
				assert_nil(st.backhaul_wired_port, "one remembered uplink at a time")
			end)
		end
	},
	{
		name = "backhaul: child_serialno() finds a swconfig parent's LAN bridge through the trunk's sub-device",
		fn = function()
			local scans = {{name = "radio0", scan_table = {
				{bssid = "ac:10:07:6f:c6:71", is_unifi = true, serialno = "ac:10:07:6f:c6:70"},
			}}}
			local si = fake_swsysinfo({up = {}})
			si.bridge_fdb_ports = function(br)
				assert_eq(br, "br-lan", "asked of the LAN bridge")
				return {["ac:10:07:6f:c6:70"] = "phy0-ap1.sta1"}
			end
			assert_eq(backhaul.child_serialno("phy0-ap1.sta1", scans, SWCFG, si), "ac:10:07:6f:c6:70",
				"the child behind the WDS netdev")
		end
	},
	-- ── Multi-hop ────────────────────────────────────────────────────────────
	{
		name = "backhaul: learn() files a downlink whose ancestors include this AP as a descendant",
		fn = function()
			backhaul._dirty = false
			local st = {mac = "AA:00:00:00:00:0B"}
			local got = backhaul.learn(st, {
				-- the wired root A
				{bssid = "02:00:00:00:0a:01", peer_mac = "aa:00:00:00:00:0a",
					peer_mesh = {rooted = true, ancestors = {}}},
				-- C, B's child: its chain runs through B
				{bssid = "02:00:00:00:0c:01", peer_mac = "aa:00:00:00:00:0c",
					peer_mesh = {rooted = true, sta = "02:00:00:00:0c:99", ancestors = {"aa:00:00:00:00:0b", "aa:00:00:00:00:0a"}}},
				-- D, C's child: B two levels up
				{bssid = "02:00:00:00:0d:01", peer_mac = "aa:00:00:00:00:0d",
					peer_mesh = {rooted = true, ancestors = {"aa:00:00:00:00:0c", "aa:00:00:00:00:0b", "aa:00:00:00:00:0a"}}},
				-- an ordinary neighbour with no element
				{bssid = "02:00:00:00:ee:01"},
			})
			assert_eq(got["02:00:00:00:0a:01"].desc, false, "the root is not a descendant")
			assert_eq(st.backhaul_seen["02:00:00:00:0c:01"].desc, true, "a child is")
			assert_eq(st.backhaul_seen["02:00:00:00:0d:01"].desc, true, "and a grandchild")
			assert_eq(st.backhaul_seen["02:00:00:00:0c:01"].sta, "02:00:00:00:0c:99", "the child's station kept")
			assert_eq(st.backhaul_seen["02:00:00:00:ee:01"], nil, "no element, nothing learnt")
			assert_true(backhaul._dirty, "worth saving")
			backhaul._dirty = false
			backhaul.learn(st, {{bssid = "02:00:00:00:0a:01", peer_mac = "aa:00:00:00:00:0a",
				peer_mesh = {rooted = true, ancestors = {}}}})
			assert_false(backhaul._dirty, "the same again is not saved again")
		end
	},
	{
		name = "backhaul: learn() forgets a downlink not heard for a week",
		fn = function()
			local now = 1000000
			local orig = backhaul._time
			backhaul._time = function() return now end
			local st = {mac = "aa:00:00:00:00:0b", backhaul_seen = {
				["02:00:00:00:0c:01"] = {id = "aa:00:00:00:00:0c", desc = true, t = now - 8 * 86400},
				["02:00:00:00:0a:01"] = {id = "aa:00:00:00:00:0a", t = now - 3600},
			}}
			backhaul.learn(st, {})
			backhaul._time = orig
			assert_eq(st.backhaul_seen["02:00:00:00:0c:01"], nil, "a week old: gone")
			assert_true(st.backhaul_seen["02:00:00:00:0a:01"] ~= nil, "an hour old: kept")
		end
	},
	{
		name = "backhaul: station_lists() pins the controller's parent unless it is a descendant, and blacklists descendants",
		fn = function()
			local st = {backhaul_parent = "aa:00:00:00:00:0a", backhaul_seen = {
				["02:00:00:00:0a:02"] = {id = "aa:00:00:00:00:0a"},
				["02:00:00:00:0a:01"] = {id = "aa:00:00:00:00:0a"},
				["02:00:00:00:0c:01"] = {id = "aa:00:00:00:00:0c", desc = true},
				["02:00:00:00:0e:01"] = {id = "aa:00:00:00:00:0e"},
			}}
			local l = backhaul.station_lists(st)
			assert_eq(l.bssid, "02:00:00:00:0a:01", "the parent's first downlink")
			assert_eq(table.concat(l.blacklist, " "), "02:00:00:00:0c:01", "only the descendant")
			assert_eq(backhaul.station_lists(st, true).bssid, nil, "drop_pin")
			st.backhaul_parent = "aa:00:00:00:00:0c"
			assert_eq(backhaul.station_lists(st).bssid, nil, "a descendant is never pinned, even if chosen")
		end
	},
	{
		name = "backhaul: tick() enables the station with the pin and the blacklist in one go",
		fn = function()
			with_seams({wan = false}, "", function()
				local st = {mac = "aa:00:00:00:00:0b", backhaul_mode = "wired", backhaul_wired_port = "wan",
					backhaul_parent = "aa:00:00:00:00:0a", backhaul_seen = {
						["02:00:00:00:0a:01"] = {id = "aa:00:00:00:00:0a"},
						["02:00:00:00:0c:01"] = {id = "aa:00:00:00:00:0c", desc = true}}}
				local secs = {{name = "openuf_bh_ul_radio1", radio = "radio1", ssid = MESH.essid, disabled = true}}
				local uf = fake_ufuci(secs, nil)
				local got
				function uf.backhaul_set_uplink_enabled(enabled, lists)
					got = {enabled = enabled, lists = lists}
					return true
				end
				backhaul.tick(st, {}, uf, fake_sysinfo(nil), nil)
				now = now + backhaul.DOWN_SECS
				assert_eq(backhaul.tick(st, {}, uf, fake_sysinfo(nil), nil), "wireless", "wireless")
				assert_eq(got.enabled, true, "enabled")
				assert_eq(got.lists.bssid, "02:00:00:00:0a:01", "pinned to the chosen parent")
				assert_eq(got.lists.blacklist[1], "02:00:00:00:0c:01", "its child blacklisted")
				assert_eq(st.backhaul_pin, "02:00:00:00:0a:01", "remembered for the next push")
				assert_eq(st.backhaul_blacklist, "02:00:00:00:0c:01", "likewise")
			end)
		end
	},
	{
		name = "backhaul: multihop_tick() leaves a descendant's downlink it finds itself joined to",
		fn = function()
			local orig_popen, orig_log = backhaul._popen, backhaul._log
			local logs = {}
			backhaul._log = function(m) logs[#logs + 1] = m end
			backhaul._popen = function(cmd)
				if cmd:find(" info$") then return "Interface phy1-sta0\n\taddr 02:00:00:00:0b:99\n" end
				if cmd:find(" link$") then return "Connected to 02:00:00:00:0c:01 (on phy1-sta0)\n" end
				return ""
			end
			local st = {mac = "aa:00:00:00:00:0b", backhaul_seen = {}}
			local written
			local uf = {backhaul_set_uplink_lists = function(l) written = l; return true end}
			local si = {scan_table = function() return {
				{bssid = "02:00:00:00:0c:01", peer_mac = "aa:00:00:00:00:0c",
					peer_mesh = {rooted = true, ancestors = {"aa:00:00:00:00:0b"}}}} end}
			local ok, err = pcall(backhaul.multihop_tick, st, uf, si, "wireless", "phy1-sta0")
			backhaul._popen, backhaul._log = orig_popen, orig_log
			assert_true(ok, tostring(err))
			assert_true(written ~= nil, "lists rewritten")
			assert_eq(written.blacklist[1], "02:00:00:00:0c:01", "the descendant's downlink banned")
			assert_true(logs[1]:find("loop", 1, true) ~= nil, "says why")
		end
	},
	{
		name = "backhaul: multihop_tick() drops an unreachable parent pin after PIN_GIVEUP heartbeats",
		fn = function()
			local orig_popen, orig_log = backhaul._popen, backhaul._log
			backhaul._log = function() end
			backhaul._popen = function(cmd)
				if cmd:find(" link$") then return "Not connected.\n" end
				return ""
			end
			backhaul._unjoined = 0
			local st = {mac = "aa:00:00:00:00:0b", backhaul_parent = "aa:00:00:00:00:0a",
				backhaul_pin = "02:00:00:00:0a:01",
				backhaul_seen = {["02:00:00:00:0a:01"] = {id = "aa:00:00:00:00:0a", t = os.time()}}}
			local writes = {}
			local uf = {backhaul_set_uplink_lists = function(l) writes[#writes + 1] = l; return true end}
			for _ = 1, backhaul.PIN_GIVEUP - 1 do backhaul.multihop_tick(st, uf, {}, "wireless", "phy1-sta0") end
			local before = #writes
			backhaul.multihop_tick(st, uf, {}, "wireless", "phy1-sta0")
			backhaul._popen, backhaul._log = orig_popen, orig_log
			assert_eq(before, 0, "the pin is kept while there is still hope")
			assert_eq(#writes, 1, "then rewritten once")
			assert_eq(writes[1].bssid, nil, "without the pin")
			assert_eq(st.backhaul_pin, nil, "and remembered so")
		end
	},
	{
		name = "backhaul: multihop_tick() keeps the downlink's element current without a reload",
		fn = function()
			local orig_popen = backhaul._popen
			backhaul._popen = function(cmd)
				if cmd:find(" info$") then return "\taddr 02:00:00:00:0b:99\n" end
				if cmd:find(" link$") then return "Connected to 02:00:00:00:0a:01 (on phy1-sta0)\n" end
				return ""
			end
			local sysinfo = dofile("openuf/sysinfo.lua")
			local si = {
				peer_ie_hex = sysinfo.peer_ie_hex, peer_path_ie_hex = sysinfo.peer_path_ie_hex,
				scan_table = function() return {
					{bssid = "02:00:00:00:0a:01", peer_mac = "aa:00:00:00:00:0a",
						peer_mesh = {rooted = true, ancestors = {}}}} end,
			}
			local set = {}
			local uf = {backhaul_set_downlink_ie = function(h) set[#set + 1] = h; return true end,
				backhaul_set_uplink_lists = function() return false end}
			local st = {mac = "aa:00:00:00:00:0b"}
			backhaul.multihop_tick(st, uf, si, "wired", nil)
			assert_eq(st.backhaul_ie, sysinfo.peer_path_ie_hex("aa:00:00:00:00:0b", true, nil, {}), "wired: rooted, no ancestors")
			assert_eq(set[1], sysinfo.peer_ie_hex("aa:00:00:00:00:0b") .. st.backhaul_ie, "version 1 kept in front")
			backhaul.multihop_tick(st, uf, si, "wired", nil)
			assert_eq(#set, 1, "unchanged: not handed over again")
			backhaul.multihop_tick(st, uf, si, "wireless", "phy1-sta0")
			backhaul._popen = orig_popen
			assert_eq(st.backhaul_ie, sysinfo.peer_path_ie_hex("aa:00:00:00:00:0b", true,
				"02:00:00:00:0b:99", {"aa:00:00:00:00:0a"}), "on the air: the parent in front, own station named")
			assert_eq(#set, 2, "handed over once more")
		end
	},
	{
		name = "backhaul: tick() with a downlink and no uplink station still beacons the rooted element",
		fn = function()
			-- A wired root whose Wireless Meshing is off: the push carries the
			-- downlink only. tick() returned before multihop_tick, so the
			-- downlink beaconed version 1 alone (QEMU test VM, 2026-10-26).
			local sysinfo = dofile("openuf/sysinfo.lua")
			local si = {peer_ie_hex = sysinfo.peer_ie_hex, peer_path_ie_hex = sysinfo.peer_path_ie_hex}
			local set, saved = {}, 0
			local uf = fake_ufuci({}, nil, {{name = "openuf_bh_dl_radio1"}})
			uf.backhaul_set_downlink_ie = function(h) set[#set + 1] = h; return true end
			local st = {mac = "aa:00:00:00:00:0a"}
			backhaul._dirty = false
			local mode = backhaul.tick(st, {}, uf, si, {save = function() saved = saved + 1 end})
			assert_eq(mode, nil, "still no uplink mode to report")
			assert_eq(st.backhaul_ie, sysinfo.peer_path_ie_hex("aa:00:00:00:00:0a", true, nil, {}),
				"rooted, no ancestors")
			assert_eq(set[1], sysinfo.peer_ie_hex("aa:00:00:00:00:0a") .. st.backhaul_ie, "handed to the downlink")
			assert_eq(saved, 1, "and persisted")
			assert_eq(#uf.calls, 0, "no station switched")

			local none = fake_ufuci({}, nil, {})
			none.backhaul_set_downlink_ie = function() error("no downlink: nothing to write") end
			local st2 = {mac = "aa:00:00:00:00:0a"}
			backhaul.tick(st2, {}, none, si, nil)
			assert_eq(st2.backhaul_ie, nil, "no mesh at all: untouched")
		end
	},
	{
		name = "backhaul: child_serialno() names a child by the station in its own element, grandchildren or not",
		fn = function()
			local st = {backhaul_seen = {
				["02:00:00:00:0b:01"] = {id = "aa:00:00:00:00:0b", sta = "02:00:00:00:0b:99"},
				["02:00:00:00:0c:01"] = {id = "aa:00:00:00:00:0c", sta = "02:00:00:00:0c:99"}}}
			assert_eq(backhaul.child_serialno("phy1-ap1.sta1", {}, {}, nil, "02:00:00:00:0B:99", st),
				"aa:00:00:00:00:0b", "exact, no bridge lookup needed")
			assert_eq(backhaul.child_serialno("phy1-ap1.sta1", {}, {}, nil, "02:00:00:00:ff:99", st),
				nil, "an unknown station falls through (and finds nothing here)")
		end
	},
	{
		name = "backhaul: plan() carries the pin, the blacklist and the downlink element into the push's rewrite",
		fn = function()
			local st = {backhaul_mode = "wireless", backhaul_pin = "02:00:00:00:0a:01",
				backhaul_blacklist = "02:00:00:00:0c:01 02:00:00:00:0d:01", backhaul_ie = "dd15aa"}
			local plan = backhaul.plan(MESH, ENTRIES, {}, st)
			assert_eq(plan.uplink.bssid, "02:00:00:00:0a:01", "pin")
			assert_eq(table.concat(plan.uplink.blacklist, " "), "02:00:00:00:0c:01 02:00:00:00:0d:01", "blacklist")
			assert_eq(plan.downlink.path_ie, "dd15aa", "element")
		end
	},
}
