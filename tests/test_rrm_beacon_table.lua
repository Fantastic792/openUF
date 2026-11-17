-- 802.11k beacon requests for beacon-table-only clients.
-- Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true
dofile("openuf/lib/lib.lua")

local rrmscan = dofile("openuf/rrmscan.lua")

-- get_clients: active+passive (0x30), every mode (0xF9), table only (0x40), none.
local CLIENTS = '{"freq":5180,"clients":{' ..
	'"00:00:5e:00:53:01":{"auth":true,"rrm":[48,0,0,0,0]},' ..
	'"00:00:5e:00:53:02":{"auth":true,"rrm":[249,0,0,0,0]},' ..
	'"00:00:5e:00:53:03":{"auth":true,"rrm":[64,0,0,0,0]},' ..
	'"00:00:5e:00:53:04":{"auth":true,"rrm":[0,0,0,0,0]}}}'

local function stations()
	local orig = rrmscan._popen
	rrmscan._popen = function() return CLIENTS end
	local ok, stas, modes = pcall(rrmscan.capable_stations, "phy1-ap0")
	rrmscan._popen = orig
	assert(ok, stas)
	local set = {}
	for _, m in ipairs(stas) do set[m] = true end
	return set, modes or {}
end

-- _rrm_tick against one table-only station; returns the opts of each request.
local function tick_table_only(times)
	local inform = dofile("openuf/inform.lua")
	local reqs, t = {}, 5000
	inform._rrmscan = {
		collector_ensure = function() end,
		harvest          = function() return {} end,
		hostapd_objects  = function() return {"hostapd.phy1-ap0"} end,
		capable_stations = function()
			return {"00:00:5e:00:53:03"}, {["00:00:5e:00:53:03"] = 2}
		end,
		request          = function(_, _, opts) reqs[#reqs + 1] = opts or {} end,
	}
	inform._sysinfo = {radio_caps = function() return {channel = 36} end}
	inform._time = function() return t end
	local err = io.stderr
	io.stderr = {write = function() end}
	local ok, e = pcall(function()
		local cfg = {config = {rrm_request_interval = 600}}
		for _, at in ipairs(times) do t = at; inform._rrm_tick(cfg) end
	end)
	io.stderr = err
	assert(ok, e)
	return reqs
end

return {
	{
		name = "test_table_only_station_is_asked",
		fn = function()
			local set, modes = stations()
			assert_true(set["00:00:5e:00:53:03"], "beacon-table-only client is asked")
			assert_eq(modes["00:00:5e:00:53:03"], 2, "in table mode")
		end
	},
	{
		name = "test_active_station_keeps_mode_1",
		fn = function()
			local set, modes = stations()
			assert_true(set["00:00:5e:00:53:01"] and set["00:00:5e:00:53:02"], "active clients asked")
			assert_eq(modes["00:00:5e:00:53:01"], 1, "0x30: active mode")
			assert_eq(modes["00:00:5e:00:53:02"], 1, "0xF9 (table too): still active mode")
		end
	},
	{
		name = "test_no_rrm_station_skipped",
		fn = function()
			local set, modes = stations()
			assert_nil(set["00:00:5e:00:53:04"], "rrm 0 is not asked")
			assert_nil(modes["00:00:5e:00:53:04"], "and has no mode")
		end
	},
	{
		name = "test_table_request_sends_mode_2",
		fn = function()
			local reqs = tick_table_only({5000})
			assert_eq(#reqs, 1, "one request")
			assert_eq(reqs[1].mode, 2, "_rrm_tick asks in table mode")
			local orig, cmd = rrmscan._exec, nil
			rrmscan._exec = function(c) cmd = c end
			rrmscan.request("phy1-ap0", "00:00:5e:00:53:03", {mode = 2})
			rrmscan._exec = orig
			assert_contains(cmd, '"mode":2', "rrm_beacon_req carries mode 2")
		end
	},
	{
		name = "test_table_only_silent_is_benched",
		fn = function()
			-- Two unanswered asks, then nothing inside the 6 h bench.
			local reqs = tick_table_only({5000, 5600, 6200, 6800, 9000})
			assert_eq(#reqs, 2, "benched after two unanswered table requests")
			assert_eq(reqs[2].mode, 2, "both in table mode")
		end
	},
}
