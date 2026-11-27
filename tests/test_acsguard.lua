-- Tests for openuf/acsguard.lua (a channel for a radio whose ACS gave up)
-- and its heartbeat in inform.lua. No device access: every seam is replaced.

local acsguard = dofile("openuf/acsguard.lua")
local inform = dofile("openuf/inform.lua")

return {
	{
		name = "acsguard: pick() takes the first non-DFS block start the radio may use",
		fn = function()
			assert_eq(acsguard.pick("ng", {1, 6, 13}), 1, "2.4 GHz: channel 1")
			assert_eq(acsguard.pick("ng", {1, 6, 13}, {"6", "13"}), 6, "the site's candidate list rules")
			assert_eq(acsguard.pick("na", {36, 40, 44, 48, 149}), 36, "5 GHz: 36")
			assert_eq(acsguard.pick("na", {149, 153}), 149, "no 36 here: 149")
			assert_nil(acsguard.pick("na", {52, 100}), "only DFS channels: no pick")
			assert_nil(acsguard.pick("na", nil), "unknown channel set: no pick")
			assert_nil(acsguard.pick("ng", {1, 6}, {"13"}), "nothing allowed: no pick")
		end
	},
	{
		name = "acsguard: decide() pins a radio only after WAIT seconds without a channel",
		fn = function()
			local since = {}
			local r = {name = "radio1", band = "na", legal = {36, 149}}
			assert_eq(#acsguard.decide({r}, since, 1000), 0, "first look: wait")
			assert_eq(#acsguard.decide({r}, since, 1059), 0, "59 s: still waiting")
			local out = acsguard.decide({r}, since, 1060)
			assert_eq(#out, 1, "60 s: pinned")
			assert_eq(out[1].name, "radio1"); assert_eq(out[1].channel, 36)
			assert_nil(since.radio1, "the clock starts over")
			acsguard.decide({r}, since, 2000)
			assert_eq(#acsguard.decide({}, since, 2030), 0, "channel back")
			assert_nil(since.radio1, "a radio that got its channel back is forgotten")
		end
	},
	{
		name = "inform: _acsguard_resync looks once a minute and pins what decide() returns",
		fn = function()
			local t, pins, looks = 1000, {}, 0
			local orig = {uci = inform._ucihelper, time = inform._time}
			inform._ucihelper = {
				acs_failing = function()
					looks = looks + 1
					return {{name = "radio0", band = "ng", legal = {1, 6, 11}}}
				end,
				acs_pin = function(r, ch) pins[#pins + 1] = r .. "=" .. ch end,
			}
			inform._time = function() return t end
			inform._acs_since, inform._acs_last = {}, nil
			local real, log = io.stderr, {}
			io.stderr = {write = function(_, ...) for _, s in ipairs({...}) do log[#log + 1] = s end end}
			local ok, err = pcall(function()
				inform._acsguard_resync()
				t = 1030; inform._acsguard_resync()
				assert_eq(looks, 1, "30 s later: not looked again")
				t = 1060; inform._acsguard_resync()
			end)
			io.stderr = real
			inform._ucihelper, inform._time = orig.uci, orig.time
			inform._acs_since, inform._acs_last = {}, nil
			if not ok then error(err, 0) end
			assert_eq(looks, 2, "looked twice")
			assert_eq(table.concat(pins, ","), "radio0=1", "pinned channel 1")
			assert_true(table.concat(log):find("acsguard: radio0", 1, true) ~= nil, "logged")
		end
	},
}
