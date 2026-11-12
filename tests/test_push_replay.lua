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
	return ('{"_type":"setparam","mgmt_cfg":"cfgversion=%s\\n","system_cfg":"%s"}')
		:format(ver, ((sys or SYS):gsub("\n", "\\n")))
end

-- A _tick whose controller answers with reply (or a noop) and records the
-- state the tick ran on; _push_replay_tick runs only after such an answer.
local function tick_env(h, st)
	local inform = h.inform
	inform.build_json = function() return '{"_type":"state"}' end
	inform._announce = {get_ip = function() return nil end}
	inform._state_mtime = function() return 1 end
	inform._rrmscan = nil
	st.authkey = inform._state.DEFAULT_KEY
	st.inform_url = "http://192.0.2.1:8080/inform"
	st.mac = "00:00:5e:00:53:01"
	local ctx = {interval = 10, backoff = 10, last_mtime = 1}
	return function(reply)
		inform._http_post = function()
			return inform.build_packet(reply or '{"_type":"noop"}', st)
		end
		inform._tick(st, CFG, nil, ctx)
	end
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
				assert_eq(h.l2, 1, "the push ran l2guard once")
				h.l2_boom = false
				-- The daemon restarts: a fresh module, the same state file/st.
				local h2 = fresh()
				local tick2 = tick_env(h2, st)
				h2.now = 1000
				tick2(); tick2()
				assert_eq(h2.l2, 0, "the restarted module replays nothing through _tick")
				assert_eq(st.push_fail_stages, "l2guard", "the failed-stage record stays")
				-- Control: the module that armed it does replay at that time.
				h.now = 1000
				tick_env(h, st)()
				assert_eq(h.l2, 2, "the old module would have replayed")
			end)
		end
	},
	{
		name = "test_replay_runs_through_tick",
		fn = function()
			local h = fresh()
			quiet(h, function()
				local st = {cfgversion = "v1", adopted = true}
				local tick = tick_env(h, st)
				h.l2_boom, h.now = true, 100
				tick(push("v2"))
				assert_eq(st.push_fail_stages, "l2guard", "the pushed stage failed")
				h.l2_boom, h.now = false, 120
				tick()
				assert_eq(h.l2, 1, "not due at 20 s")
				h.now = 131
				tick()
				assert_eq(h.l2, 2, "replayed once the delay is up, after a good reply")
				assert_nil(st.push_fail_stages, "record cleared")
			end)
		end
	},
	{
		name = "test_cfgversion_push_updates_replay",
		fn = function()
			local h = fresh()
			quiet(h, function()
				local st = {cfgversion = "v1", adopted = true}
				h.wifi_boom = true
				h.inform.handle_response(push("v2"), st, CFG)
				assert_eq(st.cfgversion, "v1", "failed WiFi holds the cfgversion back")
				-- A newer cfgversion with no system_cfg.
				h.inform.handle_response('{"_type":"setparam","mgmt_cfg":"cfgversion=v3\n"}', st, CFG)
				assert_eq(st.cfgversion, "v3", "recorded")
				h.wifi_boom = false
				assert_true(h.inform._push_replay_tick(st, CFG, 30), "replayed")
				assert_eq(st.cfgversion, "v3", "the replay does not write the older cfgversion back")
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
	{
		name = "test_forget_controller_drops_replay",
		fn = function()
			local h = fresh()
			quiet(h, function()
				local st = {cfgversion = "v1", adopted = true}
				h.l2_boom = true
				h.inform.handle_response(push("v2"), st, CFG)
				pcall(h.inform._forget_controller, st, CFG)
				local n = h.l2
				assert_false(h.inform._push_replay_tick(st, CFG, 30), "no replay after a reset/unadopt")
				assert_eq(h.l2, n, "the old site's push is not put back")
			end)
		end
	},
	{
		name = "test_raising_push_drops_old_replay",
		fn = function()
			local h = fresh()
			quiet(h, function()
				local st = {cfgversion = "v1", adopted = true}
				h.l2_boom = true
				h.inform.handle_response(push("v2"), st, CFG)
				local parse = h.inform._parse_net_system_cfg
				h.inform._parse_net_system_cfg = function() error("boom") end
				pcall(h.inform.handle_response, push("v3"), st, CFG)
				h.inform._parse_net_system_cfg = parse
				local n = h.l2
				assert_false(h.inform._push_replay_tick(st, CFG, 30), "the older copy is not replayed over the newer push")
				assert_eq(h.l2, n, "nothing replayed")
			end)
		end
	},
	{
		name = "test_wifi_replay_reruns_meshvlan",
		fn = function()
			local h = fresh()
			quiet(h, function()
				local mv = 0
				h.inform._meshvlan_push = function() mv = mv + 1 end
				local st = {cfgversion = "v1", adopted = true}
				h.wifi_boom = true
				h.inform.handle_response(push("v2"), st, CFG)
				local before = mv
				h.wifi_boom = false
				assert_true(h.inform._push_replay_tick(st, CFG, 30), "replayed")
				assert_eq(mv, before + 1, "meshvlan re-runs after the replayed WiFi pass builds the bridges")
			end)
		end
	},
}
