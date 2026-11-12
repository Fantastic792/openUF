--[[
	RADIUS Dynamic Authorization relay (RFC 5176: Disconnect-Request,
	CoA-Request): one dispatcher on the controller's port (aaa.radius.dad.port,
	3799) in front of each WLAN's hostapd DAS listener (3800 + n).

	Ported from fonix232/openUF (openuf/src/openwrt/das.lua, MIT; the notice
	is in NOTICE). The file plan (save/load) is left out: state.json's `das`
	holds it here.

	The controller sends, to a device claiming fw_caps 0x100000, for a WLAN
	whose RADIUS profile has DAS (or Hotspot 2.0) and accounting on:
	  aaa.radius.dad.status=enabled, aaa.radius.dad.port=3799    the dispatcher
	  aaa.<n>.radius.dad.client.<k>.cidr=<ip>/32, .secret        may send to it
	  aaa.<n>.radius.das.{status,port,client,secret}             the WLAN's own
	The dispatcher's clients are every accounting server. UAP firmware then
	writes radius_das_client=127.0.0.1 <secret>, so only its own daemon reaches
	hostapd. openUF does the same: this module takes the request, checks the
	sender, picks the WLAN(s) and relays the bytes unchanged from 127.0.0.1.
	The authenticators are keyed on the shared secret, not on addresses, so
	hostapd still checks the server's secret end to end.

	Which WLAN: a NAS-Identifier naming a WLAN's NAS ID, else a
	Called-Station-Id ("<BSSID>:<SSID>") naming its SSID, else every WLAN the
	sender may address, answered with the first ACK (a WLAN without the
	session NAKs). A plan WLAN: {port, nas_id, ssid, clients = {cidr, ...}}.
]]--

local M = {}

M.PORT    = 3799
M.TIMEOUT = 2

M.CODE = {
	DISCONNECT_REQUEST = 40, DISCONNECT_ACK = 41, DISCONNECT_NAK = 42,
	COA_REQUEST = 43, COA_ACK = 44, COA_NAK = 45,
}
local ATTR_CALLED_STATION_ID = 30
local ATTR_NAS_IDENTIFIER    = 32

-- code, {type = first value}, or nil for anything that is not a well-formed
-- RADIUS packet.
function M.parse(data)
	if type(data) ~= "string" or #data < 20 then return nil end
	local len = data:byte(3) * 256 + data:byte(4)
	if len < 20 or len > #data then return nil end
	local attrs, i = {}, 21
	while i <= len do
		if i + 1 > len then return nil end
		local t, l = data:byte(i), data:byte(i + 1)
		if l < 2 or i + l - 1 > len then return nil end
		if attrs[t] == nil then attrs[t] = data:sub(i + 2, i + l - 1) end
		i = i + l
	end
	return data:byte(1), attrs
end

local function ipv4(s)
	local a, b, c, d = (s or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then return nil end
	a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
	if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
	return ((a * 256 + b) * 256 + c) * 256 + d
end

-- Whether IPv4 ip is inside cidr ("a.b.c.d/n"; a bare address is /32).
function M.in_cidr(ip, cidr)
	local net, bits = (cidr or ""):match("^([^/]+)/(%d+)$")
	net, bits = net or cidr, tonumber(bits) or 32
	local x, n = ipv4(ip), ipv4(net)
	if not (x and n) or bits > 32 then return false end
	if bits <= 0 then return true end
	local size = 2 ^ (32 - bits)
	return math.floor(x / size) == math.floor(n / size)
end

-- The plan WLANs a request from src_ip should go to, in order.
function M.route(plan, src_ip, attrs)
	local allowed = {}
	for _, e in ipairs(plan or {}) do
		for _, c in ipairs(e.clients or {}) do
			if M.in_cidr(src_ip, c) then allowed[#allowed + 1] = e break end
		end
	end
	if #allowed == 0 then return allowed end
	local function only(pred)
		local hit = {}
		for _, e in ipairs(allowed) do if pred(e) then hit[#hit + 1] = e end end
		return hit
	end
	local nas = attrs[ATTR_NAS_IDENTIFIER]
	if nas then
		local hit = only(function(e) return e.nas_id == nas end)
		if #hit > 0 then return hit end
	end
	local called = attrs[ATTR_CALLED_STATION_ID]
	if called then
		local ssid = called:match("^%x%x[%-:]%x%x[%-:]%x%x[%-:]%x%x[%-:]%x%x[%-:]%x%x:(.*)$")
		if ssid then
			local hit = only(function(e) return e.ssid == ssid end)
			if #hit > 0 then return hit end
		end
	end
	return allowed
end

local function is_ack(code)
	return code == M.CODE.DISCONNECT_ACK or code == M.CODE.COA_ACK
end

-- The answer to one datagram from src_ip, or nil (nothing to send).
-- relay: function(ports, data) -> hostapd's answer or nil.
function M.handle(plan, data, src_ip, relay)
	local code, attrs = M.parse(data)
	if code ~= M.CODE.DISCONNECT_REQUEST and code ~= M.CODE.COA_REQUEST then
		return nil
	end
	local ports = {}
	for _, e in ipairs(M.route(plan, src_ip, attrs)) do ports[#ports + 1] = e.port end
	if #ports == 0 then return nil end
	return relay(ports, data)
end

-- relay() for handle(): ask hostapd's listeners on 127.0.0.1 from one socket.
-- One shared budget for all of them: asking each in turn waited timeout per
-- silent WLAN, so a fan-out (or spoofed senders inside the CIDR) stalled the
-- idle wait for N x timeout. The first ACK wins, else the last answer. A reply
-- needs the request's Identifier (byte 2) and a asked port, or a stray datagram
-- on the ephemeral port could answer for hostapd.
function M.udp_relay(socket, timeout)
	return function(ports, data)
		local u = socket.udp()
		if not u then return nil end
		if not u:setsockname("127.0.0.1", 0) then u:close() return nil end
		local pending, n = {}, 0
		for _, port in ipairs(ports) do
			u:sendto(data, "127.0.0.1", port)
			if not pending[port] then pending[port] = true n = n + 1 end
		end
		local id = data:byte(2)
		local deadline = socket.gettime() + (timeout or M.TIMEOUT)
		local answer
		while n > 0 do
			local left = deadline - socket.gettime()
			if left <= 0 then break end
			u:settimeout(left)
			local r, ip, port = u:receivefrom()
			if not r then break end
			if ip == "127.0.0.1" and pending[port] and #r >= 20 and r:byte(2) == id then
				pending[port] = nil
				n = n - 1
				answer = r
				if is_ack(r:byte(1)) then break end
			end
		end
		u:close()
		return answer
	end
end

return M
