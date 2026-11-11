-- Tests for openuf/snmp.lua (the controller's SNMP Monitoring -> net-snmp).
-- Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true
local snmp = dofile("openuf/snmp.lua")

-- libuci-lua's contract for what the module uses: set(c, s, type) makes a
-- section, set(c, s, o, v) an option; delete(c, s) drops a section;
-- foreach(c, nil, fn) yields every section with .name/.type.
local function mock_uci(db, commits)
	local cursor = {}
	function cursor:get(c, s, o)
		local sec = db[c] and db[c][s]
		if not sec then return nil end
		if o == nil then return sec[".type"] end
		return sec[o]
	end
	function cursor:set(c, s, o, v)
		db[c] = db[c] or {}
		if v == nil then
			db[c][s] = {[".name"] = s, [".type"] = o}
		else
			db[c][s] = db[c][s] or {[".name"] = s, [".type"] = s}
			db[c][s][o] = tostring(v)
		end
		return true
	end
	function cursor:delete(c, s, o)
		if not (db[c] and db[c][s]) then return true end
		if o == nil then db[c][s] = nil else db[c][s][o] = nil end
		return true
	end
	function cursor:commit(c) commits[#commits + 1] = c; return true end
	function cursor:foreach(c, t, fn)
		local names = {}
		for name, sec in pairs(db[c] or {}) do
			if t == nil or sec[".type"] == t then names[#names + 1] = name end
		end
		table.sort(names)
		for _, name in ipairs(names) do fn(db[c][name]) end
	end
	return {cursor = function() return cursor end}
end

local STOCK = "config agent\n\toption agentaddress UDP:161\nconfig com2sec public\n\toption community public\n"
local SSL_DB = "C:x\nP:libnetsnmp-ssl\nV:5.9\n\nP:snmpd-ssl\nV:5.9\n"

-- opts: installed (default true), ssl (default true), enabled (snmpd enabled
-- before; default true), backup_fails.
local function fresh(opts)
	opts = opts or {}
	local db = {snmpd = {
		agent  = {[".name"] = "agent", [".type"] = "agent", agentaddress = "UDP:161"},
		public = {[".name"] = "public", [".type"] = "com2sec", community = "public"},
	}}
	local commits, cmds = {}, {}
	local files = {[snmp.CONFIG] = STOCK}
	if opts.installed ~= false then files[snmp.INIT] = "#!/bin/sh /etc/rc.common\n" end
	if opts.opkg then
		files[snmp.OPKG_INFO .. opts.opkg .. ".control"] = "Package: " .. opts.opkg .. "\n"
	else
		files[snmp.APK_DB] = (opts.ssl == false) and "P:snmpd-nossl\nV:5.9\n" or SSL_DB
	end
	local writes = {}
	snmp._uci = mock_uci(db, commits)
	snmp._cache = {}
	snmp._warned = false
	snmp._time = function() return 1000 end
	snmp._read_file = function(p) return files[p] end
	snmp._write_file = function(p, data, private)
		writes[#writes + 1] = {path = p, private = private}
		if opts.backup_fails and p == snmp.BACKUP then return false end
		files[p] = data
		return true
	end
	snmp._remove = function(p) files[p] = nil end
	snmp._exec = function(cmd)
		cmds[#cmds + 1] = cmd
		if cmd:find(" enabled", 1, true) then return (opts.enabled == false) and 1 or 0 end
		return 0
	end
	return {db = db, commits = commits, cmds = cmds, files = files, writes = writes}
end

local function with_stderr(fn)
	local buf, real = {}, io.stderr
	io.stderr = {write = function(_, ...) for _, s in ipairs({...}) do buf[#buf + 1] = s end end}
	local ok, err = pcall(fn)
	io.stderr = real
	if not ok then error(err, 0) end
	return table.concat(buf)
end

local ALL = table.concat({
	"snmp.status=enabled", "snmp.version=all", "snmp.community=c0mmunity",
	"snmp.location=Rack 2, row B", "snmp.contact=noc@example.com",
	"snmp.user.1.name=monitor", "snmp.user.1.password=s3cretpass",
	"ebtables.status=enabled",
}, "\n") .. "\n"

local function cmd_has(cmds, s)
	for _, c in ipairs(cmds) do if c:find(s, 1, true) then return true end end
	return false
end

return {
	{
		name = "snmp: parse reads each version shape and the off case",
		fn = function()
			local p = snmp.parse(ALL)
			assert_true(p.enabled and p.v1v2c and p.v3, "all = both")
			assert_eq(p.community, "c0mmunity", "community")
			assert_eq(p.location, "Rack 2, row B", "location")
			assert_eq(p.contact, "noc@example.com", "contact")
			assert_eq(p.user, "monitor", "user")
			assert_eq(p.password, "s3cretpass", "password")
			local v3 = snmp.parse("snmp.status=enabled\nsnmp.version=3\nsnmp.user.1.name=monitor\nsnmp.user.1.password=s3cretpass\n")
			assert_true(v3.v3 and not v3.v1v2c, "3 = v3 only")
			local v2 = snmp.parse("snmp.status=enabled\nsnmp.version=1_2c\nsnmp.community=c0mmunity\n")
			assert_true(v2.v1v2c and not v2.v3, "1_2c = v1/v2c only")
			assert_false(snmp.parse("radio.1.channel=6\n").enabled, "no block = off")
			assert_nil(snmp.parse(nil), "not a string")
		end
	},
	{
		name = "snmp: parse drops what snmpd.conf cannot hold, and never logs the secret",
		fn = function()
			local p
			local out = with_stderr(function()
				p = snmp.parse("snmp.status=enabled\nsnmp.version=all\nsnmp.community=bad one\n"
					.. "snmp.user.1.name=monitor\nsnmp.user.1.password=short\n")
			end)
			assert_true(p.enabled, "still on")
			assert_false(p.v1v2c, "spaced community dropped")
			assert_false(p.v3, "7-char password dropped")
			assert_contains(out, "community", "said why")
			assert_false(out:find("bad one", 1, true) ~= nil, "community not logged")
			assert_false(out:find("short", 1, true) ~= nil, "password not logged")
			assert_false(snmp.parse('snmp.status=enabled\nsnmp.version=1_2c\nsnmp.community=a"b\n').v1v2c, "quote")
		end
	},
	{
		name = "snmp: first push keeps the device's file once and writes the controller's config",
		fn = function()
			local f = fresh({enabled = false})
			local st = {}
			local out = with_stderr(function()
				assert_true(snmp.apply(snmp.parse(ALL), st, true), "applied")
			end)
			assert_eq(f.files[snmp.BACKUP], STOCK, "original kept")
			assert_true(f.writes[1].path == snmp.BACKUP and f.writes[1].private, "backup written private")
			assert_true(st.snmp_owned, "owned")
			assert_false(st.snmp_was_enabled, "was off before")
			local s = f.db.snmpd
			assert_eq(s.general.enabled, "1", "on")
			assert_eq(s.general.snmp_version, "v1/v2c/v3", "both versions")
			assert_eq(s.public.community, "c0mmunity", "only the controller's community")
			assert_eq(s.public6.community, "c0mmunity", "and over IPv6")
			assert_eq(s.system.sysLocation, "Rack 2, row B", "location")
			assert_eq(s.system.sysContact, "noc@example.com", "contact")
			assert_eq(s.openuf_v3.username, "monitor", "v3 user")
			assert_eq(s.openuf_v3.auth_type, "SHA", "SHA")
			assert_eq(s.openuf_v3.privacy_type, "AES", "AES")
			assert_eq(s.agent.agentaddress, "UDP:161,UDP6:161", "both families")
			assert_true(cmd_has(f.cmds, "snmpd enable"), "enabled")
			assert_true(cmd_has(f.cmds, "snmpd restart"), "restarted")
			assert_false(out:find("c0mmunity", 1, true) ~= nil, "community not logged")
			assert_false(out:find("s3cretpass", 1, true) ~= nil, "password not logged")
			for k, v in pairs(st) do
				assert_false(tostring(v):find("c0mmunity", 1, true) ~= nil, "no secret in st." .. k)
			end
		end
	},
	{
		name = "snmp: the same push again restarts nothing; a hand edit is put back",
		fn = function()
			local f = fresh()
			local st = {}
			with_stderr(function() snmp.apply(snmp.parse(ALL), st, true) end)
			local n = #f.cmds
			with_stderr(function()
				assert_false(snmp.apply(snmp.parse(ALL), st, true), "unchanged")
			end)
			assert_eq(#f.cmds, n, "no exec")
			f.db.snmpd.public.community = "public"
			with_stderr(function()
				assert_true(snmp.apply(snmp.parse(ALL), st, true), "edit undone")
			end)
			assert_eq(f.db.snmpd.public.community, "c0mmunity", "controller's again")
			f.db.snmpd.extra = {[".name"] = "extra", [".type"] = "com2sec", community = "public"}
			with_stderr(function()
				assert_true(snmp.apply(snmp.parse(ALL), st, true), "extra section removed")
			end)
			assert_nil(f.db.snmpd.extra, "gone")
			assert_eq(f.files[snmp.BACKUP], STOCK, "backup never overwritten")
		end
	},
	{
		name = "snmp: off only on a full push, and then the device's file comes back",
		fn = function()
			local f = fresh({enabled = false})
			local st = {}
			with_stderr(function() snmp.apply(snmp.parse(ALL), st, true) end)
			local off = snmp.parse("radio.1.channel=6\n")
			assert_false(snmp.apply(off, st, false), "partial push decides nothing")
			assert_true(st.snmp_owned, "still owned")
			local n = #f.cmds
			with_stderr(function() assert_true(snmp.apply(off, st, true), "full push: off") end)
			assert_eq(f.files[snmp.CONFIG], STOCK, "original back")
			assert_nil(f.files[snmp.BACKUP], "backup dropped")
			local after = table.concat(f.cmds, "\n", n + 1)
			assert_contains(after, "snmpd stop", "stopped")
			assert_contains(after, "snmpd disable", "disabled: it was off before")
			assert_nil(st.snmp_owned, "ledger cleared")
			assert_nil(st.snmp_was_enabled, "ledger cleared")
			assert_false(snmp.apply(off, {}, true), "never owned: nothing")
		end
	},
	{
		name = "snmp: the nossl build drops v3 and does not claim it",
		fn = function()
			local f = fresh({ssl = false})
			assert_false(snmp.v3_capable(), "no v3")
			with_stderr(function() snmp.apply(snmp.parse(ALL), {}, true) end)
			assert_eq(f.db.snmpd.general.snmp_version, "v1/v2c", "v1/v2c only")
			assert_nil(f.db.snmpd.openuf_v3, "no v3 user")
			fresh()
			assert_true(snmp.v3_capable(), "ssl build")
			fresh({installed = false})
			assert_false(snmp.v3_capable(), "not installed")
			fresh({opkg = "snmpd-ssl"})
			assert_true(snmp.v3_capable(), "opkg (24.10): snmpd-ssl")
			fresh({opkg = "libnetsnmp-ssl"})
			assert_true(snmp.v3_capable(), "opkg (24.10): libnetsnmp-ssl")
			fresh({opkg = "snmpd-nossl"})
			assert_false(snmp.v3_capable(), "opkg (24.10): nossl")
		end
	},
	{
		name = "snmp: not installed is said once and touches nothing",
		fn = function()
			local f = fresh({installed = false})
			local st = {}
			local out = with_stderr(function()
				assert_false(snmp.apply(snmp.parse(ALL), st, true), "nothing")
				assert_false(snmp.apply(snmp.parse(ALL), st, true), "nothing")
			end)
			local _, n = out:gsub("apk add snmpd%-ssl", "")
			assert_eq(n, 1, "said once")
			assert_nil(next(st), "state untouched")
			assert_eq(#f.commits, 0, "no UCI write")
		end
	},
	{
		name = "snmp: on with nothing usable stops snmpd instead of leaving public",
		fn = function()
			local f = fresh()
			local st = {}
			local out = with_stderr(function()
				assert_true(snmp.apply(snmp.parse("snmp.status=enabled\nsnmp.version=1_2c\nsnmp.community=bad one\n"),
					st, true), "acted")
			end)
			assert_eq(f.db.snmpd.general.enabled, "0", "off")
			assert_nil(f.db.snmpd.public, "no public community left")
			assert_true(cmd_has(f.cmds, "snmpd stop") and cmd_has(f.cmds, "snmpd disable"), "stopped")
			assert_contains(out, "nothing in it is usable", "said why")
			local n = #f.cmds
			with_stderr(function()
				assert_false(snmp.apply(snmp.parse("snmp.status=enabled\nsnmp.version=1_2c\nsnmp.community=bad one\n"),
					st, true), "repeat: nothing")
			end)
			assert_eq(#f.cmds, n, "no exec")
		end
	},
	{
		name = "snmp: a backup that cannot be written means no takeover",
		fn = function()
			local f = fresh({backup_fails = true})
			local st = {}
			local out = with_stderr(function()
				assert_false(snmp.apply(snmp.parse(ALL), st, true), "not applied")
			end)
			assert_contains(out, "not taking snmpd over", "said")
			assert_eq(#f.commits, 0, "no UCI write")
			assert_nil(st.snmp_owned, "not owned")
		end
	},
	{
		name = "snmp: Forget puts the device's own snmpd back",
		fn = function()
			local f = fresh()
			local st = {}
			with_stderr(function() snmp.apply(snmp.parse(ALL), st, true) end)
			with_stderr(function() assert_true(snmp.restore_if_owned(st), "restored") end)
			assert_eq(f.files[snmp.CONFIG], STOCK, "original back")
			assert_true(cmd_has(f.cmds, "snmpd restart"), "restarted on it: it was on before")
			assert_nil(st.snmp_owned, "ledger cleared")
			assert_false(snmp.restore_if_owned({}), "never owned: nothing")
		end
	},
}
