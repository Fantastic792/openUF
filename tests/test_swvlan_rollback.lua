-- Commit-confirm for switch VLAN pushes (audit #10 option B):
-- inform._arm_swvlan_rollback / _swvlan_rollback_check / _swvlan_rollback_boot
-- in openuf/mainloop.lua. Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true
dofile("openuf/lib/lib.lua")

local STATE_FILE = "/tmp/openuf_test_swvlan_rollback.json"
local CFG = {net = {lan_cpueth = "eth0"}}
local SYS = "aaa.1.ssid=openuf-test\naaa.1.wpa=2\nwireless.1.ssid=openuf-test\nwireless.1.parent=radio0\n"

-- A fresh inform module with every side effect stubbed. h.restores counts
-- switchvlan.restore calls; h.changed is what switchvlan.apply returns.
local function fresh()
	local inform = dofile("openuf/inform.lua")
	inform._state._state_file = STATE_FILE
	inform._firewall = {reconcile = function() end, deauth = function() end,
		hostapd_sockets = function() return "" end, deny_sync = function() return false end}
	inform._shaper = {sync = function() return true end}
	inform._meshvlan = {record = function() return nil end, reconcile = function() return true end,
		resync = function() return true end}
	inform._guestportal._exec = function() return 0 end
	inform._guestportal.listen = function() return {close = function() end} end
	inform._netconfig._exec = function() return true end
	inform._netconfig._read = function() return "" end
	inform._usteer.set_enabled = function() end
	inform._sysinfo.lan_bridge = function() return nil end
	inform._sysconf = {parse = function() return nil end, apply = function() return {} end,
		apply_cron = function() return false end}
	inform._ucihelper = {apply_config = function() end}
	inform._l2guard_apply_push = function() end
	inform.STATUS_FILE = os.tmpname()
	local h = {inform = inform, now = 0, restores = 0, changed = true}
	inform._time = function() return h.now end
	inform._switchvlan = {
		apply = function(_, _, st)
			if h.changed then st.swvlan_backup = st.swvlan_backup or {["1"] = "0 1 2 3 6t"} end
			return h.changed
		end,
		restore = function(st)
			h.restores = h.restores + 1
			st.swvlan_backup = nil
			return true
		end,
	}
	return h
end

local function quiet(h, fn)
	local err = io.stderr
	io.stderr = {write = function() end}
	local ok, e = pcall(fn)
	io.stderr = err
	os.remove(h.inform.STATUS_FILE); os.remove(h.inform.STATUS_FILE .. ".tmp")
	os.remove(STATE_FILE)
	if not ok then error(e, 0) end
end

local function push(ver)
	return ('{"_type":"setparam","mgmt_cfg":"cfgversion=%s\\n","system_cfg":"%s"}')
		:format(ver, (SYS:gsub("\n", "\\n")))
end

return {
	{
		name = "test_swvlan_confirm_on_reply",
		fn = function()
			local h = fresh()
			quiet(h, function()
				local st = {cfgversion = "v1", adopted = true}
				h.changed, h.now = false, 100
				h.inform.handle_response(push("v2"), st, CFG)
				assert_nil(st.swvlan_rollback, "a switch pass that changed nothing does not arm")
				h.changed = true
				h.inform.handle_response(push("v3"), st, CFG)
				assert_true(type(st.swvlan_rollback) == "table", "a switch VLAN change arms")
				assert_eq(st.swvlan_rollback.at, 100, "with the time")
				assert_true(type(h.inform._state.load().swvlan_rollback) == "table", "saved to disk")
				assert_eq(h.inform._swvlan_rollback_check(st, CFG, true, 110), "confirmed", "a reply confirms")
				assert_nil(st.swvlan_rollback, "record spent")
				assert_nil(h.inform._state.load().swvlan_rollback, "and saved")
				assert_eq(h.restores, 0, "nothing restored")
			end)
		end
	},
	{
		name = "test_swvlan_rollback_after_window",
		fn = function()
			local h = fresh()
			quiet(h, function()
				local st = {cfgversion = "v3", adopted = true, swvlan_backup = {["1"] = "0 1 2 3 6t"}}
				h.inform._arm_swvlan_rollback(st, 0)
				local check = h.inform._swvlan_rollback_check
				assert_nil(check(st, CFG, false, 10), "first miss")
				assert_nil(check(st, CFG, false, 20), "second miss")
				assert_nil(check(st, CFG, false, 30), "three misses but inside 90 s")
				assert_eq(h.restores, 0, "nothing restored yet")
				assert_eq(check(st, CFG, false, 90), "rolled_back", "three misses and 90 s")
				assert_eq(h.restores, 1, "switchvlan.restore called once")
				assert_contains(st.push_fail_stages or "", "swvlan_rollback", "stage recorded")
				assert_eq(st.cfgversion, "v3", "cfgversion kept, so no re-push loop")
				assert_nil(st.swvlan_rollback, "record spent")
				-- Time alone is not enough: one miss long after the arm waits.
				st.swvlan_backup = {["1"] = "0 1 2 3 6t"}
				h.inform._arm_swvlan_rollback(st, 1000)
				assert_nil(check(st, CFG, false, 5000), "one miss, long after")
				assert_eq(h.restores, 1, "still one restore")
			end)
		end
	},
	{
		name = "test_swvlan_rollback_own_hint",
		fn = function()
			local h = fresh()
			local log = {}
			quiet(h, function()
				local st = {cfgversion = "v3", adopted = true, swvlan_backup = {["1"] = "0 1 2 3 6t"}}
				h.inform._arm_swvlan_rollback(st, 0)
				-- quiet() swallows stderr; capture inside it.
				io.stderr = {write = function(_, s) log[#log + 1] = s end}
				h.inform._swvlan_rollback_check(st, CFG, false, 10)
				h.inform._swvlan_rollback_check(st, CFG, false, 20)
				h.inform._swvlan_rollback_check(st, CFG, false, 90)
			end)
			local out = table.concat(log)
			assert_true(h.inform.SWVLAN_HINT ~= h.inform.PUSH_HINT, "its own hint, not the generic one")
			assert_contains(out, h.inform.SWVLAN_HINT, "the rollback line carries it")
			assert_false(out:find(h.inform.PUSH_HINT, 1, true) ~= nil, "no plain Force Provision")
		end
	},
	{
		name = "test_swvlan_forget_clears_rollback",
		fn = function()
			local h = fresh()
			quiet(h, function()
				local st = {cfgversion = "v3", adopted = true, swvlan_backup = {["1"] = "0 1 2 3 6t"}}
				h.inform._arm_swvlan_rollback(st, 0)
				local prev = {}
				for k, v in pairs(st) do prev[k] = v end
				h.inform._forget_controller(prev, CFG, st)
				assert_nil(st.swvlan_rollback, "an unadopt spends the pending rollback")
				for t = 10, 200, 40 do
					assert_nil(h.inform._swvlan_rollback_check(st, CFG, false, t), "no false status after")
				end
				assert_nil(st.push_fail_stages, "no swvlan_rollback stage written")
			end)
		end
	},
	{
		name = "test_swvlan_rollback_once",
		fn = function()
			local h = fresh()
			quiet(h, function()
				local st = {cfgversion = "v3", adopted = true, swvlan_backup = {["1"] = "0 1 2 3 6t"}}
				h.inform._arm_swvlan_rollback(st, 0)
				for t = 10, 90, 40 do h.inform._swvlan_rollback_check(st, CFG, false, t) end
				h.inform._swvlan_rollback_check(st, CFG, false, 200)
				assert_eq(h.restores, 1, "rolled back once")
				for t = 300, 3000, 100 do
					assert_nil(h.inform._swvlan_rollback_check(st, CFG, false, t), "nothing more")
				end
				assert_eq(h.restores, 1, "restore not called again")
			end)
		end
	},
	{
		name = "test_swvlan_and_ip_both_armed",
		fn = function()
			local h = fresh()
			quiet(h, function()
				local inform = h.inform
				inform.build_json = function() return '{"_type":"state"}' end
				inform._announce = {get_ip = function() return nil end}
				inform._state_mtime = function() return 1 end
				inform._rrmscan = nil
				local st = {cfgversion = "v3", adopted = true, authkey = inform._state.DEFAULT_KEY,
					inform_url = "http://192.0.2.1:8080/inform", mac = "00:00:5e:00:53:01",
					swvlan_backup = {["1"] = "0 1 2 3 6t"}}
				local snap = {addrs = {"192.0.2.10/24"}, gw = "192.0.2.1", dns = {}}
				h.now = 5000
				st.ip_rollback = {at = 5000, snap = snap}
				inform._arm_swvlan_rollback(st, 5000)
				local ctx = {interval = 10, backoff = 10, last_mtime = 1}
				inform._http_post = function() return nil, "HTTP nil" end
				inform._tick(st, CFG, nil, ctx)
				assert_eq(st.ip_rollback.fails, 1, "a miss counts for the address")
				assert_eq(st.swvlan_rollback.fails, 1, "and for the switch")
				inform._http_post = function() return inform.build_packet('{"_type":"noop"}', st) end
				inform._tick(st, CFG, nil, ctx)
				assert_nil(st.ip_rollback, "one reply confirms the address")
				assert_nil(st.swvlan_rollback, "and the switch VLANs")
				assert_eq(h.restores, 0, "nothing restored")
			end)
		end
	},
	{
		name = "test_swvlan_boot_with_rollback_pending",
		fn = function()
			local h = fresh()
			quiet(h, function()
				local st = {cfgversion = "v3", adopted = true, swvlan_backup = {["1"] = "0 1 2 3 6t"},
					swvlan_rollback = {at = 1, fails = 2}}
				h.now = 7000
				h.inform._swvlan_rollback_boot(st)
				assert_eq(st.swvlan_rollback.fails, 0, "boot resets the count")
				assert_eq(st.swvlan_rollback.at, 7000, "and the clock")
				assert_nil(h.inform._swvlan_rollback_check(st, CFG, false, 7010), "a miss right after boot waits")
				assert_eq(h.restores, 0, "nothing restored")
			end)
		end
	},
}
