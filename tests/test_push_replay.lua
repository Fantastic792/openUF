-- Replay of a partly failed config push from RAM (audit #4 option B):
-- inform._push_replay_arm / _push_replay_tick in openuf/mainloop.lua.
-- Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true
dofile("openuf/lib/lib.lua")

local STATE_FILE = "/tmp/openuf_test_push_replay.json"
local CFG = {net = {lan_cpueth = "eth0"}}
local SYS = "aaa.1.ssid=openuf-test\naaa.1.wpa=2\nwireless.1.ssid=openuf-test\nwireless.1.parent=radio0\n"

-- A fresh inform module (a daemon start) with every side effect stubbed.
-- h.reloads counts apply_config runs: the real one ends in an unconditional
-- `wifi reload`, so a replay that calls it reloads the radios.
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
	inform._switchvlan = {apply = function() end, restore = function() end}
	inform._sysconf = {parse = function() return nil end, apply = function() return {} end,
		apply_cron = function() return false end}
	inform.STATUS_FILE = os.tmpname()
	local h = {inform = inform, reloads = 0, l2 = 0, l2_boom = false, wifi_boom = false, l2_seen = nil,
		now = 0}
	inform._time = function() return h.now end
	inform._ucihelper = {apply_config = function()
		h.reloads = h.reloads + 1
		if h.wifi_boom then error("uci: boom") end
	end}
	inform._l2guard_apply_push = function(sys_raw)
		h.l2, h.l2_seen = h.l2 + 1, sys_raw
		if h.l2_boom then error("nft: boom") end
	end
	return h
end

local function push(ver, sys)
	return ('{"_type":"setparam","mgmt_cfg":"cfgversion=%s\n","system_cfg":"%s"}')
		:format(ver, ((sys or SYS):gsub("\n", "\n")))
end

-- Runs fn with stderr silenced and the module's status file cleaned up.
local function quiet(h, fn)
	local err = io.stderr
	io.stderr = {write = function() end}
	local ok, e = pcall(fn)
	io.stderr = err
	os.remove(h.inform.STATUS_FILE); os.remove(h.inform.STATUS_FILE .. ".tmp")
	os.remove(STATE_FILE)
	if not ok then error(e, 0) end
end

return {
	{
		name = "test_replay_schedule",
		fn = function()
			local h = fresh()
			quiet(h, function()
				local st = {cfgversion = "v1", adopted = true}
				h.l2_boom = true
				h.inform.handle_response(push("v2"), st, CFG)
				assert_eq(st.push_fail_stages, "l2guard", "push record names the stage")
				local tick = h.inform._push_replay_tick
				assert_false(tick(st, CFG, 29), "not before 30 s")
				assert_true(tick(st, CFG, 30), "first replay at 30 s")
				assert_false(tick(st, CFG, 149), "not before 2 min after that")
				assert_true(tick(st, CFG, 150), "second replay 2 min later")
				assert_true(tick(st, CFG, 750), "third replay 10 min later")
				assert_false(tick(st, CFG, 2000), "then it gives up")
				assert_eq(h.l2, 4, "the push plus three replays ran l2guard")
				assert_eq(st.push_fail_stages, "l2guard", "given up: the #4 A record stays")
			end)
		end
	},
	{
		name = "test_replay_success_disarms",
		fn = function()
			local h = fresh()
			quiet(h, function()
				local st = {cfgversion = "v1", adopted = true}
				h.wifi_boom = true
				h.inform.handle_response(push("v2"), st, CFG)
				assert_eq(st.cfgversion, "v1", "a failed WiFi pass holds the cfgversion back")
				assert_eq(st.push_fail_stages, "wifi", "push record names wifi")
				h.wifi_boom = false
				assert_true(h.inform._push_replay_tick(st, CFG, 30), "replayed at 30 s")
				assert_nil(st.push_fail_stages, "failed record cleared")
				assert_eq(st.cfgversion, "v2", "the replayed WiFi pass records the cfgversion")
				local runs = h.reloads
				assert_false(h.inform._push_replay_tick(st, CFG, 150), "no second replay")
				assert_false(h.inform._push_replay_tick(st, CFG, 750), "nor a third")
				assert_eq(h.reloads, runs, "nothing ran after the good replay")
			end)
		end
	},
	{
		name = "test_replay_noop_no_reload",
		fn = function()
			local h = fresh()
			quiet(h, function()
				local st = {cfgversion = "v1", adopted = true}
				h.l2_boom = true
				h.inform.handle_response(push("v2"), st, CFG)
				h.reloads, h.l2_boom = 0, false
				assert_true(h.inform._push_replay_tick(st, CFG, 30), "replayed")
				assert_eq(h.l2, 2, "the failed stage ran again")
				assert_eq(h.reloads, 0, "the WiFi pass went through, so no wifi reload")
				assert_nil(st.push_fail_stages, "record cleared")
			end)
		end
	},
	{
		name = "test_replay_lost_on_restart",
		fn = function()
			local h = fresh()
			quiet(h, function()
				local st = {cfgversion = "v1", adopted = true}
				h.l2_boom = true
				h.inform.handle_response(push("v2"), st, CFG)
				local h2 = fresh()   -- the daemon restarted: a new module
				quiet(h2, function()
					assert_false(h2.inform._push_replay_tick(st, CFG, 30), "no replay after a restart")
					assert_eq(h2.l2, 0, "nothing ran")
				end)
				assert_eq(st.push_fail_stages, "l2guard", "st failed record unchanged")
			end)
		end
	},
	{
		name = "test_new_push_replaces_replay",
		fn = function()
			local h = fresh()
			quiet(h, function()
				local st = {cfgversion = "v1", adopted = true}
				h.l2_boom = true
				h.inform.handle_response(push("v2"), st, CFG)
				-- A newer push that fails too, with other content: its copy wins.
				local sys3 = SYS .. "system.timezone=UTC\n"
				h.now = 10
				h.inform.handle_response(push("v3", sys3), st, CFG)
				h.l2_boom = false
				assert_false(h.inform._push_replay_tick(st, CFG, 30), "schedule restarted at the new push")
				assert_true(h.inform._push_replay_tick(st, CFG, 40), "replays 30 s after it")
				assert_eq(h.l2_seen, sys3, "the replay carried the newer push")
				-- A newer push that applies drops the copy.
				h.l2_boom, h.now = true, 100
				h.inform.handle_response(push("v4"), st, CFG)
				h.l2_boom, h.now = false, 110
				h.inform.handle_response(push("v5"), st, CFG)
				local n = h.l2
				assert_false(h.inform._push_replay_tick(st, CFG, 130), "old copy dropped")
				assert_false(h.inform._push_replay_tick(st, CFG, 1000), "for good")
				assert_eq(h.l2, n, "nothing replayed")
			end)
		end
	},
}
