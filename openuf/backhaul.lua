--[[
	backhaul.lua -- the mesh backhaul (UniFi "wireless uplink"): plan, policy, report.

	What the controller sends (captured live 2026-10-03, PROTOCOL-VALIDATION.md
	§ Wireless uplink): a `mesh` block with the site's backhaul SSID and PSK and
	the preferred parent (`mesh.serial1`), plus two entries on the 5 GHz radio --
	a DOWNLINK (`mode=master usage=downlink wds=enabled`, the hidden WPA2 AP a
	child joins) and an UPLINK (`mode=managed usage=uplink wds=enabled`, the
	4-address station that joins a parent). Both are classic 4-address WDS, which
	OpenWrt does with `option wds 1` on an AP and on a station; VLAN-tagged
	frames ride the link as payload, exactly as UniFi's own `ath4.10` layout.

	This module owns three things:
	  plan()           turn the parsed entries into the sections ucihelper writes
	  tick()/decide()  the uplink policy the controller's `connectivity` block
	                   describes and leaves to the device: wired first, the
	                   station only while the wired uplink has no carrier --
	                   never both, because that is a bridge loop and UniFi runs
	                   with STP off. On a swconfig board the carrier is the
	                   switch port's, not the CPU trunk's (see tick())
	  uplink_report()  the `uplink` object a wireless child must report itself
	                   (a wired one is synthesised by the gateway's LLDP)

	Everything is best-effort and pcall-wrapped by the caller; nothing here may
	cost a heartbeat.
]]--

local M = {}

-- Injectable seams (tests replace them).
M._popen = function(cmd)
	local h = io.popen(cmd .. " 2>/dev/null")
	if not h then return "" end
	local s = h:read("*a") or ""
	h:close()
	return s
end
M._read_file = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end
M._log = function(msg) io.stderr:write("backhaul: " .. msg .. "\n") end
M._exec = os.execute
M._write_file = function(path, value)
	local f = io.open(path, "w")
	if not f then return false end
	local ok = f:write(value)
	f:close()
	return ok ~= nil
end

-- Consecutive heartbeats without wired carrier before the station is enabled.
-- Two ticks (~20 s) rides out a switch reboot or a cable being re-seated
-- without taking the user SSIDs on that radio down for nothing; carrier
-- coming back disables the station on the very next tick.
M.DOWN_TICKS = 2

M._down_ticks = 0
M._dirty = false
-- swconfig: heartbeats left in which a stale switch address table is flushed
-- after the uplink came back to the wire (see the end of tick()).
M.ARL_HEAL_TICKS = 3
M._arl_heal = 0

local function is_mac(s)
	return type(s) == "string" and s:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

-- plan(mesh, entries, cfg, st) -> opts.backhaul for ucihelper.apply_config, or nil.
--   mesh:    _parse_mesh_system_cfg's table (status, essid, psk, serial1 ...)
--   entries: _parse_wifi_system_cfg's third return (role, radio, ssid, psk ...)
-- The uplink station is written ENABLED only while the device is already on
-- its wireless uplink (st.backhaul_mode == "wireless"); otherwise disabled,
-- and tick() flips it when the wire goes away.
function M.plan(mesh, entries, cfg, st)
	if type(mesh) ~= "table" or not mesh.status then return nil end
	if type(mesh.essid) ~= "string" or mesh.essid == "" then return nil end
	if type(mesh.psk) ~= "string" or #mesh.psk < 8 or #mesh.psk > 64 then return nil end
	local plan = {}
	for _, e in ipairs(entries or {}) do
		if type(e) == "table" and e.radio then
			if e.role == "downlink" then
				plan.downlink = {
					radio   = e.radio,
					ssid    = (e.ssid and e.ssid ~= "") and e.ssid or mesh.essid,
					key     = (type(e.psk) == "string" and #e.psk >= 8) and e.psk or mesh.psk,
					devname = e.devname,  -- the controller's own name for it (vwire3), reported back as `name`
				}
			elseif e.role == "uplink" then
				plan.uplink = {
					radio   = e.radio,
					ssid    = mesh.essid,
					key     = mesh.psk,
					vport   = e.ssid,  -- the station's own vport-<mac> name, reported as its essid
					devname = e.devname,  -- the controller's name for it (ath4), also connectivity.uplink_wds
					bssid   = nil,  -- the parent's downlink BSSID is learned on the air, not pushed
					enabled = (st ~= nil and st.backhaul_mode == "wireless") or false,
				}
			end
		end
	end
	if not plan.downlink and not plan.uplink then return nil end
	return plan
end

-- Pure policy step. carrier: true/false, or nil when it cannot be read.
-- Returns the new mode and the updated down-tick counter.
function M.decide(carrier, mode, ticks)
	mode  = (mode == "wireless") and "wireless" or "wired"
	ticks = tonumber(ticks) or 0
	if carrier == true then return "wired", 0 end
	if carrier == false then
		ticks = ticks + 1
		if ticks >= M.DOWN_TICKS then return "wireless", ticks end
		return mode, ticks
	end
	return mode, 0  -- unknown: hold what we have, and do not accumulate
end

-- Link state of a wired socket. operstate first: a pulled cable reads
-- "lowerlayerdown" (carrier 0), an administratively downed port reads "down"
-- and has NO readable carrier file, and both mean "no wired uplink". Falls
-- back to the carrier file for drivers that leave operstate at "unknown".
local function carrier_of(ifname)
	if type(ifname) ~= "string" or not ifname:match("^[%w%-%._]+$") then return nil end
	local op = M._read_file("/sys/class/net/" .. ifname .. "/operstate")
	op = op and op:match("%S+") or nil
	if op == "up" then return true end
	if op == "down" or op == "lowerlayerdown" or op == "notpresent" or op == "dormant" then
		return false
	end
	local v = M._read_file("/sys/class/net/" .. ifname .. "/carrier")
	if not v then return nil end
	v = v:match("%d")
	if v == "1" then return true elseif v == "0" then return false end
	return nil
end

local function looks_wireless(ifname)
	return type(ifname) == "string"
		and (ifname:match("^phy%d+%-") or ifname:match("^wlan") or ifname:match("^ath")) ~= nil
end

local function valid_ifname(s)
	return type(s) == "string" and #s <= 15 and s:match("^[%w%-%._]+$") ~= nil
end

-- The LAN (management) bridge, whatever the modelmap names as lan_cpueth:
-- the bridge itself (br-lan on the DSA maps), a socket in it (the AX3000T
-- map), or -- on swconfig -- the CPU trunk, whose VLAN sub-device
-- (<trunk>.<lan_vlanid>, eth0.1) is what sits in the bridge. sysinfo.lan_bridge
-- answers the first two; the trunk has no master of its own, so the third is
-- one hop further. nil when none of them is a bridge port.
function M.lan_bridge(cfg, sysinfo)
	if not sysinfo then return nil end
	local net = cfg and cfg.net
	local cpueth = net and net.lan_cpueth
	if sysinfo.lan_bridge then
		local ok, br = pcall(sysinfo.lan_bridge, cpueth)
		if ok and br then return br end
	end
	if type(cpueth) == "string" and sysinfo.bridge_of then
		local ok, br = pcall(sysinfo.bridge_of, cpueth .. "." .. tostring((net and net.lan_vlanid) or 1))
		if ok and br then return br end
	end
	return nil
end

-- swconfig: the switch's physical port numbers that are sockets on the case
-- (dev.conf.net.ports[].swport resolved through dev.conf.vlan.ports), and the
-- set of CPU ports, which never are.
local function switch_sockets(cfg)
	local sockets, cpu = {}, {}
	local vlan = cfg and cfg.vlan
	if not (vlan and vlan.ports) then return sockets, cpu end
	if tonumber(vlan.cpu_lan) then cpu[tonumber(vlan.cpu_lan)] = true end
	if tonumber(vlan.cpu_wan) then cpu[tonumber(vlan.cpu_wan)] = true end
	for _, p in ipairs((cfg.net and cfg.net.ports) or {}) do
		local phys = p.swport and tonumber(vlan.ports[p.swport] or p.swport)
		if phys and not cpu[phys] then sockets[phys] = true end
	end
	return sockets, cpu
end

-- swconfig: the sockets that are netdevs of their own, outside the switch
-- (the TL-WDR3500's WAN PHY, eth1). On such a board those are the only LAN
-- bridge ports whose carrier is a socket's; every other wired port there is a
-- sub-device of the CPU trunk.
local function netdev_sockets(cfg)
	local out = {}
	for _, p in ipairs((cfg and cfg.net and cfg.net.ports) or {}) do
		if type(p.ifname) == "string" and not p.swport then out[p.ifname] = true end
	end
	return out
end

local function is_wireless_port(ifname)
	return looks_wireless(ifname)
		or M._read_file("/sys/class/net/" .. ifname .. "/phy80211/name") ~= nil
end

-- Make the bridges forget every address they learnt on a WIRED port: the LAN
-- bridge and openUF's VLAN bridges (br-openuf<vid>). For a swconfig board
-- switching between its two uplinks. DSA does not need it -- the uplink
-- socket loses carrier, and the kernel flushes a port that goes down -- but a
-- swconfig board's wired bridge port is the CPU trunk's sub-device, whose
-- carrier is the SoC<->switch link and never drops. Without the flush, every
-- host beyond the pulled cable, the gateway first, stays learnt behind eth0.1,
-- and the device's own traffic to it goes into the switch and dies there until
-- the entry ages out (300 s) or the gateway happens to broadcast. Wireless
-- ports keep theirs. Returns the number of ports flushed.
function M.forget_wired(cfg, sysinfo)
	local bridges = {}
	local br = M.lan_bridge(cfg, sysinfo)
	if valid_ifname(br) then bridges[#bridges + 1] = br end
	for name in (M._popen("ls /sys/class/net") or ""):gmatch("%S+") do
		if name:match("^br%-openuf%d+$") then bridges[#bridges + 1] = name end
	end
	local n = 0
	for _, b in ipairs(bridges) do
		for port in (M._popen("ls /sys/class/net/" .. b .. "/brif") or ""):gmatch("%S+") do
			if valid_ifname(port) and not is_wireless_port(port)
					and M._write_file("/sys/class/net/" .. port .. "/brport/flush", "1") then
				n = n + 1
			end
		end
	end
	return n
end

-- One heartbeat of the policy. Needs ucihelper for the station sections and
-- sysinfo for "which socket is the gateway behind". Persists the mode and the
-- remembered wired socket in state so a restart does not flap the radio.
-- Returns the mode in effect, or nil when the device has no uplink station.
--
-- Which socket, and whether its cable is in, is asked of what can tell:
--   DSA      the LAN bridge's FDB names the socket netdev the gateway is
--            behind (st.backhaul_wired_port), and its operstate the carrier.
--   swconfig the bridge only ever sees the CPU trunk's sub-device, eth0.1,
--            whose carrier is the SoC<->switch link and is always up -- the
--            policy would never have let go of the wire. The switch's ARL
--            table names the physical port instead (st.backhaul_wired_phys),
--            and the switch's own port status its link. A socket that is a
--            netdev of its own (a WAN PHY outside the switch) is still asked
--            of the bridge, as on DSA.
function M.tick(st, cfg, ufuci, sysinfo, state_mod)
	if not (st and ufuci and ufuci.backhaul_uplink_sections) then return nil end
	local secs = ufuci.backhaul_uplink_sections()
	if #secs == 0 then return nil end
	local sta_if = ufuci.ifname_for_section and ufuci.ifname_for_section(secs[1].name) or nil
	local swconfig = (cfg and cfg.vlan and cfg.vlan.ports) and true or false
	local sockets, cpu = switch_sockets(cfg)

	-- swconfig: one `swconfig dev <sw> show` answers both questions.
	local sw, gw_phys = nil, nil
	if swconfig and sysinfo and sysinfo.switch_status then
		local ok, s = pcall(sysinfo.switch_status, cfg.vlan.device)
		if ok and type(s) == "table" and type(s.ports) == "table" and next(s.ports) ~= nil then
			sw = s
			if sysinfo.uplink_phys_port then
				local ok2, phys = pcall(sysinfo.uplink_phys_port, s.arl)
				if ok2 then gw_phys = tonumber(phys) end
			end
		end
	end

	-- Remember the wired socket the gateway is behind while there is one. A
	-- CPU port in the ARL is not one: that is the gateway seen through the
	-- station, its frames flooded from br-lan into the switch.
	if gw_phys and sockets[gw_phys] then
		if st.backhaul_wired_phys ~= gw_phys or st.backhaul_wired_port ~= nil then
			st.backhaul_wired_phys = gw_phys
			st.backhaul_wired_port = nil
			M._dirty = true
		end
	elseif sysinfo and sysinfo.uplink_bridge_port
			and (not swconfig or next(netdev_sockets(cfg)) ~= nil) then
		local br = M.lan_bridge(cfg, sysinfo)
		if br then
			local ok2, p = pcall(sysinfo.uplink_bridge_port, br)
			if ok2 and type(p) == "string" and p ~= sta_if and not looks_wireless(p)
					and (not swconfig or netdev_sockets(cfg)[p]) then
				if st.backhaul_wired_port ~= p or st.backhaul_wired_phys ~= nil then
					st.backhaul_wired_port = p
					st.backhaul_wired_phys = nil
					M._dirty = true
				end
			end
		end
	end

	-- Not `wired_port and carrier_of(...) or nil`: a false carrier would turn
	-- into nil (unknown) and the station would never come up.
	local carrier, wired_desc = nil, nil
	local phys = swconfig and tonumber(st.backhaul_wired_phys) or nil
	local wired_port = st.backhaul_wired_port
	if type(wired_port) ~= "string" or wired_port == "" then wired_port = nil end
	if phys then
		wired_desc = "switch port " .. phys
		if sw and type(sw.ports[phys]) == "table" then carrier = (sw.ports[phys].up == true) end
	elseif wired_port then
		wired_desc = wired_port
		carrier = carrier_of(wired_port)
	end
	local mode = (st.backhaul_mode == "wireless") and "wireless" or "wired"
	local new_mode, ticks = M.decide(carrier, mode, M._down_ticks)
	M._down_ticks = ticks
	if new_mode ~= mode then
		M._log(("wired uplink %s on %s -- %s the WDS station"):format(
			new_mode == "wireless" and "lost" or "back", tostring(wired_desc or "?"),
			new_mode == "wireless" and "enabling" or "disabling"))
		local ok, err = pcall(ufuci.backhaul_set_uplink_enabled, new_mode == "wireless")
		if not ok then M._log("could not switch the station: " .. tostring(err)) end
		st.backhaul_mode = new_mode
		M._dirty = true
		M._arl_heal = (new_mode == "wired") and M.ARL_HEAL_TICKS or 0
		if swconfig then
			local ok_f, n = pcall(M.forget_wired, cfg, sysinfo)
			if not ok_f then M._log("could not flush the bridges: " .. tostring(n)) end
		end
	end

	-- swconfig, back on the wire: hosts beyond the cable that the switch
	-- learnt on the CPU port while their frames came in over the air stay
	-- there, and the switch drops anything the CPU sends them -- a frame is
	-- never forwarded back out of the port it came in on. The kernel only
	-- flushes a port that goes DOWN, and the CPU port never does. So while
	-- the gateway still sits on a CPU port with the uplink a socket again,
	-- the table is stale: flush it, and let the next frames teach it.
	-- For a few heartbeats rather than once, because the station goes down
	-- asynchronously after the switch (`wifi reload`) and keeps teaching the
	-- old answer until it has. Not for ever: on a board with two CPU ports
	-- and its WAN socket bridged into the LAN, the switch lists the gateway
	-- on the LAN CPU port as well, legitimately, in the LAN's VLAN.
	if M._arl_heal > 0 and new_mode == "wired" then
		M._arl_heal = M._arl_heal - 1
		if swconfig and phys and gw_phys and cpu[gw_phys] then
			local dev = tostring(cfg.vlan.device or "switch0")
			if dev:match("^[%w_%-]+$") then
				M._exec("swconfig dev " .. dev .. " set flush_arl_table >/dev/null 2>&1")
				M._log("the switch still had the gateway on its CPU port -- flushed its address table")
			end
		end
	end

	if M._dirty and state_mod and state_mod.save then
		pcall(state_mod.save, st)
		M._dirty = false
	end
	return new_mode
end

local function channel_of(freq)
	if not freq then return nil end
	if freq == 2484 then return 14 end
	if freq >= 5000 then return math.floor((freq - 5000) / 5) end
	if freq >= 2407 then return math.floor((freq - 2407) / 5) end
	return nil
end

-- The parent device behind a downlink BSSID: the controller's priority-1
-- choice (mesh.serial1, persisted) when it named one, else the sibling
-- element of that BSS in the scan table (sysinfo.scan_table tags a sibling
-- openUF AP's BSSes with its identity MAC as serialno). nil when unknown --
-- never a guess, the controller would attribute the link to a wrong device.
function M.parent_for_bssid(st, bssid, ifname, sysinfo)
	-- The BSS actually joined decides. sysinfo.scan_table hands back RAW
	-- entries: the sibling element is `peer_mac` there, and is_unifi/serialno
	-- are only stamped on later, when inform.lua builds scan_radio_table --
	-- the first version tested for those and so found nothing after a cold
	-- boot (AP2, 2026-10-03: station up, informs fine, serialno nil, and the
	-- controller fell back to the gateway's MAC table: "wired via port 2").
	-- It had passed its live test only because the controller's push had
	-- named the parent (mesh.serial1 -> st.backhaul_parent) -- which a boot
	-- straight onto the air, with cfgversion matching, never receives.
	if is_mac(bssid) and sysinfo and sysinfo.scan_table and type(ifname) == "string" then
		local ok_s, entries = pcall(sysinfo.scan_table, ifname)
		for _, e in ipairs((ok_s and type(entries) == "table") and entries or {}) do
			if type(e) == "table" and type(e.bssid) == "string"
					and e.bssid:lower() == bssid:lower() then
				local sn = e.serialno or e.peer_mac
				if (e.is_unifi or e.peer_mac) and is_mac(sn) then return sn:lower() end
			end
		end
	end
	-- Fallback: the parent the controller's last push named. Second, not
	-- first: it describes the push's topology, and a station that has since
	-- joined another parent's downlink must not be filed under the old one.
	if st and is_mac(st.backhaul_parent) then return st.backhaul_parent:lower() end
	return nil
end

-- The device behind a downlink's station: the sibling AP whose identity MAC the
-- bridge learnt behind that station's WDS netdev. `siblings` are the identity
-- MACs the sibling element tagged in this AP's scans (scan_radio_table from the
-- same payload, entries with is_unifi/serialno). nil when none or more than one
-- sibling is behind the netdev -- a grandchild on a multi-hop path would be
-- learnt behind the same netdev, and a wrong attribution is worse than none.
function M.child_serialno(sta_dev, scan_radio_table, cfg, sysinfo)
	if type(sta_dev) ~= "string" or sta_dev == "" then return nil end
	if not (sysinfo and sysinfo.bridge_fdb_ports) then return nil end
	local siblings = {}
	for _, r in ipairs(scan_radio_table or {}) do
		for _, e in ipairs(type(r) == "table" and r.scan_table or {}) do
			if type(e) == "table" and e.is_unifi and is_mac(e.serialno) then
				siblings[e.serialno:lower()] = true
			end
		end
	end
	if next(siblings) == nil then return nil end
	-- M.lan_bridge, not sysinfo.lan_bridge: on a swconfig board lan_cpueth is
	-- the CPU trunk, which is not itself in the bridge.
	local bridge = M.lan_bridge(cfg, sysinfo)
	if not bridge then return nil end
	local ok_f, fdb = pcall(sysinfo.bridge_fdb_ports, bridge)
	if not (ok_f and type(fdb) == "table") then return nil end
	local found = nil
	for mac, port in pairs(fdb) do
		if port == sta_dev and siblings[mac:lower()] then
			if found and found ~= mac:lower() then return nil end  -- ambiguous
			found = mac:lower()
		end
	end
	return found
end

-- The `uplink` object while the device is on its wireless uplink and the
-- station is associated; nil otherwise (the gateway's LLDP then describes the
-- wired uplink, as today). Shape: the fields the controller's frontend reads
-- (`type`, `uplink_mac`, `name`, counters) plus the obvious radio facts; the
-- real wireless shape has never been captured, so this is iterated against the
-- UI (REVERSE-ENGINEERING.md Investigation 1, step 3).
function M.uplink_report(st, cfg, ufuci, sysinfo)
	if not (st and st.backhaul_mode == "wireless" and ufuci and ufuci.backhaul_uplink_sections) then
		return nil
	end
	local secs = ufuci.backhaul_uplink_sections()
	if #secs == 0 then return nil end
	local ifname = ufuci.ifname_for_section and ufuci.ifname_for_section(secs[1].name) or nil
	if not ifname or not ifname:match("^[%w%-%._]+$") then return nil end
	local link = M._popen("iw dev " .. ifname .. " link") or ""
	-- The station's own MAC: the wired `uplink` object the controller shows
	-- carries the uplink interface's `mac`, and it is the only handle that ties
	-- this device to the station the parent sees on its downlink.
	local own = (M._popen("iw dev " .. ifname .. " info") or ""):match("addr (%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
	-- `name` is the controller's own devname for the station (ath4, the one
	-- its push put in connectivity.uplink_wds) when known, so the uplink can be
	-- tied to the uplink VAP entry carrying the same name.
	local report_name = secs[1].devname or ifname
	local bssid = link:match("Connected to (%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
	if not bssid then return nil end
	local signal = tonumber(link:match("signal:%s*(-?%d+)"))
	local freq   = tonumber(link:match("freq:%s*(%d+)"))
	local tx     = tonumber(link:match("tx bitrate:%s*([%d%.]+)"))
	local rx     = tonumber(link:match("rx bitrate:%s*([%d%.]+)"))
	local function stat(n)
		local v = M._read_file("/sys/class/net/" .. ifname .. "/statistics/" .. n)
		return tonumber(v and v:match("%d+")) or 0
	end
	local parent = M.parent_for_bssid(st, bssid, ifname, sysinfo)
	return {
		type          = "wireless",
		up            = true,
		name          = report_name,
		mac           = own,
		essid         = secs[1].ssid,
		bssid         = bssid,
		uplink_mac    = parent,
		ap_mac        = parent,
		radio         = (freq and freq >= 5000) and "na" or "ng",
		channel       = channel_of(freq),
		signal        = signal,
		rssi          = signal and (signal + 95) or nil,
		tx_rate       = tx and math.floor(tx * 1000) or nil,
		rx_rate       = rx and math.floor(rx * 1000) or nil,
		tx_bytes      = stat("tx_bytes"),
		rx_bytes      = stat("rx_bytes"),
		tx_packets    = stat("tx_packets"),
		rx_packets    = stat("rx_packets"),
		uplink_source = "wds",
	}
end


return M
