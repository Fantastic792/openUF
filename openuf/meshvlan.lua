--[[
	meshvlan.lua -- a tagged SSID's VLAN over the mesh hop, on a swconfig board.

	Why only swconfig. On a DSA board the per-VLAN bridge's uplink is
	`br-lan.<vid>`, a VLAN device on the LAN bridge itself (lan_cpueth is
	br-lan there, see ucihelper.ensure_vlan_network), so the VLAN follows br-lan
	wherever the uplink is: out of the wired socket, or over the 4-address
	station when the device is a wireless child. Nothing to add.

	A swconfig board's per-VLAN bridge rides `eth0.<vid>`, the CPU trunk's
	sub-device, which switchvlan trunks to the uplink socket. That path ends at
	the switch. A wireless child has no wired uplink for it to reach, and a
	parent never sees a child's tagged frames there: they arrive in br-lan, from
	the WDS link. So the VLAN bridge needs `br-lan.<vid>` as a second uplink, the
	one DSA already has.

	The hazard that makes this a module rather than one more port in UCI.
	br-lan's wired member on a swconfig board is eth0.1, itself a VLAN device on
	the trunk. A tagged frame br-lan hands to eth0.1 leaves double-tagged (outer
	1, inner <vid>); the switch strips the outer tag on the way out of the
	untagged LAN sockets, and the frame reaches the wire as an ordinary VLAN
	<vid> frame. With br-lan.<vid> in the VLAN bridge and nothing else, every
	broadcast on that VLAN would come in through eth0.<vid>, cross into br-lan
	and go straight back out of the uplink socket: a reflection that moves every
	sender's MAC onto this AP's port upstream, and an endless storm between two
	such APs. So the extra port only ever exists behind a guard:

	  * nft table `bridge openuf_meshvlan`: a VLAN-tagged frame may enter or
	    leave the LAN bridge only through a wireless port (phy*, wlan*, ath* --
	    the mesh station, a parent's per-child WDS netdevs, the VAPs). Every
	    wired port is refused them in both directions, eth0.1 and any socket
	    netdev alike. The rules match interface-name patterns, so a wired port
	    netifd adds later is covered without a resync, and a new child's WDS
	    netdev is allowed without one.
	  * `br-lan.<vid>` is runtime state, never UCI. netifd would bring a UCI
	    port up at boot, long before openUF can install the guard. This module
	    adds the port only after the guard is in, puts the guard back once a
	    minute, and deletes the ports the moment the guard cannot be installed.
	    A reboot clears both; openUF rebuilds them in that order.
	  * learning is off on `br-lan.<vid>`, as ucihelper already has it on
	    `eth0.<vid>`. The VLAN bridge then never remembers the gateway behind
	    the uplink that just went away when the device moves between wire and
	    air: unicast to it floods to both, and the dead path drops the copy
	    (the guard on a wired node, the switch on a wireless one). The price
	    is one extra pass through br-lan per upstream frame on a wired node.

	Scope: the VLANs this AP itself has a tagged SSID, or a private key's
	VLAN, on. A swconfig parent cannot carry a child's VLAN it has no bridge
	for: the switch drops a VID it has no table entry for, and the guard keeps
	the child's frames off the wired sockets instead of leaking them there.

	NOT verified on hardware yet. The untagged mesh it builds on ran on a
	Deco M4R v1 on 2026-10-19 (user, shallow: online over the wireless
	uplink with the cable pulled); a tagged SSID across the hop has not been
	tried there. What to look at is in USAGE.md (the mesh section).
	Checked on a real kernel (OpenWrt 25.12.6, Linux 6.12, nftables 1.1.6, in
	a VM, 2026-10-18) with veth stand-ins for a wired and a wireless port:
	nft takes the rules as written; a tagged frame crosses from the
	wireless-named port into the VLAN bridge and not from the wired one;
	frames the VLAN bridge sends into br-lan reach the wireless port and not
	the wired one (0 with the guard, all of them without it); untagged
	traffic is untouched; resync re-attaches the port after the VLAN bridge
	is recreated; and busybox `ip` creates, enslaves and deletes the port.
]]--

local M = {}
local util = package.loaded["openuf.util"]
	or assert(loadfile("util.lua") or loadfile("openuf/util.lua"))()

-- Injectable seams, as in l2guard.lua.
M._exec      = os.execute
M._read_file = util.read_file
M._write_file = function(path, value)
	local f = io.open(path, "w")
	if not f then return false end
	local ok = f:write(value)
	f:close()
	return ok ~= nil
end
M._log  = function(msg) io.stderr:write("meshvlan: " .. msg .. "\n") end
M._time = os.time

M.NFT_TABLE  = "bridge openuf_meshvlan"
M.VLAN_BRIDGE_PREFIX = "br-openuf"
-- The netdev names OpenWrt gives wireless interfaces: phy<n>-ap<m>,
-- phy<n>-sta<m> and a WDS AP's per-station phy<n>-ap<m>.sta<k> since 23.05;
-- wlan<n>, wlan<n>-<m>, wlan<n>.sta<k> before; ath<n> for the names UniFi uses.
M.WIRELESS_PATTERNS = {"phy*", "wlan*", "ath*"}
-- How often the guard is put back regardless (a hand-run `nft flush ruleset`
-- would otherwise leave the ports unguarded until the next push).
M.GUARD_INTERVAL = 60

M._guard_ok   = false
M._guard_next = 0
M._warned     = {}

local valid_ifname = util.valid_ifname

local function warn_once(key, msg)
	if M._warned[key] then return end
	M._warned[key] = true
	M._log(msg)
end

local function exists(dev)
	return valid_ifname(dev) and M._read_file("/sys/class/net/" .. dev .. "/ifindex") ~= nil
end

local function run(cmd)
	return util.exec_ok(M._exec(cmd .. " >/dev/null 2>&1"))
end

-- The VLAN ids of a record, as sorted unique integers in 1..4094. Tolerant of
-- the shapes a JSON round trip can give a list (string keys, string values).
function M.vids_of(rec)
	local out, seen = {}, {}
	if type(rec) ~= "table" or type(rec.vids) ~= "table" then return out end
	for _, v in pairs(rec.vids) do
		local n = tonumber(v)
		if n and n == math.floor(n) and n >= 1 and n <= 4094 and not seen[n] then
			seen[n] = true
			out[#out + 1] = n
		end
	end
	table.sort(out)
	return out
end

-- The record a push asks for: nil when nothing is to be carried.
--   bridge: the LAN bridge (backhaul.lan_bridge)
--   vids:   the VLANs of this AP's tagged SSIDs
function M.record(bridge, vids)
	if not valid_ifname(bridge) then return nil end
	local rec = {bridge = bridge, vids = {}}
	rec.vids = M.vids_of({vids = vids})
	if #rec.vids == 0 then return nil end
	-- The port name must fit IFNAMSIZ: "br-lan.4094" does, a long bridge
	-- name with a long VID might not, and such a VID is left out loudly.
	local kept = {}
	for _, vid in ipairs(rec.vids) do
		if valid_ifname(bridge .. "." .. vid) then
			kept[#kept + 1] = vid
		else
			warn_once("name:" .. bridge .. vid, ("%s.%d is longer than a netdev name may be -- "
				.. "VLAN %d is not carried over the mesh hop"):format(bridge, vid, vid))
		end
	end
	rec.vids = kept
	if #kept == 0 then return nil end
	return rec
end

-- ─── The guard ───────────────────────────────────────────────────────────────

function M.guard_stmts(bridge)
	local T = M.NFT_TABLE
	local not_wireless_in, not_wireless_out = {}, {}
	for _, p in ipairs(M.WIRELESS_PATTERNS) do
		not_wireless_in[#not_wireless_in + 1]   = 'iifname != "' .. p .. '"'
		not_wireless_out[#not_wireless_out + 1] = 'oifname != "' .. p .. '"'
	end
	return {
		-- -300: before the bridge looks at the frame, where l2guard's drops sit.
		"add chain " .. T .. " pre { type filter hook prerouting priority -300; policy accept; }",
		-- postrouting sees every frame the bridge sends, forwarded, flooded or
		-- from the bridge's own upper devices (br-lan.<vid>) alike.
		"add chain " .. T .. " post { type filter hook postrouting priority 0; policy accept; }",
		"add rule " .. T .. ' pre meta ibrname "' .. bridge .. '" ether type vlan '
			.. table.concat(not_wireless_in, " ") .. " drop",
		"add rule " .. T .. ' post meta obrname "' .. bridge .. '" ether type vlan '
			.. table.concat(not_wireless_out, " ") .. " drop",
	}
end

-- Install (replace) the guard for this LAN bridge, as ONE nft transaction:
-- all of it or none of it, and on failure the kernel is exactly as it was --
-- including an older copy of the guard, which must outlive the ports it
-- protects. util.nft_apply is not used on purpose: when its batch fails it
-- deletes the table first and re-adds statement by statement, which would
-- leave the ports unguarded in between. True only when everything went in.
function M.guard(bridge)
	if not valid_ifname(bridge) then return false end
	local T = M.NFT_TABLE
	local script = "add table " .. T .. "\ndelete table " .. T .. "\nadd table " .. T .. "\n"
		.. table.concat(M.guard_stmts(bridge), "\n") .. "\n"
	local ok = util.nft_run(script, M._exec)
	if not ok then
		warn_once("guard", "nft refused the VLAN guard (it needs nftables and kmod-nft-bridge) -- "
			.. "tagged SSIDs are NOT carried over the mesh hop; untagged ones are unaffected")
	else
		M._warned.guard = nil
	end
	return ok and true or false
end

function M.unguard()
	util.nft_apply(M.NFT_TABLE, nil, M._exec)
end

-- ─── The ports ───────────────────────────────────────────────────────────────

function M.port_name(bridge, vid) return bridge .. "." .. tostring(vid) end

-- Make <bridge>.<vid> exist, sit in br-openuf<vid>, learn nothing and be up.
-- Returns "ok", "waiting" (the VLAN bridge is not there yet: netifd builds it
-- after a push, asynchronously) or "failed".
function M.ensure_port(bridge, vid)
	local dev = M.port_name(bridge, vid)
	local vbr = M.VLAN_BRIDGE_PREFIX .. tostring(vid)
	if not (valid_ifname(bridge) and valid_ifname(dev) and valid_ifname(vbr)) then return "failed" end
	if not exists(vbr) then return "waiting" end
	if not exists(bridge) then return "waiting" end
	if not exists(dev) then
		if not run(("ip link add link %s name %s type vlan id %d"):format(bridge, dev, vid))
				or not exists(dev) then
			warn_once("add:" .. dev, "could not create " .. dev
				.. " (`ip link add ... type vlan` failed) -- VLAN " .. vid
				.. " is not carried over the mesh hop")
			return "failed"
		end
	end
	if util.master_of(dev, M._read_file) ~= vbr then
		if not run(("ip link set dev %s master %s"):format(dev, vbr))
				or util.master_of(dev, M._read_file) ~= vbr then
			warn_once("master:" .. dev, "could not add " .. dev .. " to " .. vbr)
			return "failed"
		end
		M._log("carrying VLAN " .. vid .. " over the mesh hop: " .. dev .. " in " .. vbr)
	end
	local learning = "/sys/class/net/" .. dev .. "/brport/learning"
	local l = M._read_file(learning)
	if l and l:match("%d") ~= "0" then M._write_file(learning, "0") end
	local op = M._read_file("/sys/class/net/" .. dev .. "/operstate")
	if op and op:match("%S+") == "down" then run("ip link set dev " .. dev .. " up") end
	M._warned["add:" .. dev], M._warned["master:" .. dev] = nil, nil
	return "ok"
end

function M.remove_port(bridge, vid)
	local dev = M.port_name(bridge, vid)
	if exists(dev) then
		run("ip link del dev " .. dev)
		M._log("no longer carrying VLAN " .. vid .. " over the mesh hop: " .. dev .. " deleted")
		return true
	end
	return false
end

local function remove_all(rec)
	if type(rec) ~= "table" or not valid_ifname(rec.bridge) then return end
	for _, vid in ipairs(M.vids_of(rec)) do M.remove_port(rec.bridge, vid) end
end

-- The guard could not be installed: the ports go first, then whatever is
-- left of the table.
local function fail_closed(rec)
	remove_all(rec)
	M.unguard()
	M._guard_ok = false
end

-- ─── Reconcile ───────────────────────────────────────────────────────────────

-- Bring the kernel to `rec` from `prev` (the record the last reconcile was
-- for, so its ports can be taken away). Either may be nil. Order is the whole
-- point: ports go before the guard, and come only after it. Returns true when
-- the guard is in (or nothing is wanted).
function M.reconcile(rec, prev)
	if type(rec) ~= "table" or #M.vids_of(rec) == 0 then
		remove_all(prev)
		remove_all(rec)
		M.unguard()
		M._guard_ok, M._guard_next = false, 0
		return true
	end
	-- Ports a previous record had and this one does not, or on another bridge.
	if type(prev) == "table" then
		local keep = {}
		if prev.bridge == rec.bridge then
			for _, vid in ipairs(M.vids_of(rec)) do keep[vid] = true end
		end
		for _, vid in ipairs(M.vids_of(prev)) do
			if not keep[vid] and valid_ifname(prev.bridge) then M.remove_port(prev.bridge, vid) end
		end
	end
	M._guard_ok = M.guard(rec.bridge)
	M._guard_next = M._time() + M.GUARD_INTERVAL
	if not M._guard_ok then
		fail_closed(rec)
		return false
	end
	for _, vid in ipairs(M.vids_of(rec)) do M.ensure_port(rec.bridge, vid) end
	return true
end

-- Once a heartbeat: put the guard back once a minute (failing closed), and
-- (re)attach any port netifd's last reload took away -- a recreated VLAN
-- bridge drops it, a recreated br-lan deletes it. Cheap when all is well:
-- a few sysfs reads per VLAN, no fork.
function M.resync(rec, now)
	if type(rec) ~= "table" or #M.vids_of(rec) == 0 then return false end
	now = now or M._time()
	if not M._guard_ok or now >= M._guard_next then
		M._guard_ok = M.guard(rec.bridge)
		M._guard_next = now + M.GUARD_INTERVAL
		if not M._guard_ok then
			fail_closed(rec)
			return false
		end
	end
	for _, vid in ipairs(M.vids_of(rec)) do M.ensure_port(rec.bridge, vid) end
	return true
end

return M
