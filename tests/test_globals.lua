-- No stray globals in openuf/. A typo'd local, or a `local` declared after
-- the function that uses it, compiles fine and fails only when that line
-- runs; luac's listing shows it as a GETGLOBAL or SETGLOBAL. Idea from
-- fonix232/openUF's CI (COMPLETION-PLAN D3).

-- Lua 5.1's own names, the bit libraries some boards load, and openUF's
-- deliberate globals: the test-mode switches, the `config`/`dev` pair
-- conf.lua and the board maps fill in, and lib.lua's packet helper.
local ALLOWED = {}
for name in ([[_G _VERSION arg assert collectgarbage coroutine debug dofile error
	getfenv getmetatable io ipairs load loadfile loadstring math module next os
	package pairs pcall print rawequal rawget rawset require select setfenv
	setmetatable string table tonumber tostring type unpack xpcall bit bit32
	newproxy gcinfo
	OPENUF_TEST_MODE SYSWRAPPER_TEST_MODE config dev ufpkt]]):gmatch("%S+") do
	ALLOWED[name] = true
end

local function luac()
	for _, c in ipairs({"luac5.1", "luac"}) do
		local h = io.popen("command -v " .. c .. " 2>/dev/null")
		local p = h and h:read("*l")
		if h then h:close() end
		if p and p ~= "" then return p end
	end
	return nil
end

-- The globals `path` reads or writes that are not allowed, sorted.
local function stray(bin, path)
	local h = assert(io.popen(bin .. " -l -p '" .. path .. "' 2>&1"))
	local out = h:read("*a")
	h:close()
	local seen, list = {}, {}
	for name in out:gmatch("[GS]ETGLOBAL[^\n]-; ([%a_][%w_]*)\n") do
		if not ALLOWED[name] and not seen[name] then
			seen[name] = true
			list[#list + 1] = name
		end
	end
	table.sort(list)
	return list, out
end

return {
	{
		name = "globals: no module under openuf/ reads or writes a stray global",
		fn = function()
			local bin = luac()
			if not bin then return skip("no luac5.1/luac on PATH") end
			local h = assert(io.popen("find openuf -name '*.lua' | sort"))
			local files = {}
			for f in h:lines() do files[#files + 1] = f end
			h:close()
			assert_true(#files > 30, "the module tree was found (" .. #files .. " files)")
			local bad = {}
			for _, f in ipairs(files) do
				local list, out = stray(bin, f)
				assert_nil(out:find("^luac"), "luac parsed " .. f .. ": " .. out:sub(1, 120))
				if #list > 0 then bad[#bad + 1] = f .. ": " .. table.concat(list, " ") end
			end
			assert_eq(#bad, 0, "stray globals -- " .. table.concat(bad, "; "))
		end
	},
	{
		name = "globals: the scan catches a typo'd local and a late local",
		fn = function()
			local bin = luac()
			if not bin then return skip("no luac5.1/luac on PATH") end
			local path = os.tmpname()
			local f = assert(io.open(path, "w"))
			f:write("local M = {}\nlocal count = 0\n"
				.. "function M.bump() cuont = count + 1 end\n"
				.. "function M.late() return helper() end\nlocal function helper() return 1 end\n"
				.. "return M\n")
			f:close()
			local list = stray(bin, path)
			os.remove(path)
			assert_eq(table.concat(list, " "), "cuont helper", "both caught, nothing else")
		end
	},
}
