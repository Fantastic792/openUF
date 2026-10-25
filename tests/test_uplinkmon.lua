-- Tests for openuf/uplinkmon.lua (the Uplink Connectivity Monitor) and its
-- heartbeat in inform.lua. No device access: every seam is replaced.

local uplinkmon = dofile("openuf/uplinkmon.lua")
local inform = dofile("openuf/inform.lua")

local function with_stderr(fn)
	local orig = io.stderr
	local buf = {}
	io.stderr = {write = function(_, ...) for _, s in ipairs({...}) do buf[#buf + 1] = s end end}
	local ok, err = pcall(fn)
	io.stderr = orig
	if not ok then error(err, 0) end
	return table.concat(buf)
end

-- The links of fake netdevs, driven through wlansched's seams as the schedule
-- tests do: flags from sysfs, `ip link set` to change them, hostapd answers OK.
local function with_links(links, fn)
	local ws = inform._wlansched
	local orig = {exec = ws._exec, read = ws._read_file, popen = ws._popen}
	ws._popen = function() return "OK\n" end
	ws._read_file = function(p)
		local n = p:match("^/sys/class/net/(.-)/flags$")
		if links[n] == nil then return nil end
		return links[n] and "0x1003\n" or "0x1002\n"
	end
	ws._exec = function(c)
		local n, how = c:match("^ip link set dev (%S+) (%a+)")
		links[n] = (how == "up")
		return 0
	end
	local ok, err = pcall(fn)
	ws._exec, ws._read_file, ws._popen = orig.exec, orig.read, orig.popen
	if not ok then error(err, 0) end
end

return {
	{
		name = "uplinkmon: parse() reads the switch and a custom host from the connectivity block",
		fn = function()
			local u = uplinkmon.parse("connectivity.status=enabled\nconnectivity.uplink_eth=eth0\n"
				.. "connectivity.uplink_gateway=192.0.2.254\n")
			assert_true(u.enabled, "status=enabled is on")
			assert_nil(u.host, "no custom target")
			assert_eq(u.gateway, "192.0.2.254", "the controller's gateway")
			u = uplinkmon.parse("connectivity.status=disabled\nconnectivity.uplink=192.0.2.1\n")
			assert_false(u.enabled, "disabled is off")
			assert_eq(u.host, "192.0.2.1", "connectivity.uplink is the custom target")
			assert_nil(uplinkmon.parse("wireless.1.ssid=x\n"), "no block at all: nil")
			assert_nil(uplinkmon.parse(nil), "no input: nil")
		end
	},
	{
		name = "uplinkmon: decide() goes off the air after FAIL_TICKS failures and back after OK_TICKS answers",
		fn = function()
			uplinkmon.decide(false)
			local iso = false
			for i = 1, uplinkmon.FAIL_TICKS - 1 do
				iso = uplinkmon.decide(true, false, iso)
				assert_false(iso, "failure " .. i .. ": patience")
			end
			iso = uplinkmon.decide(true, false, iso)
			assert_true(iso, "failure " .. uplinkmon.FAIL_TICKS .. ": isolated")
			iso = uplinkmon.decide(true, nil, iso)
			assert_true(iso, "unknown holds")
			iso = uplinkmon.decide(true, true, iso)
			assert_false(iso, "recovery is immediate, as the firmware's")
			iso = uplinkmon.decide(true, false, iso)
			assert_false(iso, "and the failure count starts again from nothing")
			assert_false(uplinkmon.decide(false, false, true), "switched off: never isolated")
		end
	},
	{
		name = "uplinkmon: reachable() pings the default gateway, or the named host, and only safe names",
		fn = function()
			local orig_exec, orig_popen = uplinkmon._exec, uplinkmon._popen
			local cmds = {}
			uplinkmon._popen = function() return "default via 192.0.2.1 dev br-lan proto dhcp\n" end
			uplinkmon._exec = function(c) cmds[#cmds + 1] = c; return 0 end
			local a = uplinkmon.reachable()
			local b = uplinkmon.reachable("198.51.100.7")
			local c = uplinkmon.reachable("x; reboot") or uplinkmon.reachable("-f")
			uplinkmon._popen = function() return "" end
			local d = uplinkmon.reachable()
			uplinkmon._exec = function() return 1 end
			uplinkmon._popen = function() return "default via 192.0.2.1 dev br-lan\n" end
			local e = uplinkmon.reachable()
			uplinkmon._exec, uplinkmon._popen = orig_exec, orig_popen
			assert_true(a, "gateway answered")
			assert_eq(cmds[1], "ping -c 2 -W 2 192.0.2.1 >/dev/null 2>&1", "the default gateway")
			assert_true(b, "named host answered")
			assert_eq(cmds[2], "ping -c 2 -W 2 198.51.100.7 >/dev/null 2>&1", "the named host")
			assert_nil(c, "an unsafe name is never run")
			assert_eq(#cmds, 2, "nothing else ran")
			assert_nil(d, "no default route: unknown, not down")
			assert_false(e, "no answer: down")
		end
	},
	{
		name = "inform: _uplinkmon_resync takes the user SSIDs down on a dead uplink, never a VLAN netdev, and brings them back",
		fn = function()
			local orig = {uci = inform._ucihelper, save = inform._state.save,
				exec = uplinkmon._exec, popen = uplinkmon._popen, um = inform._uplinkmon}
			inform._uplinkmon = uplinkmon
			uplinkmon.decide(false)
			local answer = 1
			uplinkmon._popen = function() return "default via 192.0.2.1 dev br-lan\n" end
			uplinkmon._exec = function() return answer end
			inform._ucihelper = {
				ap_ifnames = function() return {"phy0-ap0", "phy1-ap0", "phy1-ap0-20"} end,
				bss_ifname = function(n) return n == "phy1-ap0-20" and "phy1-ap0" or n end,
			}
			local saves = 0
			inform._state.save = function() saves = saves + 1 end
			local links = {["phy0-ap0"] = true, ["phy1-ap0"] = true, ["phy1-ap0-20"] = true}
			local ok, err = pcall(with_links, links, function()
				local st = {uplinkmon_enabled = true}
				for _ = 1, uplinkmon.FAIL_TICKS - 1 do inform._uplinkmon_resync(st, {}) end
				assert_true(links["phy0-ap0"], "patience: still up")
				local log = with_stderr(function() assert_true(inform._uplinkmon_resync(st, {}), "changed") end)
				assert_false(links["phy0-ap0"], "2.4 GHz SSID down")
				assert_false(links["phy1-ap0"], "5 GHz SSID down")
				assert_true(links["phy1-ap0-20"], "the VLAN netdev is left to its BSS")
				assert_eq(table.concat(st.uplinkmon_down, " "), "phy0-ap0 phy1-ap0", "ledger")
				assert_eq(saves, 1, "saved")
				assert_true(log:find("SSIDs off the air", 1, true) ~= nil, "said so")
				answer = 0
				log = with_stderr(function() inform._uplinkmon_resync(st, {}) end)
				assert_true(links["phy0-ap0"] and links["phy1-ap0"], "the first answer: back")
				assert_nil(st.uplinkmon_down, "ledger cleared")
				assert_true(log:find("SSIDs back", 1, true) ~= nil, "said so")
			end)
			inform._ucihelper, inform._state.save, inform._uplinkmon = orig.uci, orig.save, orig.um
			uplinkmon._exec, uplinkmon._popen = orig.exec, orig.popen
			if not ok then error(err, 0) end
		end
	},
	{
		name = "inform: _uplinkmon_resync is off unless the controller or conf.lua turns it on, and lets go when switched off",
		fn = function()
			local orig = {uci = inform._ucihelper, save = inform._state.save,
				exec = uplinkmon._exec, popen = uplinkmon._popen, um = inform._uplinkmon}
			inform._uplinkmon = uplinkmon
			uplinkmon.decide(false)
			local pinged = 0
			uplinkmon._popen = function() return "default via 192.0.2.1 dev br-lan\n" end
			uplinkmon._exec = function() pinged = pinged + 1; return 1 end
			inform._ucihelper = {ap_ifnames = function() return {"phy0-ap0"} end}
			inform._state.save = function() end
			local links = {["phy0-ap0"] = true}
			local ok, err = pcall(with_links, links, function()
				local st = {}
				for _ = 1, 10 do inform._uplinkmon_resync(st, {}) end
				assert_eq(pinged, 0, "off by default: not even a ping")
				for _ = 1, uplinkmon.FAIL_TICKS do inform._uplinkmon_resync(st, {config = {uplink_monitor = true}}) end
				assert_false(links["phy0-ap0"], "conf.lua forces it on")
				with_stderr(function() inform._uplinkmon_resync(st, {config = {uplink_monitor = false}}) end)
				assert_true(links["phy0-ap0"], "forced off while isolated: back on the air at once")
				assert_nil(st.uplinkmon_down, "ledger cleared")
			end)
			inform._ucihelper, inform._state.save, inform._uplinkmon = orig.uci, orig.save, orig.um
			uplinkmon._exec, uplinkmon._popen = orig.exec, orig.popen
			if not ok then error(err, 0) end
		end
	},
	{
		name = "inform: the monitor and the WLAN schedule never bring up each other's SSIDs",
		fn = function()
			local orig = {uci = inform._ucihelper, save = inform._state.save, ct = inform._clock_trusted,
				exec = uplinkmon._exec, popen = uplinkmon._popen, um = inform._uplinkmon}
			inform._uplinkmon = uplinkmon
			uplinkmon.decide(false)
			uplinkmon._popen = function() return "default via 192.0.2.1 dev br-lan\n" end
			local answer = 1
			uplinkmon._exec = function() return answer end
			-- A schedule that is always "on" and one that is always "off".
			local always = {}
			for d = 0, 6 do always[#always + 1] = d .. "=00:00-23:59" end
			local never = {}
			for d = 0, 6 do never[#never + 1] = d .. "=00:01-00:00" end
			local sched = {{ifnames = {"phy0-ap0"}, lines = always}}
			inform._ucihelper = {
				ap_ifnames = function() return {"phy0-ap0", "phy1-ap0"} end,
				schedule_vaps = function() return sched end,
			}
			inform._clock_trusted = function() return true end
			inform._state.save = function() end
			local links = {["phy0-ap0"] = true, ["phy1-ap0"] = true}
			local ok, err = pcall(with_links, links, function()
				local st = {uplinkmon_enabled = true}
				with_stderr(function()
					for _ = 1, uplinkmon.FAIL_TICKS do inform._uplinkmon_resync(st, {}) end
				end)
				assert_false(links["phy0-ap0"], "uplink dead: down")
				-- The schedule is in its on-time: it must not bring it back.
				with_stderr(function() inform._sched_resync(st) end)
				assert_false(links["phy0-ap0"], "the schedule leaves the monitor's SSID down")
				-- Now the schedule turns it off, and the uplink comes back.
				sched[1].lines = never
				with_stderr(function() inform._sched_resync(st) end)
				answer = 0
				with_stderr(function()
					inform._uplinkmon_resync(st, {})
					inform._uplinkmon_resync(st, {})
				end)
				assert_true(links["phy1-ap0"], "the unscheduled SSID is back")
				assert_false(links["phy0-ap0"], "the scheduled one stays down: the schedule holds it")
			end)
			inform._ucihelper, inform._state.save, inform._clock_trusted, inform._uplinkmon =
				orig.uci, orig.save, orig.ct, orig.um
			uplinkmon._exec, uplinkmon._popen = orig.exec, orig.popen
			if not ok then error(err, 0) end
		end
	},
	{
		name = "inform: a push's connectivity block sets the monitor's switch and host, and its absence clears them",
		fn = function()
			local st = {}
			local u = uplinkmon.parse("connectivity.status=enabled\nconnectivity.uplink=192.0.2.9\n")
			st.uplinkmon_enabled = (u and u.enabled) or nil
			st.uplinkmon_host = u and (u.host or u.gateway) or nil
			assert_true(st.uplinkmon_enabled, "on")
			assert_eq(st.uplinkmon_host, "192.0.2.9", "host")
			u = uplinkmon.parse("wireless.1.ssid=x\n")
			st.uplinkmon_enabled = (u and u.enabled) or nil
			st.uplinkmon_host = u and (u.host or u.gateway) or nil
			assert_nil(st.uplinkmon_enabled, "no block: off")
		end
	},
}
