-- Tripwires for the hand-kept lists a controller-driven feature has to be in:
-- the per-tick resyncs in inform._tick, the teardown in
-- inform._forget_controller and state.lua's TYPED table. Nothing ties them
-- together in the code, so a feature added to one and not the others is a
-- reboot bug or survives a Forget (audit 2026-11-10, finding 14).
--
-- These read the SOURCE. A failure here does not say the code is wrong: it
-- says a list changed and the others need a look. Then update the table below
-- with how a Forget undoes the new thing.
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

-- Every pcall'd step of _tick before the POST, and how a Forget undoes what
-- it keeps alive. One of:
--   forget = "<text>"  that text is in _forget_controller (explicit teardown)
--   state  = {fields}  the step works off these state fields, which the
--                      reset before _forget_controller empties
--   vaps   = true      the step reconciles against the live VAPs and the
--                      wireless config, which ucihelper.forget removes
--   none   = "<why>"   nothing of the controller's outlives it
local TICK = {
	_stun_tick               = {state = {"stun_url"}},
	_scan_job_tick           = {none = "runs one chunk of a queued sweep; keeps nothing"},
	_rrm_tick                = {none = "collector follows the live VAPs and tears its own nft table down"},
	_maybe_service_dfs_reset = {none = "one-shot request file from syswrapper"},
	_vap_watch               = {none = "only opens the resync gates"},
	_l2guard_resync          = {forget = "M._l2guard.reconcile"},
	_bcfilt_resync           = {vaps = true},
	-- Not verified on a mesh child: what a Forget does to its own uplink.
	_backhaul_tick           = {state = {"backhaul_ul", "backhaul_parent"}},
	_uplinkmon_resync        = {state = {"uplinkmon_enabled", "uplinkmon_host", "uplinkmon_down"}},
	_meshvlan_resync         = {forget = "M._meshvlan.reconcile"},
	_guest_resync            = {forget = "M._guest_enforce"},
	_guest_wg_resync         = {forget = "M._guest_enforce"},
	_hairpin_resync          = {vaps = true},
	_usteer_filter_resync    = {forget = "M._usteer.set_enabled"},
	_block_resync            = {forget = "M._firewall.reconcile"},
	_sched_resync            = {state = {"sched_vaps_down"}},
	_rrbguard_tick           = {none = "watches hostapd's own socket; no controller setting"},
	_refresh_net_info        = {none = "reads the address; changes nothing"},
	_shaper_resync           = {forget = "M._shaper.sync"},
}
-- pcall'd in _tick, but plumbing rather than a feature.
local TICK_PLUMBING = {_write_status = true}

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

test("_tick's resyncs and the TICK table name the same steps", function()
	local tick = strip_comments(body(slurp("openuf/mainloop.lua"), "_tick"))
	local cut = assert(tick:find("M.http_post(", 1, true), "_tick no longer POSTs")
	tick = tick:sub(1, cut)
	local seen, problems = {}, {}
	for name in tick:gmatch("pcall%(M%.(_[%w_]+)[,%)]") do
		seen[name] = true
		if not TICK[name] and not TICK_PLUMBING[name] then
			problems[#problems + 1] = "_tick runs " .. name .. " but TICK has no row: say how a Forget undoes it"
		end
	end
	for name in pairs(TICK) do
		if not seen[name] then
			problems[#problems + 1] = "TICK names " .. name .. " but _tick no longer runs it"
		end
	end
	table.sort(problems)
	assert(#problems == 0, table.concat(problems, "; "))
end)

test("each TICK row's Forget story still holds in the source", function()
	local problems = {}
	for name, how in pairs(TICK) do
		if how.forget then
			if not FORGET:find(how.forget, 1, true) then
				problems[#problems + 1] = name .. ": " .. how.forget .. " is gone from _forget_controller"
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
			if not FORGET:find("M._ucihelper.forget", 1, true) then
				problems[#problems + 1] = name .. ": _forget_controller no longer calls ucihelper.forget"
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
			local named = FORGET:find("M%._" .. name .. "[^%w_]") ~= nil
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

return tests
