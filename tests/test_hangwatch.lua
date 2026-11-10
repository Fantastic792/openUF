-- Tests for openuf/hangwatch.lua (the daemon's hang watchdog) and the way
-- inform.lua starts it.
-- Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true
if not ufpkt then dofile("openuf/lib/lib.lua") end
local hw = dofile("openuf/hangwatch.lua")
local inform = dofile("openuf/inform.lua")

-- Runs fn with the seams replaced, restores them whatever happens.
local function with_seams(seams, fn)
	local orig = {}
	for k, v in pairs(seams) do orig[k] = hw[k]; hw[k] = v end
	local ok, err = pcall(fn)
	for k in pairs(seams) do hw[k] = orig[k] end
	if not ok then error(err, 0) end
end

local function stat_reader(text)
	return function(path)
		if path == "/proc/self/stat" then return text end
		return nil
	end
end

local function readable(path)
	local f = io.open(path, "r")
	if not f then return false end
	local s = f:read("*a")
	f:close()
	return s ~= nil and s ~= ""
end

return {
	{
		name = "hangwatch: SCRIPT has no single quote (it is spliced into sh -c '...')",
		fn = function()
			assert(not hw.SCRIPT:find("'", 1, true), "single quote in SCRIPT")
		end
	},
	{
		name = "hangwatch: self_pid reads the first field of /proc/self/stat",
		fn = function()
			with_seams({_read_file = stat_reader("1234 (lua) S 1 1234 1234 0 -1 4194560")}, function()
				assert_eq(hw.self_pid(), 1234, "pid")
			end)
			for _, bad in ipairs({"", "garbage", "0 (x) S 1", "-5 (x) S"}) do
				with_seams({_read_file = stat_reader(bad)}, function()
					assert_eq(hw.self_pid(), nil, "bad: " .. bad)
				end)
			end
			with_seams({_read_file = function() return nil end}, function()
				assert_eq(hw.self_pid(), nil, "unreadable")
			end)
		end
	},
	{
		name = "hangwatch: command is the exact sh line, digits only",
		fn = function()
			local c = hw.command(1234, 5, 12)
			assert(c, "command built")
			assert(c:sub(1, 7) == "sh -c '", "starts with sh -c")
			assert(c:sub(-1) == "&", "ends with &")
			assert(c:find("</dev/null >/dev/null 2>&1", 1, true), "redirects")
			assert(c:find("openuf-hangwatch 1234 5 12 ", 1, true), "arguments")
		end
	},
	{
		name = "hangwatch: command refuses anything but positive integers",
		fn = function()
			local bad = {1.5, 0, -1, "12", "1; reboot", false, true, 0 / 0}
			for pos = 1, 3 do
				for i = 1, #bad do
					local a = {1234, 5, 12}
					a[pos] = bad[i]
					assert_eq(hw.command(a[1], a[2], a[3]), nil, "pos " .. pos .. " bad " .. i)
				end
				local a = {1234, 5, 12}
				a[pos] = nil
				assert_eq(hw.command(a[1], a[2], a[3]), nil, "pos " .. pos .. " nil")
			end
			assert_eq(hw.command(), nil, "no args")
		end
	},
	{
		name = "hangwatch: start runs one command with the own pid and ceil(60/5) polls",
		fn = function()
			local ran = {}
			with_seams({
				_exists = function() return false end,
				_read_file = stat_reader("777 (lua) S 1 "),
				_exec = function(c) ran[#ran + 1] = c; return 0 end,
			}, function()
				assert_eq(hw.start(), true, "started")
			end)
			assert_eq(#ran, 1, "one command")
			assert(ran[1]:find("openuf-hangwatch 777 5 12 ", 1, true), "pid and polls: " .. ran[1])
		end
	},
	{
		name = "hangwatch: start honours opts and never goes below two polls",
		fn = function()
			local ran = {}
			with_seams({
				_exists = function() return false end,
				_exec = function(c) ran[#ran + 1] = c end,
			}, function()
				assert_eq(hw.start({limit = 3, poll = 5, pid = 42}), true, "started")
			end)
			assert(ran[1]:find("openuf-hangwatch 42 5 2 ", 1, true), "two polls: " .. ran[1])
		end
	},
	{
		name = "hangwatch: start runs nothing when off, pid-less or limit 0",
		fn = function()
			local ran = 0
			local function try(seams, opts)
				seams._exec = function() ran = ran + 1 end
				local ok, why
				with_seams(seams, function() ok, why = hw.start(opts) end)
				assert_eq(ok, false, "refused")
				assert(type(why) == "string" and why ~= "", "reason")
			end
			local nofile = function() return false end
			try({_exists = function(p) return p == hw.OFF_FILE end,
				_read_file = stat_reader("777 (lua) S 1 ")})
			try({_exists = nofile, _read_file = stat_reader("")})
			try({_exists = nofile, _read_file = stat_reader("777 (lua) S 1 ")}, {limit = 0})
			try({_exists = nofile, _read_file = stat_reader("777 (lua) S 1 ")}, {poll = 0})
			assert_eq(ran, 0, "nothing run")
		end
	},
	{
		name = "inform._start_hangwatch: calls start once and never raises",
		fn = function()
			local orig, o_err = inform._hangwatch, io.stderr
			local lines = {}
			io.stderr = {write = function(_, s) lines[#lines + 1] = s end}
			local calls = 0
			local function run_with(stub)
				calls = 0
				inform._hangwatch = stub
				local ok, err = pcall(inform._start_hangwatch)
				assert(ok, "raised: " .. tostring(err))
			end
			local ok, err = pcall(function()
				run_with({LIMIT_S = 60, start = function() calls = calls + 1; return true end})
				assert_eq(calls, 1, "once")
				assert_eq(lines[#lines], "inform: hang watchdog started (limit 60 s)\n", "started line")
				run_with({LIMIT_S = 60, start = function() calls = calls + 1; return false, "off" end})
				assert_eq(calls, 1, "once (refused)")
				assert_eq(lines[#lines], "inform: hang watchdog not started: off\n", "refused line")
				run_with({LIMIT_S = 60, start = function() calls = calls + 1; error("boom") end})
				assert_eq(calls, 1, "once (raised)")
				assert(lines[#lines]:find("not started: .*boom"), "error line: " .. lines[#lines])
				run_with(nil)
				assert(lines[#lines]:find("not started"), "missing module line")
				assert_eq(#lines, 4, "one line per call")
			end)
			inform._hangwatch, io.stderr = orig, o_err
			if not ok then error(err, 0) end
		end
	},
	{
		name = "hangwatch: a real watchdog unblocks a daemon stuck on a hung child, leaving nothing behind",
		fn = function()
			if not readable("/proc/self/stat") then skip("no /proc") end
			local pidf, outf = os.tmpname(), os.tmpname()
			os.remove(outf)
			-- The pipeline's own sh has "sleep 29'[7]" in its text, which the
			-- pattern does not match, so only the real sleep is found.
			local scan = "for f in /proc/[0-9]*/cmdline; do p=${f#/proc/}; p=${p%%/cmdline}; "
				.. "case $(tr '\\000' ' ' < $f 2>/dev/null) in *'sleep 29'[7]*) %s;; esac; done"
			local function cleanup(pid)
				os.execute(scan:format("kill -9 $p 2>/dev/null") .. " >/dev/null 2>&1")
				if pid then os.execute("kill -9 " .. pid .. " >/dev/null 2>&1") end
				os.remove(pidf); os.remove(outf)
			end
			local function wait_for(fn, secs)
				for _ = 1, secs * 10 do
					if fn() then return true end
					os.execute("sleep 0.1")
				end
				return false
			end
			-- The fake daemon: blocked on a pipeline whose sleep never ends.
			os.execute("sh -c 'echo $$ > " .. pidf .. "; x=$(sleep 297 | cat); echo done > "
				.. outf .. "' </dev/null >/dev/null 2>&1 &")
			local pid
			wait_for(function()
				local f = io.open(pidf, "r")
				if not f then return false end
				pid = tonumber(f:read("*l"))
				f:close()
				return pid ~= nil
			end, 5)
			if not pid then cleanup(nil); error("fake daemon did not start") end
			os.execute(hw.command(pid, 1, 2))
			local done = wait_for(function() return readable(outf) end, 10)
			local left = io.popen(scan:format("echo $p") .. " 2>/dev/null")
			local out = left:read("*a")
			left:close()
			cleanup(pid)
			assert(done, "the fake daemon was never unblocked")
			assert_eq(out, "", "processes still running the hung sleep")
		end
	},
}
