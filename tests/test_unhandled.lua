-- Tests for openuf/unhandled.lua (the ledger of unhandled protocol surfaces).
-- Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true
local cjson = require("cjson")
local unhandled = dofile("openuf/unhandled.lua")

local FILE = "/tmp/openuf_test_unhandled.json"

local function fresh(t0)
	os.remove(FILE)
	os.remove(FILE .. ".tmp")
	unhandled._reset(FILE)
	unhandled.MAX_ENTRIES       = 150
	unhandled.MAX_PAYLOAD_BYTES = 2048
	unhandled.MAX_VALUE_CHARS   = 200
	unhandled.FLUSH_INTERVAL    = 300
	local now = t0 or 1700000000
	unhandled._time = function() return now end
	return function(t) now = t end
end

local function read_file()
	local f = io.open(FILE, "r")
	if not f then return nil end
	local raw = f:read("*a")
	f:close()
	return raw
end

return {
	{
		name = "unhandled: first record creates an entry with count 1 and both timestamps",
		fn = function()
			fresh(1700000000)
			local e, is_new = unhandled.record("cmd", "mesh-halt", {cmd = "mesh-halt", mac = "00:00:5e:00:53:01"})
			assert_true(is_new, "first sighting is new")
			assert_eq(e.category, "cmd", "category")
			assert_eq(e.key, "mesh-halt", "key")
			assert_eq(e.count, 1, "count")
			assert_eq(e.first_seen, "2023-11-14T22:13:20Z", "first_seen is ISO UTC")
			assert_eq(e.last_seen, e.first_seen, "last_seen == first_seen on the first sighting")
			assert_eq(e.payload.mac, "00:00:5e:00:53:01", "payload kept")
			assert_eq(unhandled.entry("cmd", "mesh-halt"), e, "entry() finds it")
		end
	},
	{
		name = "unhandled: a repeat sighting increments the count and moves last_seen only",
		fn = function()
			local set_time = fresh(1700000000)
			unhandled.record("cmd", "mesh-halt", {a = 1})
			set_time(1700000060)
			local e, is_new = unhandled.record("cmd", "mesh-halt", {a = 2})
			assert_false(is_new, "second sighting is not new")
			assert_eq(e.count, 2, "count")
			assert_eq(e.first_seen, "2023-11-14T22:13:20Z", "first_seen unchanged")
			assert_eq(e.last_seen, "2023-11-14T22:14:20Z", "last_seen advanced")
			assert_eq(e.payload.a, 2, "payload is the latest one")
			assert_eq(unhandled.count(), 1, "still one entry")
		end
	},
	{
		name = "unhandled: redact replaces secret-named fields at any depth and keeps the rest",
		fn = function()
			fresh()
			local out = unhandled.redact({
				cmd = "x", psk = "hunter2", authkey = "ff", guest_token = "t",
				nested = {radius_secret = "s", wpa_passphrase = "p", ok = "kept", deeper = {api_key = "k"}},
				list = {"a", "b"},
			})
			assert_eq(out.cmd, "x", "plain field kept")
			assert_eq(out.psk, "<redacted>", "psk")
			assert_eq(out.authkey, "<redacted>", "authkey")
			assert_eq(out.guest_token, "<redacted>", "token")
			assert_eq(out.nested.radius_secret, "<redacted>", "nested secret")
			assert_eq(out.nested.wpa_passphrase, "<redacted>", "nested passphrase")
			assert_eq(out.nested.ok, "kept", "nested plain field kept")
			assert_eq(out.nested.deeper.api_key, "<redacted>", "*_key two levels down")
			assert_eq(out.list[2], "b", "arrays survive")
			-- The name test is what redact(value, name) exposes for callers
			-- that hold a bare key=value pair (the system_cfg rows).
			assert_eq(unhandled.redact("v", "aaa.1.wpa.psk"), "<redacted>", "bare value under a psk key")
			assert_eq(unhandled.redact("WPA-PSK", "aaa.1.wpa.key.1.mgmt"), "WPA-PSK",
				"'key' in the middle of a name is not a secret")
			assert_eq(unhandled.redact("stun://h:3478/", "stun_url"), "stun://h:3478/", "plain name kept")
		end
	},
	{
		name = "unhandled: redact cuts long strings and caps nesting",
		fn = function()
			fresh()
			unhandled.MAX_VALUE_CHARS = 10
			local out = unhandled.redact("0123456789abcdef")
			assert_eq(out, "0123456789...(+6 chars)", "cut with a marker")
			local deep = {a = {b = {c = {d = {e = {f = 1}}}}}}
			local r = unhandled.redact(deep)
			assert_eq(r.a.b.c.d, "<nested>", "nesting capped at depth 4")
		end
	},
	{
		name = "unhandled: a failed write never replaces the ledger and is said once",
		fn = function()
			fresh(1700000000)
			unhandled.record("mgmt_cfg", "a", {})
			assert_true(unhandled.flush(), "a good ledger on disk")
			local good = read_file()
			-- A full overlay: open works, the write (or the flush at close) fails.
			local said = {}
			local o_open, o_err = unhandled._open, io.stderr
			unhandled._open = function(path, mode)
				local f = {}
				function f:write() return nil, "No space left on device" end
				function f:close() return true end
				assert_eq(path, FILE .. ".tmp", "only the temp file is opened")
				local real = io.open(path, mode)  -- so the test can see it removed
				if real then real:close() end
				return f
			end
			io.stderr = {write = function(_, m) said[#said + 1] = m end}
			local ok, err = pcall(function()
				unhandled.record("mgmt_cfg", "b", {})
				local w, why = unhandled.flush()
				assert_false(w, "not written")
				assert_contains(why, "No space left", "says why")
				unhandled.flush(true)
				assert_eq(#said, 1, "said once, not every heartbeat")
				assert_eq(read_file(), good, "the last good ledger is untouched")
				assert_nil(io.open(FILE .. ".tmp", "r"), "no partial temp file left")
			end)
			unhandled._open, io.stderr = o_open, o_err
			if not ok then error(err, 0) end
			assert_true(unhandled.flush(), "space again: written")
			assert_not_nil(unhandled.load()["mgmt_cfg/b"], "with the entry it held back")
		end
	},
	{
		name = "unhandled: a new entry is flushed at once and reads back after load",
		fn = function()
			fresh(1700000000)
			unhandled.record("mgmt_cfg", "stun_url", {stun_url = "stun://192.0.2.1:3478/"})
			assert_true(unhandled.flush(), "new entry -> written")
			local raw = read_file()
			assert_not_nil(raw, "file exists")
			local doc = cjson.decode(raw)
			assert_eq(doc.version, 1, "version")
			assert_eq(doc.entries["mgmt_cfg/stun_url"].count, 1, "entry on disk")
			assert_eq(doc.entries["mgmt_cfg/stun_url"].payload.stun_url, "stun://192.0.2.1:3478/", "payload on disk")
			assert_nil(io.open(FILE .. ".tmp", "r"), "temp file renamed away")

			unhandled._reset(FILE)
			assert_eq(unhandled.count(), 0, "reset forgets")
			unhandled.load()
			assert_eq(unhandled.count(), 1, "load reads it back")
			assert_eq(unhandled.entry("mgmt_cfg", "stun_url").count, 1, "count preserved")
			local e = unhandled.record("mgmt_cfg", "stun_url", {stun_url = "stun://192.0.2.1:3478/"})
			assert_eq(e.count, 2, "counting continues from the loaded value")
			assert_eq(e.first_seen, "2023-11-14T22:13:20Z", "first_seen survives the restart")
		end
	},
	{
		name = "unhandled: repeat counts are written only every FLUSH_INTERVAL, new entries at once",
		fn = function()
			local set_time = fresh(1700000000)
			unhandled.load()   -- sets last_flush = now, as run() does
			unhandled.record("cmd", "a", {})
			assert_true(unhandled.flush(), "new -> written")
			set_time(1700000010)
			unhandled.record("cmd", "a", {})
			assert_false(unhandled.flush(), "repeat 10 s later -> not yet")
			assert_true(unhandled._dirty, "but still dirty")
			set_time(1700000010 + 300)
			assert_true(unhandled.flush(), "repeat after the interval -> written")
			assert_false(unhandled.flush(), "clean -> nothing to write")
			set_time(1700000010 + 301)
			unhandled.record("cmd", "b", {})
			assert_true(unhandled.flush(), "a NEW entry is written at once whatever the clock says")
			set_time(1700000010 + 302)
			unhandled.record("cmd", "b", {})
			assert_true(unhandled.flush(true), "force writes a repeat")
		end
	},
	{
		name = "unhandled: MAX_ENTRIES evicts the entry seen longest ago",
		fn = function()
			local set_time = fresh(1700000000)
			unhandled.MAX_ENTRIES = 3
			unhandled.record("cmd", "old", {})
			set_time(1700000001); unhandled.record("cmd", "mid", {})
			set_time(1700000002); unhandled.record("cmd", "new", {})
			set_time(1700000003); unhandled.record("cmd", "old", {})   -- refreshed
			set_time(1700000004); unhandled.record("cmd", "newest", {})
			assert_eq(unhandled.count(), 3, "capped")
			assert_nil(unhandled.entry("cmd", "mid"), "the one seen longest ago went")
			assert_not_nil(unhandled.entry("cmd", "old"), "a refreshed old entry stays")
			assert_not_nil(unhandled.entry("cmd", "newest"), "the newcomer stays")
		end
	},
	{
		name = "unhandled: an oversize payload is replaced by its key list",
		fn = function()
			fresh()
			unhandled.MAX_PAYLOAD_BYTES = 64
			unhandled.MAX_VALUE_CHARS = 1000
			local e = unhandled.record("response", "huge", {
				alpha = string.rep("x", 100), beta = string.rep("y", 100), cmd = "z",
			})
			assert_nil(e.payload.alpha, "values dropped")
			assert_true(e.payload._truncated_bytes > 64, "size recorded")
			assert_eq(table.concat(e.payload._keys, ","), "alpha,beta,cmd", "sorted key list kept")
		end
	},
	{
		name = "unhandled: _file = false counts in memory and never writes",
		fn = function()
			fresh()
			unhandled._file = false
			unhandled.load()
			unhandled.record("cmd", "x", {})
			assert_false(unhandled.flush(true), "nothing written")
			assert_nil(read_file(), "no file")
			assert_eq(unhandled.entry("cmd", "x").count, 1, "still counted")
			assert_false(unhandled._dirty, "flush cleared the dirty flag so it is not retried every tick")
		end
	},
	{
		name = "unhandled: a garbage or partial file starts an empty ledger",
		fn = function()
			fresh()
			local f = io.open(FILE, "w"); f:write("{not json"); f:close()
			local o_stderr = io.stderr
			local warned = ""
			io.stderr = {write = function(_, s) warned = warned .. s end}
			unhandled.load()
			io.stderr = o_stderr
			assert_eq(unhandled.count(), 0, "empty")
			assert_contains(warned, "not valid JSON", "said so")
			-- Entries missing their identity are skipped, the rest kept.
			f = io.open(FILE, "w")
			f:write('{"version":1,"entries":{"cmd/ok":{"category":"cmd","key":"ok","count":"3"},"bad":{"count":1}}}')
			f:close()
			unhandled.load()
			assert_eq(unhandled.count(), 1, "one valid entry")
			assert_eq(unhandled.entry("cmd", "ok").count, 3, "count coerced to a number")
		end
	},
	{
		-- The ledger is shown on a LuCI page now, to every user with the
		-- openUF ACL: names a controller uses for credentials besides
		-- password/passphrase are secrets too.
		name = "unhandled: passwd, pwd, pass, community, credential and cookie names are secrets",
		fn = function()
			for _, n in ipairs({"sshd.auth.passwd", "admin_pwd", "radius.pass", "snmp.community",
					"x_credential", "session_cookie"}) do
				assert_true(unhandled.is_secret_name(n), n)
			end
			for _, n in ipairs({"bcfilt.bypass_types", "passthrough", "compass"}) do
				assert_false(unhandled.is_secret_name(n), n .. " is not a secret")
			end
		end
	},
	{
		-- A ledger written before a name joined the list still holds the value;
		-- load() redacts it again and marks the file for rewriting.
		name = "unhandled: load re-redacts a ledger written before a name was added",
		fn = function()
			fresh(1700000000)
			local f = io.open(FILE, "w")
			f:write(cjson.encode({version = 1, entries = {
				["system_cfg/snmp.community"] = {category = "system_cfg", key = "snmp.community",
					count = 1, payload = {value = "hunter2", sample = "snmp.community", occurrences = 1}},
				["field/setparam.x"] = {category = "field", key = "setparam.x", count = 1,
					payload = {admin_pwd = "hunter2", keep = "this"}},
			}}))
			f:close()
			unhandled.load()
			local a = unhandled.entry("system_cfg", "snmp.community")
			assert_eq(a.payload.value, "<redacted>", "the sample's value, by its key name")
			assert_eq(a.payload.sample, "snmp.community", "the key name itself stays")
			local b = unhandled.entry("field", "setparam.x")
			assert_eq(b.payload.admin_pwd, "<redacted>", "a field by its own name")
			assert_eq(b.payload.keep, "this", "the rest stays")
			assert_true(unhandled._dirty, "rewritten at the next flush")
			assert_true(unhandled.flush(true), "flushed")
			local raw = read_file()
			assert_true(raw:find("hunter2", 1, true) == nil, "gone from the file")
		end
	},
}
