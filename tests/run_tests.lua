-- Pure Lua 5.1 test runner. Run from project root: lua tests/run_tests.lua
-- The runner itself has no external deps, but most test files require cjson --
-- see the preflight below. Exit code 0 = all pass, 1 = any failure.
-- Each test file must return a list of {name=..., fn=...} tables.

-- Dependency preflight. Most test files require("cjson") at LOAD time; when it
-- is unresolvable each such file dies with a single "ERROR running <file>"
-- line and ALL of its tests silently never run -- a past incident made "182
-- passed, 7 failed" look plausible while ~200 tests in 5 files had not
-- executed at all. Fail fast and loudly instead.
do
	local ok = pcall(require, "cjson")
	if not ok then
		print("FATAL: lua-cjson is not resolvable from this interpreter.")
		print("       Without it most test files would silently not run at all.")
		print("       Run the suite as:")
		print("           eval $(luarocks path --local) && lua tests/run_tests.lua")
		os.exit(1)
	end
end

local passed = 0
local failed = 0
local skipped = 0

-- A test that cannot run here (a missing optional backend, say) calls
-- skip(reason). It is counted as SKIP, never as PASS: a test that returned
-- early without asserting used to read exactly like one that passed.
local SKIP = {}
function skip(reason)
	error({[SKIP] = tostring(reason or "skipped")}, 0)
end

-- Global assert helpers available to all test files

function assert_eq(got, expected, label)
	if got ~= expected then
		error(string.format("%s\n  expected: %s\n  got:      %s",
			label or "(no label)", tostring(expected), tostring(got)), 2)
	end
end

function assert_neq(got, notexpected, label)
	if got == notexpected then
		error(string.format("%s: expected a different value, both are %s",
			label or "(no label)", tostring(got)), 2)
	end
end

function assert_true(val, label)
	if not val then
		error(string.format("%s: expected true, got %s",
			label or "(no label)", tostring(val)), 2)
	end
end

function assert_false(val, label)
	if val then
		error(string.format("%s: expected false, got %s",
			label or "(no label)", tostring(val)), 2)
	end
end

function assert_nil(val, label)
	if val ~= nil then
		error(string.format("%s: expected nil, got %s",
			label or "(no label)", tostring(val)), 2)
	end
end

function assert_not_nil(val, label)
	if val == nil then
		error(string.format("%s: expected non-nil", label or "(no label)"), 2)
	end
end

function assert_error(fn, label)
	local ok = pcall(fn)
	if ok then
		error(string.format("%s: expected an error but none was raised",
			label or "(no label)"), 2)
	end
end

function assert_contains(str, sub, label)
	if type(str) ~= "string" or not str:find(sub, 1, true) then
		error(string.format("%s: expected %q to contain %q",
			label or "(no label)", tostring(str), tostring(sub)), 2)
	end
end

function assert_bytes_eq(got, expected, label)
	-- Compare two binary strings; show hex diff on failure
	if got ~= expected then
		local function to_hex(s)
			return s:gsub(".", function(c)
				return string.format("%02x ", string.byte(c))
			end)
		end
		error(string.format("%s\n  expected (%d bytes): %s\n  got      (%d bytes): %s",
			label or "(no label)", #expected, to_hex(expected), #got, to_hex(got)), 2)
	end
end

-- A stand-in nft for a module's os.execute seam (util.nft_run writes a script
-- and runs `nft -f <file>`). Returns exec and r: r.cmds lists every statement
-- nft accepted as "nft <statement>" (a rejected script, being one
-- transaction, adds none of its statements), r.runs counts nft invocations,
-- r.other lists every command that was not an nft script. fail(stmt) -> true
-- makes nft reject a script holding that statement.
function fake_nft(fail)
	local r = {cmds = {}, runs = 0, other = {}}
	local function exec(cmd)
		local path = cmd:match("^nft %-f (%S+)")
		if not path then
			r.other[#r.other + 1] = cmd
			return 0
		end
		r.runs = r.runs + 1
		local lines = {}
		for line in io.lines(path) do
			if fail and fail(line) then return 1 end
			lines[#lines + 1] = "nft " .. line
		end
		for _, l in ipairs(lines) do r.cmds[#r.cmds + 1] = l end
		return 0
	end
	return exec, r
end

-- Run a list of {name, fn} test entries. Returns the file's own
-- pass/fail/skip counts so the per-file summary can make a silently-vanished
-- file visible. seen holds the names run so far; emit prints a line (the
-- self-test below captures it instead).
local function run_suite(tests, seen, emit)
	local p, f, s = 0, 0, 0
	for _, t in ipairs(tests) do
		local ok, err = pcall(t.fn)
		if seen[t.name] then
			-- A copy-pasted duplicate name makes two results indistinguishable
			-- in the output (and hides one of them from anyone grepping a name).
			ok, err = false, "duplicate test name"
		end
		seen[t.name] = true
		if ok then
			p = p + 1
			emit("PASS  " .. tostring(t.name))
		elseif type(err) == "table" and err[SKIP] then
			s = s + 1
			emit("SKIP  " .. tostring(t.name) .. " (" .. err[SKIP] .. ")")
		else
			f = f + 1
			emit("FAIL  " .. tostring(t.name))
			emit("      " .. tostring(err):gsub("\n", "\n      "))
		end
	end
	return p, f, s
end

-- Load and run one test file. loader is loadfile (the self-test passes a
-- fake). Every way a file can fail to run counts as a failure: missing,
-- unloadable, erroring at load, not returning a table, or holding no tests.
local function run_file(filepath, loader, seen, emit)
	local fn, err = loader(filepath)
	if not fn then
		emit("ERROR loading " .. filepath .. ": " .. tostring(err))
		return 0, 1, 0
	end
	local ok, result = pcall(fn)
	if not ok then
		-- Loud on purpose: one counted failure, but the real damage is
		-- every test in the file silently not running.
		emit("ERROR running " .. filepath .. ": " .. tostring(result))
		emit("      ALL of this file's tests were SKIPPED and did not run")
		return 0, 1, 0
	elseif type(result) ~= "table" then
		-- A file that forgets `return {...}` (or returns a function) used
		-- to vanish with ZERO failures recorded.
		emit("ERROR " .. filepath .. " returned " .. type(result)
			.. " instead of a test table -- its tests did not run")
		return 0, 1, 0
	elseif #result == 0 then
		emit("ERROR " .. filepath .. " returned no tests")
		return 0, 1, 0
	end
	local p, f, s = run_suite(result, seen, emit)
	emit(("      %s: %d passed, %d failed, %d skipped"):format(filepath, p, f, s))
	return p, f, s
end

-- Every tests/test_*.lua on disk has to be registered: a file that is not
-- never runs. names iterates the directory listing (nil when it could not be
-- read). Returns the number of problems found.
local function check_registered(names, registered, emit)
	if not names then
		emit("ERROR cannot list tests/ -- the unregistered-file check did not run")
		return 1
	end
	local bad, listed = 0, {}
	for name in names do
		listed["tests/" .. name] = true
		if name:match("^test_.*%.lua$") and not registered["tests/" .. name] then
			emit("ERROR tests/" .. name .. " exists but is not registered in "
				.. "tests/run_tests.lua -- its tests did not run")
			bad = bad + 1
		end
	end
	-- An empty or failed `ls` (its exit status is lost under Lua 5.1) would
	-- otherwise pass the check vacuously.
	for f in pairs(registered) do
		if not listed[f] then
			emit("ERROR " .. f .. " is registered but `ls tests` did not list it")
			bad = bad + 1
		end
	end
	return bad
end

-- The runner checks itself first, on synthetic files: these are the rules
-- the gate's Results: line depends on.
local function self_test()
	local out = {}
	local function emit(l) out[#out + 1] = l end
	local function iter(t) local i = 0 return function() i = i + 1 return t[i] end end
	local seen = {}
	local p, f, s = run_suite({
		{name = "a", fn = function() end},
		{name = "b", fn = function() skip("no backend") end},
		{name = "c", fn = function() error("boom") end},
		{name = "a", fn = function() end},
	}, seen, emit)
	assert_eq(p, 1, "one pass"); assert_eq(s, 1, "skip is not a pass")
	assert_eq(f, 2, "an error and a duplicate name both fail")
	assert_contains(table.concat(out, "\n"), "SKIP  b (no backend)", "SKIP line")
	local function loader(t) return function(path) return t[path] end end
	local files = {
		["empty"] = function() return {} end,
		["str"] = function() return "x" end,
		["dies"] = function() error("load") end,
		["ok"] = function() return {{name = "ok1", fn = function() end}} end,
	}
	local l = loader(files)
	assert_eq(select(2, run_file("missing", l, {}, emit)), 1, "missing file fails")
	assert_eq(select(2, run_file("empty", l, {}, emit)), 1, "zero tests fails")
	assert_eq(select(2, run_file("str", l, {}, emit)), 1, "non-table fails")
	assert_eq(select(2, run_file("dies", l, {}, emit)), 1, "load error fails")
	local op, of = run_file("ok", l, {}, emit)
	assert_eq(op, 1, "a good file passes"); assert_eq(of, 0, "a good file has no failure")
	local reg = {["tests/test_a.lua"] = true}
	assert_eq(check_registered(nil, reg, emit), 1, "unlistable dir fails")
	assert_eq(check_registered(iter({}), reg, emit), 1, "empty listing fails")
	assert_eq(check_registered(iter({"test_a.lua", "test_b.lua"}), reg, emit), 1,
		"unregistered file fails")
	assert_eq(check_registered(iter({"test_a.lua", "x.txt"}), reg, emit), 0, "clean dir")
end

-- Test files to run in order. A listed file that is missing is a failure.
local test_files = {
	"tests/test_lib.lua",
	"tests/test_util.lua",
	"tests/test_announce.lua",
	"tests/test_state.lua",
	"tests/test_crypto.lua",
	"tests/test_inform_packet.lua",
	"tests/test_sysinfo.lua",
	"tests/test_lldp.lua",
	"tests/test_syswrapper.lua",
	"tests/test_guestportal.lua",
	"tests/test_inform_json.lua",
	"tests/test_led.lua",
	"tests/test_ucihelper.lua",
	"tests/test_usteer.lua",
	"tests/test_netconfig.lua",
	"tests/test_firewall.lua",
	"tests/test_bcfilter.lua",
	"tests/test_rrmscan.lua",
	"tests/test_assoctrack.lua",
	"tests/test_satisfaction.lua",
	"tests/test_minrssi.lua",
	"tests/test_stun.lua",
	"tests/test_loadbalance.lua",
	"tests/test_wlansched.lua",
	"tests/test_uplinkmon.lua",
	"tests/test_rrbguard.lua",
	"tests/test_shaper.lua",
	"tests/test_switchvlan.lua",
	"tests/test_modelmap.lua",
	"tests/test_ufmodel.lua",
	"tests/test_inflate.lua",
	"tests/test_unhandled.lua",
	"tests/test_sysconf.lua",
	"tests/test_l2guard.lua",
	"tests/test_roamassist.lua",
	"tests/test_airtime.lua",
	"tests/test_backhaul.lua",
	"tests/test_meshvlan.lua",
	"tests/test_uciconf.lua",
	"tests/test_probe.lua",
	"tests/test_ftinterop.lua",
	"tests/test_plugins.lua",
}

do
	local ok, err = pcall(self_test)
	if ok then
		passed = passed + 1
		print("PASS  runner: self-test (skip, duplicate, missing/empty file, ls checks)")
	else
		failed = failed + 1
		print("FAIL  runner: self-test\n      " .. tostring(err))
	end
end

local seen_names = {}
for _, filepath in ipairs(test_files) do
	local p, f, s = run_file(filepath, loadfile, seen_names, print)
	passed, failed, skipped = passed + p, failed + f, skipped + s
end

-- `ls` rather than a filesystem library -- the runner has no external
-- dependencies, and io.popen is standard Lua.
do
	local registered = {}
	for _, f in ipairs(test_files) do registered[f] = true end
	local h = io.popen("ls tests 2>/dev/null")
	failed = failed + check_registered(h and h:lines(), registered, print)
	if h then h:close() end
end

-- The first two fields keep their old shape: tools read "N passed, M failed".
-- A skip never fails the run.
print(string.format("\nResults: %d passed, %d failed, %d skipped", passed, failed, skipped))
os.exit(failed == 0 and 0 or 1)
