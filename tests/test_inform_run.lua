-- Tests for inform.run()'s startup: what it restores, in what order, and
-- that no single failing step stops the daemon before its first heartbeat.
-- Run from project root: lua tests/run_tests.lua
--
-- run() ends in `while true do M._cycle(...) end`. Every seam it calls is
-- stubbed with a recorder, and the stub _cycle raises a sentinel, so one
-- pcall(run) is exactly the startup plus the first heartbeat's arguments.

OPENUF_TEST_MODE = true
if not ufpkt then dofile("openuf/lib/lib.lua") end
local inform = dofile("openuf/inform.lua")

local STOP = {}

-- opts.st: what state.load returns. opts.fail[name] = true makes that
-- seam raise. opts.led_active: what locate_active answers. opts.identity:
-- what ensure_bridge_identity returns. Returns the call log and the
-- arguments _cycle got.
local function start(cfg, ufhw, opts)
	opts = opts or {}
	local calls, saved, cyc, logged = {}, {}, nil, {}
	local function rec(name, ret)
		return function(...)
			calls[#calls + 1] = {name = name, args = {...}}
			if opts.fail and opts.fail[name] then error(name .. " failed") end
			return ret
		end
	end
	local st = opts.st or {}
	local seams = {
		_reapply_static_ip = rec("reapply_static_ip"),
		_populate_net_info = rec("populate_net_info"),
		_warn_identity_change = rec("warn_identity_change"),
		_warn_missing_uci = rec("warn_missing_uci"),
		_warn_debug_overrides = rec("warn_debug_overrides"),
		_sync_bootstrap_account = rec("sync_bootstrap_account"),
		_reconcile_plugins = rec("reconcile_plugins"),
		_reapply_airtime = rec("reapply_airtime"),
		_meshvlan_resync = rec("meshvlan_resync"),
		_guest_enforce = rec("guest_enforce"),
		_l2guard_live_ifnames = function() return {} end,
		_state_mtime = function() return 42 end,
		_unhandled = {_file = "unset", load = rec("unhandled.load")},
		_ucihelper = {ensure_bridge_identity = rec("ensure_bridge_identity", opts.identity),
			reapply_runtime_rules = rec("reapply_runtime_rules"), _network_dirty = true},
		_sysinfo = {_run_cmd = rec("run_cmd")},
		_firewall = {reconcile = rec("firewall.reconcile")},
		_led = {locate_active = rec("led.locate_active", opts.led_active),
			locate_stop = rec("led.locate_stop"), set_enabled = rec("led.set_enabled")},
		_switchvlan = {enable_mib_polling = rec("enable_mib_polling"),
			reconcile_mac_taps = rec("reconcile_mac_taps")},
		_l2guard = {reconcile = rec("l2guard.reconcile")},
		_guestportal = {},
		_cycle = function(...)
			cyc = {...}
			error(STOP, 0)
		end,
	}
	local orig = {}
	for k, v in pairs(seams) do orig[k] = inform[k]; inform[k] = v end
	-- state is a module-local upvalue in inform.lua: patch the shared table.
	local o_load, o_save = inform._state.load, inform._state.save
	inform._state.load = function() return st end
	inform._state.save = function(s) saved[#saved + 1] = s end
	local o_model, o_err = inform._model, io.stderr
	io.stderr = {write = function(_, m) logged[#logged + 1] = m end}
	local ok, err = pcall(inform.run, cfg, ufhw)
	io.stderr = o_err
	inform._state.load, inform._state.save = o_load, o_save
	local model = inform._model
	inform._model = o_model
	local ucih = inform._ucihelper
	for k in pairs(seams) do inform[k] = orig[k] end
	assert_false(ok, "run() blocks: only the stub heartbeat ends it")
	assert_true(err == STOP, "it reached the first heartbeat: " .. tostring(err))
	return {calls = calls, saved = saved, cycle = cyc, logged = logged, st = st,
		model = model, unhandled_file = seams._unhandled._file, ucih = ucih}
end

local function index_of(r, name)
	for i, c in ipairs(r.calls) do
		if c.name == name then return i end
	end
	return nil
end

local function has_log(r, text)
	for _, l in ipairs(r.logged) do
		if l:find(text, 1, true) then return true end
	end
	return false
end

return {
	{
		name = "inform.run: startup restores live state, then hands st/cfg/ufhw to the first heartbeat",
		fn = function()
			local cfg = {led = "test:green", config = {unhandled_file = "/tmp/x.json"}}
			local ufhw = {uap = {model = "UHDIW"}}
			local r = start(cfg, ufhw, {st = {adopted = true, blocked_stas = {"b"}}})
			assert_eq(r.unhandled_file, "/tmp/x.json", "conf.lua's unhandled_file is honoured")
			assert_not_nil(index_of(r, "unhandled.load"), "the ledger is loaded")
			assert_eq(r.model, "UHDIW", "the identity's model is kept for the beacon name")
			-- The static IP goes back before the identity fields are read.
			assert_true(index_of(r, "reapply_static_ip") < index_of(r, "populate_net_info"),
				"static IP before the address is read")
			for _, n in ipairs({"firewall.reconcile", "reapply_runtime_rules", "reapply_airtime",
					"enable_mib_polling", "reconcile_mac_taps", "meshvlan_resync",
					"sync_bootstrap_account", "reconcile_plugins"}) do
				assert_not_nil(index_of(r, n), n .. " runs at startup")
			end
			assert_eq(r.calls[index_of(r, "firewall.reconcile")].args[1][1], "b",
				"blocked clients come from state.json")
			assert_eq(r.calls[index_of(r, "sync_bootstrap_account")].args[1], true, "with the adopted flag")
			assert_nil(index_of(r, "led.set_enabled"), "no led_enabled pushed: the board's LED is left alone")
			assert_nil(index_of(r, "run_cmd"), "no identity change: no network reload")
			assert_true(r.cycle[1] == r.st and r.cycle[2] == cfg and r.cycle[3] == ufhw,
				"the heartbeat gets the loaded state, cfg and ufhw")
			assert_eq(r.cycle[4].interval, 10, "first interval")
			assert_eq(r.cycle[4].last_mtime, 42, "state.json's mtime is the baseline")
		end
	},
	{
		name = "inform.run: a Locate is undone before the LED's steady state is applied",
		fn = function()
			local r = start({led = "l"}, nil, {led_active = true,
				st = {locating = true, locate_prev_trigger = "phy0tpt", led_enabled = false}})
			local stop, set = index_of(r, "led.locate_stop"), index_of(r, "led.set_enabled")
			assert_not_nil(stop, "a still-blinking Locate is stopped")
			assert_eq(r.calls[stop].args[2], "phy0tpt", "back to the persisted trigger")
			assert_true(set > stop, "the operator's LED choice wins, applied after")
			assert_eq(r.calls[set].args[2], false, "with the stored value")
			assert_false(r.st.locating, "locating cleared")
			assert_nil(r.st.locate_prev_trigger, "and its snapshot")
			assert_eq(#r.saved, 1, "and saved")
			-- Rebooted mid-Locate: the kernel already restored the trigger.
			r = start({led = "l"}, nil, {led_active = false, st = {locating = true}})
			assert_nil(index_of(r, "led.locate_stop"), "nothing to stop: never writes over it")
			assert_false(r.st.locating, "still cleared")
		end
	},
	{
		name = "inform.run: a failing startup step is logged and the daemon still reaches its heartbeat",
		fn = function()
			local r = start({}, nil, {fail = {["unhandled.load"] = true, reapply_static_ip = true,
				ensure_bridge_identity = true, reapply_runtime_rules = true, meshvlan_resync = true}})
			assert_true(has_log(r, "could not load the unhandled ledger"), "ledger")
			assert_true(has_log(r, "could not reapply static IP"), "static IP")
			assert_true(has_log(r, "could not reconcile bridge identity"), "bridge identity")
			assert_true(has_log(r, "could not reapply the blocker rules"), "blocker rules")
			assert_not_nil(r.cycle, "heartbeat reached")
		end
	},
	{
		name = "inform.run: a bridge identity change reloads the network and re-reads the address",
		fn = function()
			local r = start({}, nil, {identity = true})
			local reload = index_of(r, "run_cmd")
			assert_not_nil(reload, "netifd is told")
			assert_contains(r.calls[reload].args[1], "/etc/init.d/network reload", "a network reload")
			assert_false(r.ucih._network_dirty, "the dirty flag is consumed")
			local n = 0
			for _, c in ipairs(r.calls) do
				if c.name == "populate_net_info" then n = n + 1 end
			end
			assert_eq(n, 2, "the address is read again after the reload")
		end
	},
}
