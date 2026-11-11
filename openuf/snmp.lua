--[[
	The controller's SNMP Monitoring setting (Settings -> System -> SNMP) on
	OpenWrt's net-snmp agent.

	Ported from fonix232/openUF (openuf/src/unifi/snmp.lua and
	openuf/src/openwrt/snmp.lua, MIT; the notice is in NOTICE), merged into
	one module. Its SHA-256 of the applied settings is left out: the wanted
	config is compared with the live /etc/config/snmpd instead.

	Decompiled from 10.6.106, not yet seen on the wire. system_cfg, sent only
	while SNMP is on:

	  snmp.status=enabled
	  snmp.version=1_2c | 3 | all        (v1/v2c, v3, both)
	  snmp.location=<text>, snmp.contact=<text>   (when set)
	  snmp.community=<string>            v1/v2c only, default "public"
	  snmp.user.1.name / .password       v3 only

	v3 goes only to a device claiming fw_caps 0x4000 (supportsSNMPv3), which
	inform claims when M.v3_capable(): the ssl build, the only one with AES
	privacy. There is no snmp.status=disabled: off is the block missing from
	a FULL system_cfg (one carrying ebtables.status); a partial push decides
	nothing.

	While SNMP is on, openUF owns /etc/config/snmpd: the device's file is
	kept once in /etc/openuf/snmpd.orig (0600: it may hold a community;
	written only when no copy exists, so openUF's own config can never become
	the "original"), with whether snmpd was enabled (st.snmp_was_enabled),
	and the config is rewritten from the push -- one read-only community, one
	v3 user, sysLocation/sysContact -- so no community the controller does
	not know about is left answering. Off (or a Forget) puts the kept file
	back and restarts snmpd on it, or stops and disables it if it was off.
	SNMP on with nothing usable stops and disables snmpd rather than leave
	the stock config, which answers `public`.
]]--

local M = {}
local util = package.loaded["openuf.util"]
	or assert(loadfile("util.lua") or loadfile("openuf/util.lua"))()

M.CONFIG    = "/etc/config/snmpd"
M.BACKUP    = "/etc/openuf/snmpd.orig"
M.INIT      = "/etc/init.d/snmpd"
M.APK_DB    = "/lib/apk/db/installed"
-- v3_capable is asked on every inform (fw_caps); kept this long rather than
-- reading the whole apk database each time.
M.CACHE_TTL = 600

M._exec = os.execute
M._time = os.time
M._read_file = util.read_file
M._remove = os.remove
-- private: readable by root only (chmod 600 before the data goes in).
M._write_file = function(path, data, private)
	local tmp = path .. ".tmp"
	os.remove(tmp)
	local f = io.open(tmp, "w")
	if not f then return false end
	if private then
		f:close()
		if not util.exec_ok(os.execute("chmod 600 '" .. tmp .. "'")) then
			os.remove(tmp)
			return false
		end
		f = io.open(tmp, "w")
		if not f then os.remove(tmp); return false end
	end
	local ok = f:write(data)
	local closed = f:close()
	if not (ok and closed and os.rename(tmp, path)) then
		os.remove(tmp)
		return false
	end
	return true
end
M._uci = nil   -- nil = require("uci") on first use
M._warned = false
M._cache = {}

local function get_uci()
	if not M._uci then M._uci = require("uci") end
	return M._uci
end

-- ─── Parsing ─────────────────────────────────────────────────────────────────

-- Values reach snmpd.conf through OpenWrt's init script, which writes some of
-- them inside double quotes: printable, no quote, backslash or whitespace.
local function token(s, max)
	return type(s) == "string" and #s >= 1 and #s <= (max or 64)
		and s:match("^[%w%p]+$") ~= nil and not s:find('["\\]')
end

-- Free text (location/contact): printable ASCII, no quote or backslash.
local function text(s)
	return type(s) == "string" and #s >= 1 and #s <= 255
		and s:match("^[%w%p ]+$") ~= nil and not s:find('["\\]')
end

-- nil when sys_raw is not a string; {enabled = false} without the block;
-- else {enabled = true, v1v2c, v3, community, location, contact, user,
-- password}, with neither version on when nothing in it is usable.
function M.parse(sys_raw)
	if type(sys_raw) ~= "string" then return nil end
	local kv = {}
	for line in (sys_raw .. "\n"):gmatch("([^\n]*)\n") do
		local k, v = line:match("^snmp%.([%w%._]+)=(.*)$")
		if k then kv[k] = v end
	end
	if kv.status ~= "enabled" then return {enabled = false} end
	local ver = kv.version
	local out = {
		enabled  = true,
		v1v2c    = (ver == "1_2c" or ver == "all"),
		v3       = (ver == "3" or ver == "all"),
		location = text(kv.location) and kv.location or nil,
		contact  = text(kv.contact) and kv.contact or nil,
	}
	if out.v1v2c then
		if token(kv.community) then
			out.community = kv.community
		else
			io.stderr:write("snmp: unusable community string, v1/v2c not enabled\n")
			out.v1v2c = false
		end
	end
	if out.v3 then
		-- net-snmp's createUser needs a passphrase of 8 characters or more.
		if token(kv["user.1.name"], 32) and token(kv["user.1.password"], 64)
				and #kv["user.1.password"] >= 8 then
			out.user, out.password = kv["user.1.name"], kv["user.1.password"]
		else
			io.stderr:write("snmp: unusable v3 user or password (8+ printable characters, "
				.. "no quotes or spaces), v3 not enabled\n")
			out.v3 = false
		end
	end
	return out
end

-- ─── Probes ──────────────────────────────────────────────────────────────────

local function cached(name, fn)
	local c, now = M._cache[name], M._time()
	if c and now - c.at < M.CACHE_TTL and now >= c.at then return c.v end
	local v = fn()
	M._cache[name] = {v = v, at = now}
	return v
end

function M.installed()
	return cached("installed", function() return M._read_file(M.INIT) ~= nil end)
end

-- The ssl build (libnetsnmp linked with OpenSSL), from apk's database.
function M.v3_capable()
	if not M.installed() then return false end
	return cached("v3", function()
		local db = "\n" .. (M._read_file(M.APK_DB) or "")
		return db:find("\nP:snmpd%-ssl\n") ~= nil or db:find("\nP:libnetsnmp%-ssl\n") ~= nil
	end)
end

-- ─── Apply ───────────────────────────────────────────────────────────────────

-- The whole /etc/config/snmpd for an intent: {name = {type, opts}}. nil
-- intent = nothing usable: a config that answers nobody, and says off.
local function wanted(i)
	if not i then return {general = {"snmpd", {enabled = "0"}}} end
	local sys = {}
	if i.location then sys.sysLocation = i.location end
	if i.contact then sys.sysContact = i.contact end
	local w = {
		agent   = {"agent", {agentaddress = "UDP:161,UDP6:161"}},
		general = {"snmpd", {enabled = "1",
			snmp_version = (i.v1v2c and i.v3) and "v1/v2c/v3" or (i.v3 and "v3" or "v1/v2c")}},
		system  = {"system", sys},
		all     = {"view", {viewname = "all", type = "included", oid = ".1"}},
	}
	if i.v1v2c then
		w.public     = {"com2sec", {secname = "ro", source = "default", community = i.community}}
		w.public6    = {"com2sec6", {secname = "ro", source = "default", community = i.community}}
		w.public_v1  = {"group", {group = "public", version = "v1", secname = "ro"}}
		w.public_v2c = {"group", {group = "public", version = "v2c", secname = "ro"}}
		w.public_access = {"access", {group = "public", context = "none", version = "any",
			level = "noauth", prefix = "exact", read = "all", write = "none", notify = "none"}}
	end
	if i.v3 then
		w.openuf_v3 = {"v3", {username = i.user, allow_write = "0",
			auth_type = "SHA", auth_pass = i.password,
			privacy_type = "AES", privacy_pass = i.password, RestrictOID = "no"}}
	end
	return w
end

-- True when the live config is exactly w: same sections, types and options.
local function matches(cursor, w)
	local same, seen = true, 0
	cursor:foreach("snmpd", nil, function(s)
		local want = w[s[".name"]]
		if not want or want[1] ~= s[".type"] then same = false; return end
		seen = seen + 1
		for k, v in pairs(s) do
			if k:sub(1, 1) ~= "." and want[2][k] ~= v then same = false end
		end
		for k, v in pairs(want[2]) do
			if s[k] ~= v then same = false end
		end
	end)
	local n = 0
	for _ in pairs(w) do n = n + 1 end
	return same and seen == n
end

-- Writes w when the live config differs. Returns true when it wrote.
local function write_config(w)
	local cursor = get_uci().cursor()
	if matches(cursor, w) then return false end
	local names = {}
	cursor:foreach("snmpd", nil, function(s) names[#names + 1] = s[".name"] end)
	for _, n in ipairs(names) do cursor:delete("snmpd", n) end
	for name, sec in pairs(w) do
		cursor:set("snmpd", name, sec[1])
		for k, v in pairs(sec[2]) do cursor:set("snmpd", name, k, v) end
	end
	cursor:commit("snmpd")
	return true
end

-- Keep the device's file (once) and whether snmpd was enabled. false when
-- the copy cannot be made -- then nothing is touched.
local function take_over(st)
	if st.snmp_owned then return true end
	if not M._read_file(M.BACKUP) then
		local orig = M._read_file(M.CONFIG)
		if orig and not M._write_file(M.BACKUP, orig, true) then
			io.stderr:write("snmp: cannot keep a copy of " .. M.CONFIG .. " in " .. M.BACKUP
				.. " -- not taking snmpd over\n")
			return false
		end
	end
	st.snmp_was_enabled = util.exec_ok(M._exec(M.INIT .. " enabled >/dev/null 2>&1"))
	st.snmp_owned = true
	return true
end

local function restore(st)
	local orig = M._read_file(M.BACKUP)
	if orig and M._write_file(M.CONFIG, orig) then
		M._remove(M.BACKUP)
	else
		write_config(wanted(nil))
	end
	if M.installed() then
		if st.snmp_was_enabled == false then
			M._exec(M.INIT .. " stop >/dev/null 2>&1")
			M._exec(M.INIT .. " disable >/dev/null 2>&1")
		else
			M._exec(M.INIT .. " restart >/dev/null 2>&1")
		end
	end
	st.snmp_owned, st.snmp_was_enabled = nil, nil
	io.stderr:write("snmp: SNMP off -- the device's snmpd config restored\n")
end

-- Forget: the device's own snmpd back, when openUF took it over.
function M.restore_if_owned(st)
	if type(st) ~= "table" or not st.snmp_owned then return false end
	restore(st)
	return true
end

-- One parsed intent. st carries the ledger (snmp_owned, snmp_was_enabled);
-- full: the push was a full system_cfg, the only kind whose missing block
-- means off. Returns true when snmpd was configured, stopped or restored.
function M.apply(intent, st, full)
	if type(intent) ~= "table" or type(st) ~= "table" then return false end
	if not intent.enabled then
		if not full then return false end
		return M.restore_if_owned(st)
	end
	if not M.installed() then
		if not M._warned then
			M._warned = true
			io.stderr:write("snmp: the controller has SNMP Monitoring on, but snmpd is not "
				.. "installed (apk add snmpd-ssl) -- nothing applied\n")
		end
		return false
	end
	local i = {}
	for k, v in pairs(intent) do i[k] = v end
	if i.v3 and not M.v3_capable() then
		io.stderr:write("snmp: SNMPv3 needs snmpd-ssl (privacy) -- v3 user not configured\n")
		i.v3 = false
	end
	if not i.v1v2c and not i.v3 then
		if st.snmp_owned and matches(get_uci().cursor(), wanted(nil)) then return false end
		if not take_over(st) then return false end
		write_config(wanted(nil))
		M._exec(M.INIT .. " stop >/dev/null 2>&1")
		M._exec(M.INIT .. " disable >/dev/null 2>&1")
		io.stderr:write("snmp: the controller has SNMP Monitoring on, but nothing in it is "
			.. "usable here -- snmpd stopped and disabled rather than left on its stock config\n")
		return true
	end
	local w = wanted(i)
	if st.snmp_owned and matches(get_uci().cursor(), w) then return false end
	if not take_over(st) then return false end
	write_config(w)
	M._exec(M.INIT .. " enable >/dev/null 2>&1")
	M._exec(M.INIT .. " restart >/dev/null 2>&1")
	io.stderr:write("snmp: snmpd configured from the controller (" .. w.general[2].snmp_version .. ")\n")
	return true
end

return M
