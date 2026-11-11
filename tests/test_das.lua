-- Tests for openuf/das.lua (the RADIUS Dynamic Authorization relay: the
-- dispatcher port's CIDR check, WLAN routing and relay to hostapd).
-- Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true
local das = dofile("openuf/das.lua")

-- A RADIUS packet: code, id 7, a zero authenticator, then attrs {{type, value}}.
local function pkt(code, attrs)
	local body = {}
	for _, a in ipairs(attrs or {}) do
		body[#body + 1] = string.char(a[1], #a[2] + 2) .. a[2]
	end
	local b = table.concat(body)
	local len = 20 + #b
	return string.char(code, 7, math.floor(len / 256), len % 256) .. string.rep("\0", 16) .. b
end

local NAS, CALLED = 32, 30
local PLAN = {
	{port = 3801, nas_id = "nas-corp", ssid = "corp", clients = {"192.0.2.0/24"}},
	{port = 3802, nas_id = "nas-staff", ssid = "staff", clients = {"192.0.2.11/32", "198.51.100.5/32"}},
}

return {
	{
		name = "das: in_cidr",
		fn = function()
			assert_true(das.in_cidr("192.0.2.5", "192.0.2.0/24"), "inside a /24")
			assert_true(not das.in_cidr("192.0.2.5", "192.0.2.4/32"), "a /32 is one address")
			assert_true(das.in_cidr("192.0.2.5", "192.0.2.5"), "a bare address is a /32")
			assert_true(not das.in_cidr("192.0.2.6", "192.0.2.5"), "and only that one")
			assert_true(das.in_cidr("203.0.113.9", "0.0.0.0/0"), "/0 is everyone")
			assert_true(not das.in_cidr("192.0.2.5", "192.0.2.0/33"), "/33 matches nothing")
			assert_true(not das.in_cidr("192.0.2.5", "bogus"), "garbage matches nothing")
			assert_true(not das.in_cidr(nil, "192.0.2.0/24"), "no source, no match")
		end
	},
	{
		name = "das: parse refuses malformed packets",
		fn = function()
			assert_nil(das.parse("short"), "under 20 bytes")
			local p = pkt(40, {{NAS, "nas-corp"}})
			local code, attrs = das.parse(p)
			assert_eq(code, 40, "the code")
			assert_eq(attrs[NAS], "nas-corp", "the NAS-Identifier")
			-- The length field claims more than arrived.
			assert_nil(das.parse(p:sub(1, 2) .. string.char(0, 200) .. p:sub(5)), "length beyond the data")
			-- An attribute whose length is under 2 would loop forever.
			assert_nil(das.parse(string.char(40, 1, 0, 22) .. string.rep("\0", 16) .. string.char(32, 1)),
				"attribute length 1")
			assert_nil(das.parse(nil), "not a string")
		end
	},
	{
		name = "das: route checks the source, then NAS-ID, then the SSID",
		fn = function()
			assert_eq(#das.route(PLAN, "203.0.113.9", {}), 0, "a stranger reaches nothing")
			local all = das.route(PLAN, "192.0.2.11", {})
			assert_eq(#all, 2, "no hint: every WLAN that client may address")
			assert_eq(all[1].port, 3801, "in plan order")
			local only = das.route(PLAN, "192.0.2.50", {})
			assert_eq(#only, 1, "a client of one WLAN only")
			assert_eq(only[1].port, 3801, "that one")
			local by_nas = das.route(PLAN, "192.0.2.11", {[NAS] = "nas-staff"})
			assert_eq(#by_nas, 1, "the NAS-ID picks one")
			assert_eq(by_nas[1].port, 3802, "the WLAN with that NAS ID")
			local by_ssid = das.route(PLAN, "192.0.2.11", {[CALLED] = "02-00-00-00-00-01:corp"})
			assert_eq(#by_ssid, 1, "the Called-Station-Id SSID picks one")
			assert_eq(by_ssid[1].port, 3801, "the WLAN with that SSID")
			assert_eq(#das.route(PLAN, "192.0.2.11", {[NAS] = "other"}), 2,
				"an unknown NAS-ID falls back to every allowed WLAN")
		end
	},
	{
		name = "das: handle relays Disconnect/CoA only, first ACK wins",
		fn = function()
			local asked
			local function relay_with(answers)
				asked = {}
				return function(port, data)
					asked[#asked + 1] = port
					return answers[port]
				end
			end
			local req = pkt(40, {})
			assert_nil(das.handle(PLAN, pkt(1, {}), "192.0.2.11", relay_with({})), "an Access-Request")
			assert_eq(#asked, 0, "is never relayed")
			assert_nil(das.handle(PLAN, "garbage", "192.0.2.11", relay_with({})), "garbage")
			assert_eq(#asked, 0, "is never relayed")
			assert_nil(das.handle(PLAN, req, "203.0.113.9", relay_with({})), "a stranger")
			assert_eq(#asked, 0, "is never relayed")
			local nak, ack = pkt(42, {}), pkt(41, {})
			assert_eq(das.handle(PLAN, req, "192.0.2.11", relay_with({[3801] = nak, [3802] = ack})), ack,
				"the WLAN that has the session answers")
			assert_eq(das.handle(PLAN, req, "192.0.2.11", relay_with({[3801] = ack, [3802] = nak})), ack,
				"first ACK")
			assert_eq(#asked, 1, "ends the search")
			assert_eq(das.handle(PLAN, req, "192.0.2.11", relay_with({[3801] = nak})), nak,
				"no ACK anywhere: the last answer")
			assert_nil(das.handle(PLAN, req, "192.0.2.11", relay_with({})), "hostapd silent: nothing to send")
			assert_eq(#asked, 2, "after asking each")
			assert_eq(das.handle(PLAN, pkt(43, {}), "192.0.2.11", relay_with({[3801] = pkt(44, {})})):byte(1), 44,
				"a CoA-Request too")
		end
	},
	{
		name = "das: udp_relay asks hostapd on localhost and always closes",
		fn = function()
			local log = {}
			local function fake(reply, bind_ok)
				return {udp = function()
					return {
						setsockname = function(_, ip, port) log[#log + 1] = "bind " .. ip; return bind_ok end,
						settimeout = function(_, t) log[#log + 1] = "timeout " .. t end,
						sendto = function(_, d, ip, port) log[#log + 1] = "send " .. ip .. ":" .. port end,
						receive = function() return reply end,
						close = function() log[#log + 1] = "close" end,
					}
				end}
			end
			assert_eq(das.udp_relay(fake("ans", 1))(3801, "req"), "ans", "hostapd's answer")
			assert_eq(table.concat(log, ","), "bind 127.0.0.1,timeout 2,send 127.0.0.1:3801,close",
				"from 127.0.0.1, the 2 s bound, then closed")
			log = {}
			assert_nil(das.udp_relay(fake("ans", nil))(3801, "req"), "cannot bind: nothing")
			assert_eq(log[#log], "close", "and still closed")
		end
	},
}
