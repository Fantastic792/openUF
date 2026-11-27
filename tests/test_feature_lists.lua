-- Tripwires for the places a controller-driven feature has to be in: its row
-- in mainloop.lua's M._FEATURES (tick, teardown, startup hooks), the phase
-- order lists, and state.lua's TYPED table. A feature in one and not the
-- others is a reboot bug or survives a Forget (audit 2026-11-10, finding 14).
--
-- Most read the table or the SOURCE. A failure here does not say the code is
-- wrong: it says a list changed and the others need a look. Then give the row
-- a forget hook or a forget_by story.
-- Run from project root: lua tests/run_tests.lua

local state = dofile("openuf/state.lua")

local function slurp(path)
	local f = assert(io.open(path, "r"))
	local s = f:read("*a")
	f:close()
	return s
end

local function strip_comments(src)
	return (src:gsub("%-%-[^\n]*", ""))
end

-- The text of top-level `function M.<name>(` up to its closing `end`.
local function body(src, name)
	local s = src:find("\nfunction M%." .. name:gsub("%p", "%%%0") .. "%(")
	assert(s, "no function M." .. name .. " in the source")
	local e = assert(src:find("\nend\n", s, true), "no end for M." .. name)
	return src:sub(s, e)
end

local INFORM = slurp("openuf/inform.lua")
local FORGET = strip_comments(body(INFORM, "_forget_controller"))
local MAINLOOP = slurp("openuf/mainloop.lua")

local function modules()
	local out = {}
	local p = assert(io.popen("ls openuf/*.lua"))
	for path in p:lines() do out[#out + 1] = path end
	p:close()
	assert(#out > 20, "openuf/*.lua not found -- run from the project root")
	return out
end

-- What state.reset leaves in a field: nothing a resync could act on.
local function empty_after_reset(field)
	local o = state._state_file
	state._state_file = "/nonexistent/openuf-test-state.json"
	local st = state.load()
	state._state_file = o
	local v = st[field]
	return v == nil or v == false or v == "" or (type(v) == "table" and next(v) == nil)
end

-- pcall'd in _tick before the POST, but plumbing rather than a feature.
local TICK_PLUMBING = {_write_status = true}

-- A fresh inform module; nothing it loads runs a command at load time.
local function fresh_inform()
	OPENUF_TEST_MODE = true
	dofile("openuf/lib/lib.lua")
	return dofile("openuf/inform.lua")
end

-- The feature table (mainloop.lua M._FEATURES / M._FEATURE_ORDER), as loaded.
local FM = fresh_inform()

-- What a Forget runs: its own body plus the source lines of each forget hook
-- (debug.getinfo gives where each one sits in mainloop.lua).
local TEARDOWN = FORGET
do
	local lines = {}
	for l in (MAINLOOP .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = l end
	for _, row in pairs(FM._FEATURES or {}) do
		if row.forget then
			local i = debug.getinfo(row.forget, "S")
			TEARDOWN = TEARDOWN .. "\n" .. strip_comments(
				table.concat(lines, "\n", i.linedefined, i.lastlinedefined))
		end
	end
end

local function quiet(fn)
	local err = io.stderr
	io.stderr = {write = function() end}
	local ok, e = pcall(fn)
	io.stderr = err
	if not ok then error(e, 0) end
end

-- Modules inform.lua loads that can run a command, and are NOT named in
-- _forget_controller: why a Forget may leave them alone.
local FORGET_EXEMPT = {
	state      = "the reset runs before _forget_controller (prev is the state before it)",
	unhandled  = "its only command is a mkdir; the ledger is the device's own record",
	netconfig  = "the management address is kept on purpose (comment above _forget_controller)",
	wlansched  = "the reset empties the down-lists and ucihelper.forget removes the VAPs",
	assoctrack = "its nft table follows the RRM collector (_rrm_tick tears it down)",
	hangwatch  = "watches the daemon's own children; holds no controller setting",
	rrmscan    = "collector for the live VAPs; holds no controller setting",
	roamassist = "works off the live VAPs; holds no controller setting",
	rrbguard   = "repairs hostapd's socket; holds no controller setting",
	-- Not verified on a mesh child (audit 2026-11-10, finding 14).
	backhaul   = "its state fields go with the reset, its openuf_ wifi-ifaces with ucihelper.forget",
}

local tests = {}
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end

test("every st field the code assigns is named in state.lua TYPED", function()
	local missing = {}
	for _, path in ipairs(modules()) do
		local src = strip_comments(slurp(path))
		local function note(k)
			if not state.FIELDS[k] then missing[k] = path end
		end
		for k in src:gmatch("[^%w_%.]st%.([%a_][%w_]*)%s*=[^=]") do note(k) end
		-- `st.a, st.b = x, y`
		for k in src:gmatch("[^%w_%.]st%.([%a_][%w_]*)%s*,%s*st%.") do note(k) end
	end
	local list = {}
	for k, path in pairs(missing) do list[#list + 1] = k .. " (" .. path .. ")" end
	table.sort(list)
	assert(#list == 0, "persisted without a type in state.lua TYPED: " .. table.concat(list, ", "))
end)

test("_tick runs no feature step outside the feature table", function()
	local tick = strip_comments(body(slurp("openuf/mainloop.lua"), "_tick"))
	local cut = assert(tick:find("M.http_post(", 1, true), "_tick no longer POSTs")
	tick = tick:sub(1, cut)
	local problems = {}
	for name in tick:gmatch("pcall%(M%.(_[%w_]+)[,%)]") do
		if not TICK_PLUMBING[name] then
			problems[#problems + 1] = "_tick runs " .. name .. " itself: give it a row in M._FEATURES"
		end
	end
	if tick:find("M._maybe_scan_neighbours", 1, true) then
		problems[#problems + 1] = "_tick runs _maybe_scan_neighbours itself"
	end
	for _, phase in ipairs({"tick", "tick_late"}) do
		if not tick:find('M._run_features("' .. phase .. '"', 1, true) then
			problems[#problems + 1] = "_tick does not run the " .. phase .. " phase"
		end
	end
	table.sort(problems)
	assert(#problems == 0, table.concat(problems, "; "))
end)

test("_forget_controller tears nothing down outside the feature table", function()
	local problems = {}
	if not FORGET:find('M._run_features("forget"', 1, true) then
		problems[#problems + 1] = "_forget_controller does not run the forget phase"
	end
	for _, call in ipairs({"M._meshvlan.reconcile", "M._switchvlan.restore", "M._usteer.set_enabled",
			"M._ucihelper.forget", "M._l2guard.reconcile", "M._guest_enforce", "M._sysconf.apply_cron",
			"M._airtime.set_enabled", "M._led.set_enabled", "M._firewall.reconcile", "M._shaper.sync"}) do
		if FORGET:find(call, 1, true) then
			problems[#problems + 1] = "_forget_controller calls " .. call .. " itself: move it to a forget hook"
		end
	end
	assert(#problems == 0, table.concat(problems, "; "))
end)

test("M.run reapplies nothing outside the feature table", function()
	local run = strip_comments(body(MAINLOOP, "run"))
	local problems = {}
	if not run:find('M._run_features("boot"', 1, true) then
		problems[#problems + 1] = "M.run does not run the boot phase"
	end
	for _, call in ipairs({"M._firewall.reconcile", "M._ucihelper.reapply_runtime_rules",
			"M._led.locate_stop", "M._led.set_enabled", "M._reapply_airtime",
			"M._switchvlan.enable_mib_polling", "M._switchvlan.reconcile_mac_taps",
			"M._l2guard.reconcile", "M._meshvlan_resync", "M._guest_enforce"}) do
		if run:find(call, 1, true) then
			problems[#problems + 1] = "M.run calls " .. call .. " itself: move it to a boot hook"
		end
	end
	-- Phase 1's boot steps stay in M.run, before the identity is read.
	for _, call in ipairs({"pcall(M._ip_rollback_boot, st)", "pcall(M._swvlan_rollback_boot, st)",
			"pcall(M._reapply_static_ip, st, cfg)"}) do
		if not run:find(call, 1, true) then
			problems[#problems + 1] = "M.run lost " .. call
		end
	end
	assert(#problems == 0, table.concat(problems, "; "))
end)

test("every phase list names exactly the rows with that hook", function()
	local F, O = FM._FEATURES, FM._FEATURE_ORDER
	assert(type(F) == "table" and type(O) == "table", "no M._FEATURES / M._FEATURE_ORDER")
	local problems = {}
	for phase, list in pairs(O) do
		local named = {}
		for _, n in ipairs(list) do
			if named[n] then problems[#problems + 1] = phase .. " names " .. n .. " twice" end
			named[n] = true
			if not (F[n] and type(F[n][phase]) == "function") then
				problems[#problems + 1] = phase .. " names " .. n .. ", which has no " .. phase .. " hook"
			end
		end
		for n, row in pairs(F) do
			if row[phase] ~= nil and not named[n] then
				problems[#problems + 1] = n .. " has a " .. phase .. " hook but the " .. phase .. " list skips it"
			end
		end
	end
	for n, row in pairs(F) do
		for k in pairs(row) do
			if k ~= "forget_by" and not O[k] then
				problems[#problems + 1] = n .. " has a " .. k .. " hook but no phase runs " .. k
			end
		end
	end
	table.sort(problems)
	assert(#problems == 0, table.concat(problems, "; "))
end)

test("_run_features calls the phase's hooks in list order with its arguments", function()
	local M = fresh_inform()
	local seen = {}
	local function rec(n) return function(a, b, c) seen[#seen + 1] = n .. ":" .. a .. b .. c end end
	M._FEATURES = {a = {tick = rec("a")}, b = {tick = rec("b"), forget = rec("x")}}
	M._FEATURE_ORDER = {tick = {"b", "a"}, forget = {"b"}}
	M._run_features("tick", 1, 2, 3)
	assert_eq(table.concat(seen, " "), "b:123 a:123", "order and arguments")
end)

test("_run_features lets a hook's error through (it adds no pcall)", function()
	local M = fresh_inform()
	M._FEATURES = {a = {tick = function() error("boom") end}}
	M._FEATURE_ORDER = {tick = {"a"}}
	assert(not pcall(M._run_features, "tick"), "a raising hook was swallowed")
end)

test("the hooks that were unprotected before the table still raise", function()
	local M = fresh_inform()
	local function boom() error("boom") end
	M._maybe_scan_neighbours = boom
	M._firewall = {reconcile = boom}
	M._led = {set_enabled = boom}
	assert(not pcall(M._FEATURES.neighbours.tick, {}, {}, {}), "neighbours tick swallowed an error")
	assert(not pcall(M._FEATURES.block.boot, {blocked_stas = {}}, {}), "block boot swallowed an error")
	assert(not pcall(M._FEATURES.led.boot, {led_enabled = true}, {}), "led boot swallowed an error")
end)

test("_run_features names an unknown phase in its error", function()
	local ok, err = pcall(FM._run_features, "nope")
	assert(not ok and tostring(err):find("nope", 1, true), "unclear error: " .. tostring(err))
end)

-- How a Forget undoes what a tick/tick_late row keeps alive: a forget hook, or
-- forget_by, one of:
--   via    = "<row>"   that row's forget hook undoes it too
--   state  = {fields}  the step works off these state fields, which the
--                      reset before _forget_controller empties
--   vaps   = true      the step reconciles against the live VAPs and the
--                      wireless config, which ucihelper.forget removes
--   none   = "<why>"   nothing of the controller's outlives it
test("each ticking row's Forget story still holds", function()
	local problems = {}
	for name, row in pairs(assert(FM._FEATURES, "no M._FEATURES")) do
		local how = row.forget_by
		if not (row.tick or row.tick_late) or row.forget then
			how = nil
		elseif type(how) ~= "table" then
			problems[#problems + 1] = name .. ": ticks, but has no forget hook and no forget_by"
			how = nil
		end
		if not how then
			-- nothing to check
		elseif how.via then
			local r = FM._FEATURES[how.via]
			if not (r and r.forget) then
				problems[#problems + 1] = name .. ": forget_by.via " .. tostring(how.via) .. " is not a row with a forget hook"
			end
		elseif how.state then
			for _, field in ipairs(how.state) do
				if not state.FIELDS[field] then
					problems[#problems + 1] = name .. ": " .. field .. " is not in state.lua TYPED"
				elseif not empty_after_reset(field) then
					problems[#problems + 1] = name .. ": " .. field .. " is not empty after a reset"
				end
			end
		elseif how.vaps then
			if not (FM._FEATURES.ucihelper and FM._FEATURES.ucihelper.forget) then
				problems[#problems + 1] = name .. ": no ucihelper row with a forget hook"
			end
		elseif type(how.none) ~= "string" then
			problems[#problems + 1] = name .. ": row says nothing"
		end
	end
	table.sort(problems)
	assert(#problems == 0, table.concat(problems, "; "))
end)

test("a module that runs commands is torn down by Forget or says why not", function()
	local problems = {}
	for name in INFORM:gmatch('_require_sibling%("([%w_]+)"%)') do
		local f = io.open("openuf/" .. name .. ".lua", "r")
		if f then
			local src = strip_comments(f:read("*a"))
			f:close()
			local runs = src:find("os%.execute") ~= nil
			local named = TEARDOWN:find("M%._" .. name .. "[^%w_]") ~= nil
			if runs and not named and not FORGET_EXEMPT[name] then
				problems[#problems + 1] = name .. ".lua runs commands, _forget_controller never names M._"
					.. name .. ", and FORGET_EXEMPT gives no reason"
			elseif FORGET_EXEMPT[name] and named then
				problems[#problems + 1] = name .. " is in FORGET_EXEMPT but _forget_controller handles it now"
			end
		end
	end
	table.sort(problems)
	assert(#problems == 0, table.concat(problems, "; "))
end)

-- ─── Behaviour pins: each caller runs its steps in today's order ───────────
-- These drive the real code with every step stubbed after load (the way the
-- other suites stub), so a refactor that reorders, drops or doubles a step
-- fails here.

test("_tick runs its steps in today's order", function()
	local M = fresh_inform()
	local seen = {}
	local function rec(name) return function() seen[#seen + 1] = name end end
	local STEPS = {"_stun_tick", "_maybe_scan_neighbours", "_scan_job_tick", "_rrm_tick",
		"_maybe_service_dfs_reset", "_vap_watch", "_l2guard_resync", "_bcfilt_resync",
		"_backhaul_tick", "_uplinkmon_resync", "_meshvlan_resync", "_guest_resync",
		"_guest_wg_resync", "_hairpin_resync", "_usteer_filter_resync", "_block_resync",
		"_sched_resync", "_rrbguard_tick", "_acsguard_resync", "_refresh_net_info", "build_json", "_shaper_resync"}
	for _, n in ipairs(STEPS) do M[n] = rec(n) end
	M._ucihelper, M._sysinfo = {}, {}
	M._reload_if_changed = function() return nil end
	M._write_status = function() end
	M.build_json = function() seen[#seen + 1] = "build_json"; return "{}" end
	M.build_packet = function() error("stop here") end
	quiet(function() M._tick({}, {}, nil, {}) end)
	assert_eq(table.concat(seen, " "), table.concat(STEPS, " "), "tick order")
end)

test("_forget_controller tears down in today's order", function()
	local M = fresh_inform()
	local seen = {}
	local function rec(name) return function() seen[#seen + 1] = name end end
	M._push_replay_arm = rec("replay_arm")
	M._meshvlan = {reconcile = rec("meshvlan")}
	M._switchvlan = {restore = rec("switchvlan")}
	M._usteer = {set_enabled = rec("usteer")}
	M._ucihelper = {forget = rec("ucihelper")}
	M._deny_reloaded = rec("deny_reloaded")
	M._l2guard = {reconcile = rec("l2guard")}
	M._guestportal = {}
	M._guest_enforce = rec("guest")
	M._sysconf = {apply_cron = rec("cron")}
	M._snmp = {restore_if_owned = rec("snmp")}
	M._airtime = {set_enabled = rec("airtime")}
	M._led = {set_enabled = rec("led")}
	M._firewall = {reconcile = rec("firewall")}
	M._shaper = {sync = rec("shaper")}
	M._uplinkmon = {}
	quiet(function()
		M._forget_controller({meshvlan = {bridge = "br-lan", vids = {20}}, led_enabled = false}, {})
	end)
	assert_eq(table.concat(seen, " "), "replay_arm meshvlan switchvlan usteer ucihelper deny_reloaded"
		.. " l2guard guest cron snmp airtime led firewall shaper", "forget order")
end)

return tests
