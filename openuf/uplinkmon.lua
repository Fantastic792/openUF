--[[
	"Uplink Connectivity Monitor" (Settings -> WiFi -> Uplink Connectivity
	Monitor, the site's setting/connectivity `enabled`): an AP that cannot
	reach its uplink stops broadcasting its SSIDs, so clients do not join a
	dead end, and starts again when the uplink is back.

	THE WIRE (decompiled controller, upstream 2026-10-10; PROTOCOL-VALIDATION.md
	§ `connectivity.*`)

	connectivity.status=enabled only when the device claims wifi_caps 0x1
	(VWIRE, which openUF does since the mesh work) AND the site's connectivity
	setting is on; disabled otherwise. With it: connectivity.uplink=<host> for
	a custom monitor target (uplink_type=custom), or uplink_gateway=<ip>, plus
	the uplink_eth/uplink_wds/uplink_bridge names the mesh uses.

	WHAT THE FIRMWARE DOES (firmware-confirmed for 3.9.27 to 4.0.15, upstream's
	reading of ubntbox, mcad's uplink-monitor and syswrapper.sh)

	uplink-monitor runs only with connectivity.status=enabled. It probes the
	gateway, or connectivity.uplink, every ~15 s, twice per verdict; five
	"down" verdicts in a row (about a minute) run configure_vap up down down,
	which takes every user and guest VAP down; recovery is immediate. It also
	counts the target alive if its MAC was in the bridge FDB recently, and
	carrier loss as down at once -- neither is copied here (see below).

	WHAT OPENUF DOES

	One verdict per heartbeat: two pings to the target. FAIL_TICKS verdicts
	in a row take the user and guest SSIDs down -- their BSS netdevs, the way
	the WLAN schedule does (wlansched.lua), so hostapd stops each BSS alone;
	one answer brings them back. The mesh backhaul is never touched: the
	downlink is how children reach this AP, and the uplink station is how this
	AP finds its way back. No target (no default route), or a target that is
	not a plain host name, is "unknown" and holds whatever was in effect.

	Not copied: carrier loss as an instant verdict, which would blink a
	meshing AP's SSIDs during the wired-to-wireless switch (backhaul.lua waits
	two heartbeats) -- five verdicts outlast that switch; and the FDB shortcut,
	which only spares probes (OpenWrt ships no arping, and ping alone decides).
]]--

local M = {}
local util = package.loaded["openuf.util"]
	or assert(loadfile("util.lua") or loadfile("openuf/util.lua"))()

M.FAIL_TICKS = 5

-- The firmware probes every ~15 s. A verdict comes once per heartbeat, and a
-- dead uplink is a failed inform, whose backoff grows to 60 s: five verdicts
-- then took about 4.5 minutes in the lab instead of a minute. wait_cap keeps
-- the heartbeat at this while any verdict has failed, isolation included, so
-- the SSIDs also come back within one probe of the uplink returning.
M.PROBE_S = 15
-- The whole verdict's budget, in seconds: inform.lua asks once per
-- heartbeat, in its main loop. `-c 2 -W 2` waited 2 s after the second
-- probe, about 3 s of a dead uplink's heartbeat; `-w` ends ping at this
-- deadline whatever it has heard.
M.PING_DEADLINE = 2

-- Injectable seams.
M._exec = os.execute
M._popen = util.popen

M._fails = 0

-- system_cfg -> {enabled = bool, host = string|nil, gateway = string|nil},
-- or nil when the push carries no connectivity block at all. host is the
-- custom target; gateway the controller's idea of the gateway.
function M.parse(sys_raw)
	if type(sys_raw) ~= "string" then return nil end
	local seen, out = false, {enabled = false}
	for line in (sys_raw .. "\n"):gmatch("([^\n]*)\n") do
		local k, v = line:match("^connectivity%.([%w_]+)=(.*)$")
		if k then
			seen = true
			if k == "status" then out.enabled = (v == "enabled")
			elseif k == "uplink" and v ~= "" then out.host = v
			elseif k == "uplink_gateway" and v ~= "" and not out.gateway then out.gateway = v end
		end
	end
	return seen and out or nil
end

-- An address or a host name that is safe to put on a command line: never
-- starting with "-", which ping would read as an option.
local function valid_host(s)
	return type(s) == "string" and #s <= 253 and s:match("^[%w:][%w%.%-:]*$") ~= nil
end

-- The default route's gateway, or nil.
function M.default_gateway()
	local out = M._popen("ip -4 route show default 2>/dev/null") or ""
	local gw = out:match("default via (%d+%.%d+%.%d+%.%d+)")
	return gw
end

-- true/false, or nil when there is nothing to ask.
function M.reachable(host)
	host = host or M.default_gateway()
	if not valid_host(host) then return nil end
	-- Two probes per verdict, as the firmware: one answer is enough.
	return util.exec_ok(M._exec("ping -c 2 -w " .. M.PING_DEADLINE .. " " .. host .. " >/dev/null 2>&1"))
end

-- The longest the next heartbeat may wait, or nil: PROBE_S while a failed
-- verdict is counting (or holding the SSIDs down).
function M.wait_cap()
	if M._fails > 0 then return M.PROBE_S end
	return nil
end

-- Pure policy step. reachable: true/false/nil. Returns the new isolated
-- flag; the failure count lives on M. One answer ends isolation at once,
-- as the firmware's recovery does.
function M.decide(enabled, reachable, isolated)
	if not enabled then
		M._fails = 0
		return false
	end
	if reachable == true then
		M._fails = 0
		return false
	elseif reachable == false then
		M._fails = M._fails + 1
		return isolated or M._fails >= M.FAIL_TICKS
	end
	return isolated and true or false
end

return M
